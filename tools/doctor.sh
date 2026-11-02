#!/usr/bin/env bash
# rover doctor — 새 PC 셋업 점검 / rover setup — 점검 + 빠진 것 설치
#   doctor.sh            읽기 전용 점검. 항목 순서 = SETUP.md 절 순서, ✘ 마다 "→ SETUP §x"
#   doctor.sh --fix      점검하고 고칠 수 있는 ✘ 를 하나씩 물어보고(Y/n) 고친다. sudo 는 필요한 단계에서만 묻는다
#   doctor.sh --fix -y   묻지 않고 전부
#   종료코드 = 마지막 점검의 ✘ 개수 (0 이면 전부 통과)
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
IMAGE="${ROVER_IMAGE:-ghcr.io/autowarefoundation/autoware:universe-cuda-jazzy}"
MAP_DEFAULT="$HOME/autoware_data/maps/sample-map-planning"
MAP_HOST="${ROVER_MAP:-$MAP_DEFAULT}"
MAP_URL="https://autoware-files.s3.us-west-2.amazonaws.com/maps/demos/sample-map-planning.zip"
NESTED="$ROOT/src/launcher/autoware_launch.rtst_rover"
NESTED_PUSH="git@github.com:cocobunnyfarm/autoware_launch.rtst_rover.git"
OVERLAY_PKGS="rtst_rover_description rtst_rover_launch rtst_rover_sensor_kit_description rtst_rover_sensor_kit_launch autoware_planning_config"
SYSCTL_FILE=/etc/sysctl.d/60-autoware-dds.conf
HOOK='#!/bin/sh
[ "$(git symbolic-ref --short HEAD 2>/dev/null)" = main ] && { echo "main 은 upstream 거울 — 커밋 금지 (master 나 feat/* 에서)"; exit 1; }
exit 0'

# 최소 버전과 근거
MIN_DOCKER=20.10      # cgroup v2 지원 시작 (Arch/Omarchy 는 cgroup v2 전용)
MIN_NVCTK=1.12.0      # `nvidia-ctk runtime configure` 가 들어온 버전
MIN_DRIVER=580        # 이미지가 CUDA 13 — CUDA 13.0 은 R580 이상 드라이버 필요
MIN_DISK_GB=40        # 이미지 ~17 GB (압축 해제 전후 여유 포함)

FIX=0; YES=0
for a in "$@"; do case "$a" in --fix) FIX=1;; -y|--yes) YES=1;; *) echo "알 수 없는 옵션: $a" >&2; exit 2;; esac; done

B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; C=$'\e[36m'; D=$'\e[2m'; N=$'\e[0m'
ok()   { printf "  ${G}✔${N} %s ${D}%s${N}\n" "$1" "${2:-}"; }
bad()  { printf "  ${R}✘${N} %s ${D}%s${N}\n" "$1" "${2:-}"; FAIL=$((FAIL+1)); }
warn() { printf "  ${Y}!${N} %s ${D}%s${N}\n" "$1" "${2:-}"; WARN=$((WARN+1)); }
info() { printf "  ${D}·${N} %s ${D}%s${N}\n" "$1" "${2:-}"; }
sec()  { printf "\n${B}%s${N}\n" "$1"; }
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }   # $1 >= $2
has_pacman() { command -v pacman >/dev/null; }

# ✘ 와 함께 고칠 수 있는 항목이면 큐에 넣는다 (--fix 일 때만 의미)
QUEUE=(); declare -A SKIP=()
fixable() { [ -n "${SKIP[$1]:-}" ] || QUEUE+=("$1"); }

# ================================================================= 점검
check() {
  FAIL=0; WARN=0; QUEUE=(); DOCKER_OK=0; img_ver=""

  sec "§1.1 Docker"
  if ! command -v docker >/dev/null; then
    bad "docker 없음" "→ SETUP §1.1"; fixable docker_install
  else
    local dv; dv="$(docker --version | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
    if ver_ge "$dv" "$MIN_DOCKER"; then ok "docker $dv" "(≥ $MIN_DOCKER)"; else bad "docker $dv 구버전" "(≥ $MIN_DOCKER 필요, cgroup v2) → 패키지 업데이트"; fi
    if getent group docker | cut -d: -f4 | tr ',' '\n' | grep -qx "$USER"; then
      if id -nG | tr ' ' '\n' | grep -qx docker; then ok "docker 그룹 소속 (현재 세션 적용됨)"
      else bad "docker 그룹엔 있으나 현재 세션 미적용" "→ 재로그인 (또는 이 셸만: newgrp docker)"; NEED_RELOGIN=1; fi
    else
      bad "docker 그룹 아님" "→ SETUP §1.1"; fixable docker_group
    fi
    if docker info >/dev/null 2>&1; then ok "데몬 응답 (sudo 없이)"; DOCKER_OK=1
    elif [ -S /var/run/docker.sock ]; then bad "데몬 접근 불가" "socket 은 있음 — 대개 그룹 문제(위 줄)"
    else bad "데몬 꺼짐" "→ SETUP §1.1"; fixable docker_daemon; fi
  fi

  sec "§1.2 GPU → 컨테이너"
  local drv gpu nv
  if command -v nvidia-smi >/dev/null && drv="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)" && [ -n "$drv" ]; then
    gpu="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
    if ver_ge "$drv" "$MIN_DRIVER"; then ok "NVIDIA 드라이버 $drv" "(≥ $MIN_DRIVER, $gpu)"; else bad "NVIDIA 드라이버 $drv 구버전" "(≥ $MIN_DRIVER 필요, CUDA 13 이미지) — 직접 업데이트"; fi
  else
    bad "nvidia-smi 동작 안 함" "호스트 드라이버 먼저 (직접)"
  fi
  if command -v nvidia-ctk >/dev/null; then
    nv="$(nvidia-ctk --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if ver_ge "$nv" "$MIN_NVCTK"; then ok "nvidia-container-toolkit $nv" "(≥ $MIN_NVCTK)"; else bad "nvidia-container-toolkit $nv 구버전" "(≥ $MIN_NVCTK) → SETUP §1.2"; fixable nvctk_install; fi
  else
    bad "nvidia-container-toolkit 없음" "→ SETUP §1.2"; fixable nvctk_install
  fi
  if [ $DOCKER_OK = 1 ]; then
    if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia; then ok "docker 에 nvidia 런타임 등록됨"
    elif command -v nvidia-ctk >/dev/null; then bad "docker 에 nvidia 런타임 없음" "→ SETUP §1.2"; fixable nv_runtime
    else bad "docker 에 nvidia 런타임 없음" "(toolkit 설치 후)"; fi
  else info "nvidia 런타임 등록" "(docker 접근 불가로 건너뜀)"; fi

  sec "§1.3 DDS 커널 버퍼"
  local v it sysbad=0
  for kv in net.core.rmem_max:2147483647 net.ipv4.ipfrag_high_thresh:134217728; do
    v="$(sysctl -n "${kv%%:*}" 2>/dev/null || echo 0)"
    if [ "$v" -ge "${kv##*:}" ] 2>/dev/null; then ok "${kv%%:*} = $v"; else bad "${kv%%:*} = $v" "(≥ ${kv##*:} 필요) → SETUP §1.3"; sysbad=1; fi
  done
  it="$(sysctl -n net.ipv4.ipfrag_time 2>/dev/null)"
  [ "$it" = 3 ] && ok "net.ipv4.ipfrag_time = 3" || { bad "net.ipv4.ipfrag_time = $it" "(3) → SETUP §1.3"; sysbad=1; }
  [ $sysbad = 1 ] && fixable sysctl

  sec "§1.4 화면 (RViz)"
  if [ -n "${DISPLAY:-}" ]; then
    local dn="${DISPLAY#*:}" sock; sock="/tmp/.X11-unix/X${dn%%.*}"
    [ -S "$sock" ] && ok "DISPLAY=$DISPLAY" "($sock)" || warn "DISPLAY=$DISPLAY 인데 $sock 없음" "RViz 안 뜰 수 있음 → SETUP §1.4"
  else
    warn "DISPLAY 없음" "RViz 대신 ROVER_HEADLESS=1 (SSH 접속 등)"
  fi

  sec "§1.5 git · GitHub"
  local gn ge sshmsg
  gn="$(git config --global user.name || true)"; ge="$(git config --global user.email || true)"
  if [ -n "$gn" ] && [ -n "$ge" ]; then ok "git 작성자 $gn <$ge>"; else bad "git 작성자 미설정" "→ SETUP §1.5"; fixable git_identity; fi
  sshmsg="$(timeout 8 ssh -T -o BatchMode=yes -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)"
  if grep -q "successfully authenticated" <<<"$sshmsg"; then ok "GitHub SSH" "$(grep -o 'Hi [^!]*' <<<"$sshmsg")"
  else bad "GitHub SSH 실패" "→ 직접: ssh-add / GitHub 에 키 등록 ($(head -1 <<<"$sshmsg" | cut -c1-60))"; fi

  sec "§2 이미지"
  if [ $DOCKER_OK = 1 ]; then
    if docker image inspect "$IMAGE" >/dev/null 2>&1; then
      local sz; sz="$(docker image inspect "$IMAGE" --format '{{.Size}}' | awk '{printf "%.1f GB", $1/1e9}')"
      img_ver="$(docker run --rm --entrypoint cat "$IMAGE" /opt/autoware/autoware_launch/share/autoware_launch/package.xml 2>/dev/null | grep -oE '<version>[^<]+' | sed 's/<version>//')"
      ok "$IMAGE" "($sz, autoware_launch $img_ver)"
    else
      local free_gb; free_gb="$(df -BG --output=avail "$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /)" 2>/dev/null | tail -1 | tr -dc 0-9)"
      if [ "${free_gb:-0}" -ge $MIN_DISK_GB ]; then bad "이미지 없음 $IMAGE" "(디스크 여유 ${free_gb} GB) → SETUP §2"; fixable image_pull
      else bad "이미지 없음, 디스크 여유 ${free_gb} GB" "(≥ $MIN_DISK_GB 필요) — 공간 먼저"; fi
    fi
  else info "이미지 점검" "(docker 접근 불가로 건너뜀)"; fi

  sec "§3 이 repo ($ROOT)"
  local br; br="$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null)"
  case "$br" in master|feat/*) ok "브랜치 $br";; main) bad "브랜치 main" "(upstream 거울) → git switch master"; fixable switch_master;; *) warn "브랜치 $br";; esac
  if git -C "$ROOT" remote get-url upstream >/dev/null 2>&1 && git -C "$ROOT" rev-parse -q --verify refs/remotes/upstream/main >/dev/null; then ok "upstream 원격 + fetch"
  else bad "upstream 원격 없음 또는 미fetch" "→ SETUP §3"; fixable outer_upstream; fi
  [ "$(git -C "$ROOT" config branch.main.pushRemote)" = no_push ] && ok "main push 잠금" || { bad "main push 잠금 없음" "→ SETUP §3"; fixable outer_upstream; }
  [ -x "$ROOT/.git/hooks/pre-commit" ] && ok "pre-commit 훅" || { bad "pre-commit 훅 없음" "→ SETUP §3"; fixable outer_hook; }

  sec "§4 src/ (vcs import)"
  local repos=() miss=() r other
  mapfile -t repos < <(sed -n 's/^  \([^ #][^:]*\):[[:space:]]*\(#.*\)\{0,1\}$/\1/p' "$ROOT/repositories/autoware.repos")
  for r in "${repos[@]}"; do [ -e "$ROOT/src/$r/.git" ] || miss+=("$r"); done
  if [ ${#miss[@]} = 0 ]; then ok "repo ${#repos[@]}/${#repos[@]}"
  else
    bad "repo $(( ${#repos[@]} - ${#miss[@]} ))/${#repos[@]}" "없음: $(printf '%s ' "${miss[@]:0:3}")$([ ${#miss[@]} -gt 3 ] && echo …) → SETUP §4"
    [ $DOCKER_OK = 1 ] && docker image inspect "$IMAGE" >/dev/null 2>&1 && fixable vcs_import
  fi
  if [ -d "$ROOT/src" ]; then
    other="$(find "$ROOT/src" -maxdepth 4 ! -user "$USER" -print -quit 2>/dev/null)"
    [ -z "$other" ] && ok "소유자 전부 $USER" || { bad "다른 소유자 파일 있음" "($other) → SETUP §4"; fixable src_chown; }
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
    bad "중첩 fork 없음" "→ SETUP §4 (vcs import)"
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

  sec "§8 빌드 (install/)"
  local pk buildbad=0
  if [ -d "$ROOT/install" ]; then
    for pk in $OVERLAY_PKGS; do [ -d "$ROOT/install/$pk" ] && ok "$pk" || { bad "$pk 없음" "→ SETUP §8"; buildbad=1; }; done
  else
    bad "install/ 없음" "→ SETUP §8"; buildbad=1
  fi
  [ $buildbad = 1 ] && [ $DOCKER_OK = 1 ] && [ -d "$NESTED/.git" ] && docker image inspect "$IMAGE" >/dev/null 2>&1 && fixable build
}

# ================================================================= 고치기 (함수 이름 = fix_<항목>)
run() { printf "    ${C}\$ %s${N}\n" "$*"; "$@"; }
need_pacman() { has_pacman || { echo "    pacman 없음 — SETUP 의 Ubuntu 안내대로 직접"; return 1; }; }

desc_docker_install="docker 설치 + docker.socket 켜기 (sudo)"
fix_docker_install() { need_pacman && run sudo pacman -S --needed --noconfirm docker docker-compose docker-buildx && run sudo systemctl enable --now docker.socket; }
desc_docker_group="내 계정을 docker 그룹에 (sudo) — 적용은 재로그인 후"
fix_docker_group() { run sudo usermod -aG docker "$USER" && NEED_RELOGIN=1; }
desc_docker_daemon="docker.socket 켜기 (sudo)"
fix_docker_daemon() { run sudo systemctl enable --now docker.socket; }
desc_nvctk_install="nvidia-container-toolkit 설치 (sudo)"
fix_nvctk_install() { need_pacman && run sudo pacman -S --needed --noconfirm nvidia-container-toolkit; }
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
desc_git_identity="git 전역 작성자 설정 (이름·이메일 입력)"
fix_git_identity() {
  local n e
  read -rp "    user.name : " n; read -rp "    user.email: " e
  [ -n "$n" ] && [ -n "$e" ] || { echo "    빈 값 — 건너뜀"; return 1; }
  run git config --global user.name "$n" && run git config --global user.email "$e"
}
desc_image_pull="이미지 받기 ~17 GB ($IMAGE)"
fix_image_pull() { run docker pull "$IMAGE"; }
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
desc_vcs_import="의존 repo 받기 — 컨테이너에서 vcs import src (내 uid 로)"
fix_vcs_import() {
  ( cd "$ROOT" && run docker run --rm -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" -v "$ROOT":/ws -w /ws "$IMAGE" \
      bash -c 'vcs import src < repositories/autoware.repos' ) 2>&1 | grep -v '^\[entrypoint\]'
}
desc_src_chown="src/ 소유자를 $USER 로 (sudo)"
fix_src_chown() { run sudo chown -R "$(id -u):$(id -g)" "$ROOT/src"; }
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
desc_build="오버레이 빌드: $OVERLAY_PKGS"
fix_build() { run "$ROOT/tools/rover" build $OVERLAY_PKGS; }

# ================================================================= 실행
NEED_RELOGIN=0
if [ $FIX = 0 ]; then
  check
else
  for round in 1 2 3 4 5; do
    check
    # 큐 중복 제거 (순서 유지)
    declare -A seen=(); todo=()
    for q in "${QUEUE[@]}"; do [ -n "${seen[$q]:-}" ] || { seen[$q]=1; todo+=("$q"); }; done; unset seen
    [ ${#todo[@]} = 0 ] && break
    printf "\n${B}── 고치기 (%d 단계 차례대로) ──${N}\n" "${#todo[@]}"
    for q in "${todo[@]}"; do
      d="desc_$q"; printf "\n${C}▶ %s${N}\n" "${!d}"
      if [ $YES = 0 ]; then read -rp "    진행? [Y/n] " ans; case "${ans:-y}" in y|Y) ;; *) SKIP[$q]=1; echo "    건너뜀"; continue;; esac; fi
      if "fix_$q"; then printf "    ${G}✔ 완료${N}\n"; else printf "    ${R}✘ 실패${N} — 위 출력 확인, 이번 실행에서는 다시 묻지 않음\n"; SKIP[$q]=1; fi
      [ "$q" = docker_group ] && break   # 그룹은 재로그인 전엔 docker 단계가 전부 막힌다
    done
    if [ $NEED_RELOGIN = 1 ]; then
      printf "\n${Y}${B}docker 그룹 적용을 위해 재로그인(로그아웃 → 로그인) 후 다시: ./tools/rover setup${N}\n"
      break
    fi
    printf "\n${B}── 다시 점검 ──${N}\n"
    [ $round = 5 ] && check
  done
fi

echo
if [ $FAIL = 0 ]; then printf "${G}${B}전부 통과${N}${D} (경고 %d)${N} — 다음: rover psim up (SETUP §9)\n" "$WARN"
else printf "${R}${B}✘ %d 개${N}${D}, 경고 %d — %s${N}\n" "$FAIL" "$WARN" "$([ $FIX = 1 ] && echo '남은 것은 직접 (메시지의 SETUP 절)' || echo '고치려면: ./tools/rover setup')"; fi
exit $FAIL
