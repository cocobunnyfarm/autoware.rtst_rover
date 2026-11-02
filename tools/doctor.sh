#!/usr/bin/env bash
# rover doctor — 새 PC 셋업 점검 / rover setup — 점검 + 빠진 것 설치
#   doctor.sh            읽기 전용 점검. 항목 순서 = SETUP.md 절 순서, ✘ 마다 "→ SETUP §x"
#   doctor.sh --fix      점검하고 고칠 수 있는 ✘ 를 하나씩 물어보고(Y/n) 고친다. sudo 는 필요한 단계에서만 묻는다
#   doctor.sh --fix -y   묻지 않고 전부
#   지원 OS: Omarchy, Ubuntu (패키지 설치 방법만 다르고 나머지는 같다)
#   종료코드 = 마지막 점검의 ✘ 개수 (0 이면 전부 통과)
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
IMAGE="${ROVER_IMAGE:-ghcr.io/autowarefoundation/autoware:universe-cuda-jazzy}"
MAP_DEFAULT="$HOME/autoware_data/maps/sample-map-planning"
MAP_HOST="${ROVER_MAP:-$MAP_DEFAULT}"
MAP_URL="https://autoware-files.s3.us-west-2.amazonaws.com/maps/demos/sample-map-planning.zip"
NESTED="$ROOT/src/launcher/autoware_launch.rtst_rover"
NESTED_PUSH="git@github.com:cocobunnyfarm/autoware_launch.rtst_rover.git"
SYSCTL_FILE=/etc/sysctl.d/60-autoware-dds.conf
HOOK='#!/bin/sh
[ "$(git symbolic-ref --short HEAD 2>/dev/null)" = main ] && { echo "main 은 upstream 거울 — 커밋 금지 (master 나 feat/* 에서)"; exit 1; }
exit 0'
MY_UID="$(id -u)"; MY_GID="$(getent passwd "$(id -un)" | cut -d: -f4)"   # 기본 그룹 (newgrp 셸에서도 docker 가 아니라 원래 그룹)

# 최소 버전과 근거
MIN_DOCKER=20.10      # cgroup v2 지원 시작 (요즘 배포판은 cgroup v2)
MIN_NVCTK=1.12.0      # `nvidia-ctk runtime configure` 가 들어온 버전
MIN_DRIVER=580        # 이미지가 CUDA 13 — CUDA 13.0 은 R580 이상 드라이버 필요
MIN_DISK_GB=40        # 이미지 ~17 GB (압축 해제 전후 여유 포함)

FIX=0; YES=0
for a in "$@"; do case "$a" in --fix) FIX=1;; -y|--yes) YES=1;; *) echo "알 수 없는 옵션: $a" >&2; exit 2;; esac; done

# ---- OS 판별: 패키지 설치 방법만 여기서 갈린다
OS_ID="$(. /etc/os-release 2>/dev/null; echo "${ID:-unknown}")"
OS_NAME="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-$OS_ID}")"
case "$OS_ID" in omarchy|ubuntu) OS_OK=1;; *) OS_OK=0;; esac
pkg_install() {   # 패키지 이름은 두 OS 공통 이름을 받는다: docker, git, curl, unzip
  local names=()
  for p in "$@"; do
    case "$OS_ID:$p" in
      omarchy:docker) names+=(docker docker-compose docker-buildx);;
      ubuntu:docker)  names+=(docker.io docker-compose-v2 docker-buildx);;
      *) names+=("$p");;
    esac
  done
  case "$OS_ID" in
    omarchy) run sudo pacman -S --needed --noconfirm "${names[@]}";;
    ubuntu)  run sudo apt-get update -q && run sudo apt-get install -y "${names[@]}";;
    *) echo "    지원 안 하는 OS ($OS_NAME) — 직접 설치: ${names[*]}"; return 1;;
  esac
}

B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; C=$'\e[36m'; D=$'\e[2m'; N=$'\e[0m'
ok()   { printf "  ${G}✔${N} %s ${D}%s${N}\n" "$1" "${2:-}"; }
bad()  { printf "  ${R}✘${N} %s ${D}%s${N}\n" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILS+=("$1  ${2:-}"); }
wait_on() { printf "  ${Y}⏸${N} %s ${D}— %s${N}\n" "$1" "$2"; WAITS+=("$1 — $2"); }   # 앞 단계가 끝나야 점검·설치 가능
warn() { printf "  ${Y}!${N} %s ${D}%s${N}\n" "$1" "${2:-}"; WARN=$((WARN+1)); }
info() { printf "  ${D}·${N} %s ${D}%s${N}\n" "$1" "${2:-}"; }
sec()  { printf "\n${B}%s${N}\n" "$1"; }
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }   # $1 >= $2

# ✘ 와 함께 고칠 수 있는 항목이면 큐에 넣는다 (--fix 일 때만 의미)
QUEUE=(); declare -A SKIP=()
fixable() { [ -n "${SKIP[$1]:-}" ] || QUEUE+=("$1"); }

# ================================================================= 점검
check() {
  FAIL=0; WARN=0; FAILS=(); WAITS=(); QUEUE=(); DOCKER_OK=0; img_ver=""

  sec "§0 시스템"
  [ $OS_OK = 1 ] && ok "$OS_NAME" || warn "$OS_NAME" "(지원: Omarchy·Ubuntu — 점검은 되지만 패키지 자동 설치는 안 함)"
  local t miss_t=()
  for t in git curl unzip; do command -v $t >/dev/null || miss_t+=($t); done
  [ ${#miss_t[@]} = 0 ] && ok "기본 도구 git curl unzip" || { bad "기본 도구 없음: ${miss_t[*]}" "→ SETUP §0"; fixable base_tools; }

  sec "§1 git (작성자 · GitHub · 이 repo)"
  local gn ge sshmsg br
  gn="$(git config --global user.name || true)"; ge="$(git config --global user.email || true)"
  if [ -n "$gn" ] && [ -n "$ge" ]; then ok "git 작성자 $gn <$ge>"; else bad "git 작성자 미설정" "→ SETUP §1"; fixable git_identity; fi
  sshmsg="$(timeout 8 ssh -T -o BatchMode=yes -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)"
  if grep -q "successfully authenticated" <<<"$sshmsg"; then ok "GitHub SSH" "$(grep -o 'Hi [^!]*' <<<"$sshmsg")"
  else bad "GitHub SSH 실패" "→ 직접: ssh-add / GitHub 에 키 등록 ($(head -1 <<<"$sshmsg" | cut -c1-60))"; fi
  br="$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null)"
  case "$br" in master|feat/*) ok "브랜치 $br";; main) bad "브랜치 main" "(upstream 거울) → SETUP §1"; fixable switch_master;; *) warn "브랜치 $br";; esac
  if git -C "$ROOT" remote get-url upstream >/dev/null 2>&1 && git -C "$ROOT" rev-parse -q --verify refs/remotes/upstream/main >/dev/null; then ok "upstream 원격 + fetch"
  else bad "upstream 원격 없음 또는 미fetch" "→ SETUP §1"; fixable outer_upstream; fi
  [ "$(git -C "$ROOT" config branch.main.pushRemote)" = no_push ] && ok "main push 잠금" || { bad "main push 잠금 없음" "→ SETUP §1"; fixable outer_upstream; }
  [ -x "$ROOT/.git/hooks/pre-commit" ] && ok "pre-commit 훅" || { bad "pre-commit 훅 없음" "→ SETUP §1"; fixable outer_hook; }

  sec "§2.1 Docker"
  if ! command -v docker >/dev/null; then
    bad "docker 없음" "→ SETUP §2.1"; fixable docker_install
  else
    local dv; dv="$(docker --version | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
    if ver_ge "$dv" "$MIN_DOCKER"; then ok "docker $dv" "(≥ $MIN_DOCKER)"; else bad "docker $dv 구버전" "(≥ $MIN_DOCKER 필요) → 패키지 업데이트"; fi
    if getent group docker | cut -d: -f4 | tr ',' '\n' | grep -qx "$(id -un)"; then
      if id -G | tr ' ' '\n' | grep -qx "$(getent group docker | cut -d: -f3)"; then ok "docker 그룹 소속 (현재 세션 적용됨)"
      else bad "docker 그룹엔 있으나 현재 세션 미적용" "→ 재로그인 (또는 이 셸만: newgrp docker)"; NEED_RELOGIN=1; fi
    else
      bad "docker 그룹 아님" "→ SETUP §2.1"; fixable docker_group
    fi
    if docker info >/dev/null 2>&1; then ok "데몬 응답 (sudo 없이)"; DOCKER_OK=1
    elif [ -S /var/run/docker.sock ]; then wait_on "sudo 없이 docker 접근" "docker 그룹 적용 후 (위 줄)"
    else bad "데몬 꺼짐" "→ SETUP §2.1"; fixable docker_daemon; fi
  fi

  sec "§2.2 GPU → 컨테이너"
  local drv gpu nv
  if command -v nvidia-smi >/dev/null && drv="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)" && [ -n "$drv" ]; then
    gpu="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
    if ver_ge "$drv" "$MIN_DRIVER"; then ok "NVIDIA 드라이버 $drv" "(≥ $MIN_DRIVER, $gpu)"; else bad "NVIDIA 드라이버 $drv 구버전" "(≥ $MIN_DRIVER 필요, CUDA 13 이미지) — 직접 업데이트"; fi
  else
    bad "nvidia-smi 동작 안 함" "호스트 드라이버 먼저 (직접)"
  fi
  if command -v nvidia-ctk >/dev/null; then
    nv="$(nvidia-ctk --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if ver_ge "$nv" "$MIN_NVCTK"; then ok "nvidia-container-toolkit $nv" "(≥ $MIN_NVCTK)"; else bad "nvidia-container-toolkit $nv 구버전" "(≥ $MIN_NVCTK) → SETUP §2.2"; fixable nvctk_install; fi
  else
    bad "nvidia-container-toolkit 없음" "→ SETUP §2.2"; fixable nvctk_install
  fi
  if [ $DOCKER_OK = 1 ]; then
    if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia; then ok "docker 에 nvidia 런타임 등록됨"
    elif command -v nvidia-ctk >/dev/null; then bad "docker 에 nvidia 런타임 없음" "→ SETUP §2.2"; fixable nv_runtime
    else bad "docker 에 nvidia 런타임 없음" "(toolkit 설치 후)"; fi
  else wait_on "nvidia 런타임 등록 점검" "docker 접근 후"; fi

  sec "§2.3 DDS 커널 버퍼"
  local v it sysbad=0
  for kv in net.core.rmem_max:2147483647 net.ipv4.ipfrag_high_thresh:134217728; do
    v="$(sysctl -n "${kv%%:*}" 2>/dev/null || echo 0)"
    if [ "$v" -ge "${kv##*:}" ] 2>/dev/null; then ok "${kv%%:*} = $v"; else bad "${kv%%:*} = $v" "(≥ ${kv##*:} 필요) → SETUP §2.3"; sysbad=1; fi
  done
  it="$(sysctl -n net.ipv4.ipfrag_time 2>/dev/null)"
  [ "$it" = 3 ] && ok "net.ipv4.ipfrag_time = 3" || { bad "net.ipv4.ipfrag_time = $it" "(3) → SETUP §2.3"; sysbad=1; }
  [ $sysbad = 1 ] && fixable sysctl

  sec "§2.4 화면 (RViz)"
  if [ -n "${DISPLAY:-}" ]; then
    local dn="${DISPLAY#*:}" sock; sock="/tmp/.X11-unix/X${dn%%.*}"
    [ -S "$sock" ] && ok "DISPLAY=$DISPLAY" "($sock)" || warn "DISPLAY=$DISPLAY 인데 $sock 없음" "RViz 안 뜰 수 있음 → SETUP §2.4"
  else
    warn "DISPLAY 없음" "RViz 대신 ROVER_HEADLESS=1 (SSH 접속 등)"
  fi

  sec "§3 이미지"
  if [ $DOCKER_OK = 1 ]; then
    if docker image inspect "$IMAGE" >/dev/null 2>&1; then
      local sz; sz="$(docker image inspect "$IMAGE" --format '{{.Size}}' | awk '{printf "%.1f GB", $1/1e9}')"
      img_ver="$(docker run --rm --entrypoint cat "$IMAGE" /opt/autoware/autoware_launch/share/autoware_launch/package.xml 2>/dev/null | grep -oE '<version>[^<]+' | sed 's/<version>//')"
      ok "$IMAGE" "($sz, autoware_launch $img_ver)"
    else
      local free_gb; free_gb="$(df -BG --output=avail "$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /)" 2>/dev/null | tail -1 | tr -dc 0-9)"
      if [ "${free_gb:-0}" -ge $MIN_DISK_GB ]; then bad "이미지 없음 $IMAGE" "(디스크 여유 ${free_gb} GB) → SETUP §3"; fixable image_pull
      else bad "이미지 없음, 디스크 여유 ${free_gb} GB" "(≥ $MIN_DISK_GB 필요) — 공간 먼저"; fi
    fi
  else wait_on "이미지 점검·pull" "docker 접근 후"; fi

  sec "§4 src/ (vcs import)"
  local repos=() miss=() r other
  mapfile -t repos < <(sed -n 's/^  \([^ #][^:]*\):[[:space:]]*\(#.*\)\{0,1\}$/\1/p' "$ROOT/repositories/autoware.repos")
  for r in "${repos[@]}"; do [ -e "$ROOT/src/$r/.git" ] || miss+=("$r"); done
  if [ ${#miss[@]} = 0 ]; then ok "repo ${#repos[@]}/${#repos[@]}"
  else
    local have="repo $(( ${#repos[@]} - ${#miss[@]} ))/${#repos[@]}"
    if [ $DOCKER_OK = 1 ] && docker image inspect "$IMAGE" >/dev/null 2>&1; then
      bad "$have" "없음: $(printf '%s ' "${miss[@]:0:3}")$([ ${#miss[@]} -gt 3 ] && echo …) → SETUP §4"; fixable vcs_import
    else wait_on "$have (vcs import)" "docker 접근 + 이미지 받은 후 (컨테이너 안에서 받음)"; fi
  fi
  if [ -d "$ROOT/src" ]; then
    other="$(find "$ROOT/src" -maxdepth 4 ! -uid "$MY_UID" -print -quit 2>/dev/null)"
    [ -z "$other" ] && ok "소유자 전부 uid $MY_UID" || { bad "다른 uid 소유 파일 있음" "($other) → SETUP §4"; fixable src_chown; }
  fi

  sec "§5 중첩 fork (src/launcher/autoware_launch.rtst_rover)"
  if [ -d "$NESTED/.git" ]; then
    local pu src_ver
    pu="$(git -C "$NESTED" remote get-url --push origin 2>/dev/null)"
    [[ "$pu" == git@github.com:* ]] && ok "origin push = ssh" || { bad "origin push = $pu" "→ SETUP §5"; fixable nested_git; }
    if git -C "$NESTED" remote get-url upstream >/dev/null 2>&1 && git -C "$NESTED" rev-parse -q --verify refs/remotes/upstream/main >/dev/null; then ok "upstream 원격 + fetch"
    else bad "upstream 원격 없음 또는 미fetch" "→ SETUP §5"; fixable nested_git; fi
    [ "$(git -C "$NESTED" config branch.main.pushRemote)" = no_push ] && ok "main push 잠금" || { bad "main push 잠금 없음" "→ SETUP §5"; fixable nested_git; }
    [ -x "$(git -C "$NESTED" rev-parse --absolute-git-dir)/hooks/pre-commit" ] && ok "pre-commit 훅" || { bad "pre-commit 훅 없음" "→ SETUP §5"; fixable nested_git; }
    info "브랜치 $(git -C "$NESTED" symbolic-ref --short HEAD 2>/dev/null)" "$(git -C "$NESTED" log --oneline -1 | cut -c1-60)  (작업 브랜치 전환은 직접: SETUP §5)"
    src_ver="$(grep -oE '<version>[^<]+' "$NESTED/autoware_launch/package.xml" 2>/dev/null | sed 's/<version>//')"
    if [ -n "$img_ver" ] && [ -n "$src_ver" ]; then
      [ "${img_ver%.*}" = "${src_ver%.*}" ] && ok "세대 일치: fork $src_ver ↔ 이미지 $img_ver" || bad "세대 불일치: fork $src_ver ↔ 이미지 $img_ver" "→ 직접: 이미지 pull 또는 fork 갱신"
    fi
  else
    wait_on "중첩 fork 설정" "vcs import 로 받은 후"
  fi

  sec "§6 rover 명령"
  local p
  if p="$(command -v rover)"; then
    [ "$(readlink -f "$p")" = "$ROOT/tools/rover" ] && ok "rover → 이 repo" "($p)" || warn "rover 가 다른 곳을 가리킴" "($p → $(readlink -f "$p")) → SETUP §6"
  else
    warn "rover 가 PATH 에 없음" "지금은 ./tools/rover 로 호출 (선택: SETUP §6)"
  fi

  sec "§7 지도 ($MAP_HOST)"
  local f mapbad=0
  if [ -d "$MAP_HOST" ]; then
    for f in lanelet2_map.osm pointcloud_map.pcd map_projector_info.yaml; do
      [ -e "$MAP_HOST/$f" ] && ok "$f" || { bad "$f 없음" "→ SETUP §7"; mapbad=1; }
    done
  else
    bad "지도 폴더 없음" "→ SETUP §7"; mapbad=1
  fi
  [ $mapbad = 1 ] && [ "$MAP_HOST" = "$MAP_DEFAULT" ] && fixable map_download
}

# ================================================================= 고치기 (함수 이름 = fix_<항목>)
run() { printf "    ${C}\$ %s${N}\n" "$*"; "$@"; }

desc_base_tools="기본 도구 설치: git curl unzip (sudo)"
fix_base_tools() { pkg_install git curl unzip; }
desc_git_identity="git 전역 작성자 설정 (이름·이메일 입력)"
fix_git_identity() {
  local n e
  read -rp "    user.name : " n; read -rp "    user.email: " e
  [ -n "$n" ] && [ -n "$e" ] || { echo "    빈 값 — 건너뜀"; return 1; }
  run git config --global user.name "$n" && run git config --global user.email "$e"
}
desc_switch_master="master 로 전환"
fix_switch_master() { run git -C "$ROOT" switch master; }
desc_outer_upstream="upstream 원격 추가·fetch, main = upstream/main 추적, main push 잠금"
fix_outer_upstream() {
  git -C "$ROOT" remote get-url upstream >/dev/null 2>&1 || run git -C "$ROOT" remote add upstream https://github.com/autowarefoundation/autoware.git
  run git -C "$ROOT" fetch upstream --tags || return 1
  if git -C "$ROOT" rev-parse -q --verify refs/heads/main >/dev/null; then run git -C "$ROOT" branch -u upstream/main main
  else run git -C "$ROOT" branch --track main upstream/main; fi
  run git -C "$ROOT" config branch.main.pushRemote no_push
  run git -C "$ROOT" config remote.pushDefault origin
}
desc_outer_hook="pre-commit 훅 설치 (main 커밋 금지)"
fix_outer_hook() { printf '%s\n' "$HOOK" > "$ROOT/.git/hooks/pre-commit" && chmod +x "$ROOT/.git/hooks/pre-commit" && echo "    → .git/hooks/pre-commit"; }
desc_docker_install="docker 설치 + 데몬 켜기 (sudo)"
fix_docker_install() { pkg_install docker && run sudo systemctl enable --now docker.socket; }
desc_docker_group="내 계정을 docker 그룹에 (sudo) — 적용은 재로그인 후"
fix_docker_group() { run sudo usermod -aG docker "$(id -un)" && NEED_RELOGIN=1; }
desc_docker_daemon="docker 데몬 켜기 (sudo)"
fix_docker_daemon() { run sudo systemctl enable --now docker.socket; }
desc_nvctk_install="nvidia-container-toolkit 설치 (sudo)"
fix_nvctk_install() {
  case "$OS_ID" in
    omarchy) run sudo pacman -S --needed --noconfirm nvidia-container-toolkit;;
    ubuntu)  # NVIDIA 공식 apt 저장소 (Ubuntu 기본 저장소엔 없음)
      local kr=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
      curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | run sudo gpg --dearmor --yes -o "$kr" || return 1
      curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed "s#deb https://#deb [signed-by=$kr] https://#g" \
        | run sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null || return 1
      run sudo apt-get update -q && run sudo apt-get install -y nvidia-container-toolkit;;
    *) echo "    지원 안 하는 OS ($OS_NAME) — 직접 설치"; return 1;;
  esac
}
desc_nv_runtime="docker 에 nvidia 런타임 등록 + docker 재시작 (sudo, 실행 중 컨테이너는 멈춤)"
fix_nv_runtime() {
  local n; n="$(docker ps -q 2>/dev/null | wc -l)"
  [ "$n" -gt 0 ] && echo "    ⚠ 실행 중 컨테이너 ${n}개 — docker 재시작으로 멈춘다"
  run sudo nvidia-ctk runtime configure --runtime=docker && run sudo systemctl restart docker
}
desc_sysctl="$SYSCTL_FILE 작성 + 적용 (sudo)"
fix_sysctl() {
  printf 'net.core.rmem_max=2147483647\nnet.ipv4.ipfrag_time=3\nnet.ipv4.ipfrag_high_thresh=134217728\n' | run sudo tee "$SYSCTL_FILE" >/dev/null \
    && run sudo sysctl --system >/dev/null
}
desc_image_pull="이미지 받기 ~17 GB ($IMAGE)"
fix_image_pull() { run docker pull "$IMAGE"; }
desc_vcs_import="의존 repo 받기 — 컨테이너에서 vcs import src (내 uid 로)"
fix_vcs_import() {
  # detachedHead 안내문(태그 checkout 마다 20줄) 끄기
  run docker run --rm -e HOST_UID="$MY_UID" -e HOST_GID="$MY_GID" \
    -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=advice.detachedHead -e GIT_CONFIG_VALUE_0=false \
    -v "$ROOT":/ws -w /ws "$IMAGE" \
    bash -c 'vcs import src < repositories/autoware.repos' 2>&1 | grep -v '^\[entrypoint\]'
  return "${PIPESTATUS[0]}"
}
desc_src_chown="src/ 소유자를 내 uid:gid ($MY_UID:$MY_GID) 로 (sudo)"
fix_src_chown() { run sudo chown -R "$MY_UID:$MY_GID" "$ROOT/src"; }
desc_nested_git="중첩 fork: push=ssh, upstream 추가·fetch, main push 잠금, pre-commit 훅"
fix_nested_git() {
  run git -C "$NESTED" remote set-url --push origin "$NESTED_PUSH"
  git -C "$NESTED" remote get-url upstream >/dev/null 2>&1 || run git -C "$NESTED" remote add upstream https://github.com/autowarefoundation/autoware_launch.git
  run git -C "$NESTED" fetch upstream --tags || return 1
  run git -C "$NESTED" config branch.main.pushRemote no_push
  local h; h="$(git -C "$NESTED" rev-parse --absolute-git-dir)/hooks/pre-commit"
  printf '%s\n' "$HOOK" > "$h" && chmod +x "$h" && echo "    → $h"
}
desc_map_download="샘플 지도 받기 → $MAP_DEFAULT"
fix_map_download() {
  local d; d="$(dirname "$MAP_DEFAULT")"
  mkdir -p "$d" && run curl -fL -o "$d/sample-map-planning.zip" "$MAP_URL" \
    && run unzip -oq "$d/sample-map-planning.zip" -d "$d" && rm -f "$d/sample-map-planning.zip"
}

# ================================================================= 실행
NEED_RELOGIN=0; DONE=()
if [ $FIX = 0 ]; then
  check
else
  for round in 1 2 3 4 5 6; do
    check
    declare -A seen=(); todo=()
    for q in "${QUEUE[@]}"; do [ -n "${seen[$q]:-}" ] || { seen[$q]=1; todo+=("$q"); }; done; unset seen
    [ ${#todo[@]} = 0 ] && break
    printf "\n${B}── 고치기 (%d 단계 차례대로) ──${N}\n" "${#todo[@]}"
    for q in "${todo[@]}"; do
      d="desc_$q"; printf "\n${C}▶ %s${N}\n" "${!d}"
      if [ $YES = 0 ]; then read -rp "    진행? [Y/n] " ans; case "${ans:-y}" in y|Y) ;; *) SKIP[$q]=1; echo "    건너뜀"; continue;; esac; fi
      if "fix_$q"; then printf "    ${G}✔ 완료${N}\n"; DONE+=("${!d}"); else printf "    ${R}✘ 실패${N} — 위 출력 확인, 이번 실행에서는 다시 묻지 않음\n"; SKIP[$q]=1; fi
    done
    printf "\n${B}── 다시 점검 (지금 상태) ──${N}\n"
  done
fi

# ---- 요약: 지금 상태 기준
printf "\n${B}── 요약 (지금 상태) ──${N}\n"
if [ ${#DONE[@]} -gt 0 ]; then printf "  ${G}이번에 고친 것 %d${N}\n" "${#DONE[@]}"; for x in "${DONE[@]}"; do printf "    ${D}· %s${N}\n" "$x"; done; fi
if [ $FAIL -gt 0 ]; then
  printf "  ${R}✘ 남은 문제 %d${N}\n" "$FAIL"; for x in "${FAILS[@]}"; do printf "    ${D}· %s${N}\n" "$x"; done
fi
if [ ${#WAITS[@]} -gt 0 ]; then
  printf "  ${Y}⏸ 앞 단계 대기 %d${N} ${D}(앞 단계가 풀리면 setup 이 이어서 함)${N}\n" "${#WAITS[@]}"; for x in "${WAITS[@]}"; do printf "    ${D}· %s${N}\n" "$x"; done
fi
[ $WARN -gt 0 ] && printf "  ${Y}! 경고 %d${N} ${D}(선택 사항)${N}\n" "$WARN"
echo
if [ $FAIL = 0 ] && [ ${#WAITS[@]} = 0 ]; then
  printf "${G}${B}환경 준비 완료${N} — 다음: ./tools/rover build → ./tools/rover psim up (SETUP §8·§9)\n"
elif [ $NEED_RELOGIN = 1 ]; then
  printf "${Y}${B}다음: docker 그룹 적용 — 재로그인(또는 이 터미널만: newgrp docker) → ./tools/rover setup${N}\n"
elif [ $FIX = 0 ]; then
  printf "${B}다음: ./tools/rover setup${N} ${D}(고칠 수 있는 건 자동, 나머지는 위 → SETUP 절)${N}\n"
else
  printf "${B}다음: 위 ✘ 를 SETUP 해당 절대로 직접 처리 → ./tools/rover setup${N}\n"
fi
exit $(( FAIL + ${#WAITS[@]} ))
