#!/usr/bin/env bash
# rover doctor — 새 PC 셋업 점검 (읽기 전용: 설치·sudo·파일 변경 없음)
#   항목 순서 = SETUP.md 절 순서. ✘ 마다 "→ SETUP §x" 로 해결 위치를 가리킨다.
#   종료코드 = ✘ 개수 (0 이면 전부 통과)
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
IMAGE="${ROVER_IMAGE:-ghcr.io/autowarefoundation/autoware:universe-cuda-jazzy}"
MAP_HOST="${ROVER_MAP:-$HOME/autoware_data/maps/sample-map-planning}"
NESTED="$ROOT/src/launcher/autoware_launch.rtst_rover"
OVERLAY_PKGS="rtst_rover_description rtst_rover_launch rtst_rover_sensor_kit_description rtst_rover_sensor_kit_launch autoware_planning_config"

# 최소 버전과 근거
MIN_DOCKER=20.10      # cgroup v2 지원 시작 (Arch/Omarchy 는 cgroup v2 전용)
MIN_NVCTK=1.12.0      # `nvidia-ctk runtime configure` 가 들어온 버전 (SETUP §1.2 명령)
MIN_DRIVER=580        # 이미지가 CUDA 13 — CUDA 13.0 은 R580 이상 드라이버 필요
MIN_DISK_GB=40        # 이미지 ~17 GB (압축 해제 전후 여유 포함)

B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; D=$'\e[2m'; N=$'\e[0m'
FAIL=0; WARN=0
ok()   { printf "  ${G}✔${N} %s ${D}%s${N}\n" "$1" "${2:-}"; }
bad()  { printf "  ${R}✘${N} %s ${D}%s${N}\n" "$1" "${2:-}"; FAIL=$((FAIL+1)); }
warn() { printf "  ${Y}!${N} %s ${D}%s${N}\n" "$1" "${2:-}"; WARN=$((WARN+1)); }
info() { printf "  ${D}·${N} %s ${D}%s${N}\n" "$1" "${2:-}"; }
sec()  { printf "\n${B}%s${N}\n" "$1"; }
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }   # $1 >= $2

DOCKER_OK=0   # sudo 없이 docker 사용 가능 여부 (이후 이미지 점검에 필요)

# ---------------------------------------------------------------- §1.1 docker
sec "§1.1 Docker"
if ! command -v docker >/dev/null; then
  bad "docker 없음" "→ SETUP §1.1 설치"
else
  dv="$(docker --version | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
  if ver_ge "$dv" "$MIN_DOCKER"; then ok "docker $dv" "(≥ $MIN_DOCKER)"; else bad "docker $dv 구버전" "(≥ $MIN_DOCKER 필요, cgroup v2) → SETUP §1.1"; fi
  if getent group docker | tr ':,' '\n\n' | grep -qx "$USER"; then
    if id -nG | tr ' ' '\n' | grep -qx docker; then ok "docker 그룹 소속 (현재 세션 적용됨)"
    else bad "docker 그룹엔 있으나 현재 세션 미적용" "→ 재로그인 (또는 newgrp docker)"; fi
  else
    bad "docker 그룹 아님" "→ SETUP §1.1: sudo usermod -aG docker \$USER 후 재로그인"
  fi
  if docker info >/dev/null 2>&1; then ok "데몬 응답 (sudo 없이)"; DOCKER_OK=1
  elif [ -S /var/run/docker.sock ]; then bad "데몬 접근 불가" "socket 은 있음 — 대개 그룹 문제(위 줄)"
  else bad "데몬 꺼짐" "→ SETUP §1.1: sudo systemctl enable --now docker.socket"; fi
fi

# ---------------------------------------------------------------- §1.2 GPU
sec "§1.2 GPU → 컨테이너"
if command -v nvidia-smi >/dev/null && drv="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)" && [ -n "$drv" ]; then
  gpu="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
  if ver_ge "$drv" "$MIN_DRIVER"; then ok "NVIDIA 드라이버 $drv" "(≥ $MIN_DRIVER, $gpu)"; else bad "NVIDIA 드라이버 $drv 구버전" "(≥ $MIN_DRIVER 필요, CUDA 13 이미지)"; fi
else
  bad "nvidia-smi 동작 안 함" "호스트 드라이버 먼저"
fi
if command -v nvidia-ctk >/dev/null; then
  nv="$(nvidia-ctk --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if ver_ge "$nv" "$MIN_NVCTK"; then ok "nvidia-container-toolkit $nv" "(≥ $MIN_NVCTK)"; else bad "nvidia-container-toolkit $nv 구버전" "(≥ $MIN_NVCTK) → SETUP §1.2"; fi
else
  bad "nvidia-container-toolkit 없음" "→ SETUP §1.2"
fi
if [ $DOCKER_OK = 1 ]; then
  if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia; then ok "docker 에 nvidia 런타임 등록됨"
  else bad "docker 에 nvidia 런타임 없음" "→ SETUP §1.2: nvidia-ctk runtime configure + restart docker"; fi
else info "nvidia 런타임 등록" "(docker 접근 불가로 건너뜀)"; fi

# ---------------------------------------------------------------- §1.3 sysctl
sec "§1.3 DDS 커널 버퍼"
chk_sysctl() {  # key  최소값
  local v; v="$(sysctl -n "$1" 2>/dev/null || echo 0)"
  if [ "$v" -ge "$2" ] 2>/dev/null; then ok "$1 = $v"; else bad "$1 = $v" "(≥ $2 필요) → SETUP §1.3"; fi
}
chk_sysctl net.core.rmem_max 2147483647
chk_sysctl net.ipv4.ipfrag_high_thresh 134217728
it="$(sysctl -n net.ipv4.ipfrag_time 2>/dev/null)"
[ "$it" = 3 ] && ok "net.ipv4.ipfrag_time = 3" || bad "net.ipv4.ipfrag_time = $it" "(3) → SETUP §1.3"

# ---------------------------------------------------------------- §1.4 display
sec "§1.4 화면 (RViz)"
if [ -n "${DISPLAY:-}" ]; then
  dn="${DISPLAY#*:}"; sock="/tmp/.X11-unix/X${dn%%.*}"
  [ -S "$sock" ] && ok "DISPLAY=$DISPLAY" "($sock)" || warn "DISPLAY=$DISPLAY 인데 $sock 없음" "RViz 안 뜰 수 있음 → SETUP §1.4"
else
  warn "DISPLAY 없음" "RViz 대신 ROVER_HEADLESS=1 (SSH 접속 등)"
fi

# ---------------------------------------------------------------- §1.5 git / ssh
sec "§1.5 git · GitHub"
gn="$(git config --global user.name || true)"; ge="$(git config --global user.email || true)"
[ -n "$gn" ] && [ -n "$ge" ] && ok "git 작성자 $gn <$ge>" || bad "git 작성자 미설정" "→ SETUP §1.5"
sshmsg="$(timeout 8 ssh -T -o BatchMode=yes -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)"
if grep -q "successfully authenticated" <<<"$sshmsg"; then ok "GitHub SSH" "$(grep -o 'Hi [^!]*' <<<"$sshmsg")"
else bad "GitHub SSH 실패" "→ ssh-add / 키 등록 ($(head -1 <<<"$sshmsg" | cut -c1-60))"; fi

# ---------------------------------------------------------------- §2 image
sec "§2 이미지"
if [ $DOCKER_OK = 1 ]; then
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    sz="$(docker image inspect "$IMAGE" --format '{{.Size}}' | awk '{printf "%.1f GB", $1/1e9}')"
    img_ver="$(docker run --rm --entrypoint cat "$IMAGE" /opt/autoware/autoware_launch/share/autoware_launch/package.xml 2>/dev/null | grep -oE '<version>[^<]+' | sed 's/<version>//')"
    ok "$IMAGE" "($sz, autoware_launch $img_ver)"
  else
    bad "이미지 없음 $IMAGE" "→ SETUP §2"
    free_gb="$(df -BG --output=avail "$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /)" 2>/dev/null | tail -1 | tr -dc 0-9)"
    [ "${free_gb:-0}" -ge $MIN_DISK_GB ] && ok "디스크 여유 ${free_gb} GB" "(≥ $MIN_DISK_GB)" || bad "디스크 여유 ${free_gb} GB" "(≥ $MIN_DISK_GB 필요)"
  fi
else info "이미지 점검" "(docker 접근 불가로 건너뜀)"; fi

# ---------------------------------------------------------------- §3 this repo
sec "§3 이 repo ($ROOT)"
br="$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null)"
case "$br" in master|feat/*) ok "브랜치 $br";; main) bad "브랜치 main" "(upstream 거울) → git switch master";; *) warn "브랜치 $br";; esac
git -C "$ROOT" remote get-url upstream >/dev/null 2>&1 && ok "upstream 원격" || bad "upstream 원격 없음" "→ SETUP §3"
git -C "$ROOT" rev-parse -q --verify refs/remotes/upstream/main >/dev/null && ok "upstream/main fetch 됨" || bad "upstream 미fetch" "→ SETUP §3: git fetch upstream --tags"
[ "$(git -C "$ROOT" config branch.main.pushRemote)" = no_push ] && ok "main push 잠금" || bad "main push 잠금 없음" "→ SETUP §3"
[ -x "$ROOT/.git/hooks/pre-commit" ] && ok "pre-commit 훅" || bad "pre-commit 훅 없음" "→ SETUP §3"

# ---------------------------------------------------------------- §4 src
sec "§4 src/ (vcs import)"
mapfile -t repos < <(sed -n 's/^  \([^ #][^:]*\):[[:space:]]*\(#.*\)\{0,1\}$/\1/p' "$ROOT/repositories/autoware.repos")
miss=(); for r in "${repos[@]}"; do [ -e "$ROOT/src/$r/.git" ] || miss+=("$r"); done
if [ ${#miss[@]} = 0 ]; then ok "repo ${#repos[@]}/${#repos[@]}"
else bad "repo $(( ${#repos[@]} - ${#miss[@]} ))/${#repos[@]}" "없음: $(printf '%s ' "${miss[@]:0:3}")$([ ${#miss[@]} -gt 3 ] && echo …) → SETUP §4"; fi
if [ -d "$ROOT/src" ]; then
  other="$(find "$ROOT/src" -maxdepth 4 ! -user "$USER" -print -quit 2>/dev/null)"
  [ -z "$other" ] && ok "소유자 전부 $USER" || bad "다른 소유자 파일 있음" "($other) → SETUP §4 복구"
fi

# ---------------------------------------------------------------- §5 nested fork
sec "§5 중첩 fork (src/launcher/autoware_launch.rtst_rover)"
if [ -d "$NESTED/.git" ]; then
  pu="$(git -C "$NESTED" remote get-url --push origin 2>/dev/null)"
  [[ "$pu" == git@github.com:* ]] && ok "origin push = ssh" || bad "origin push = $pu" "→ SETUP §5 (ssh 로)"
  git -C "$NESTED" remote get-url upstream >/dev/null 2>&1 && ok "upstream 원격" || bad "upstream 원격 없음" "→ SETUP §5"
  [ "$(git -C "$NESTED" config branch.main.pushRemote)" = no_push ] && ok "main push 잠금" || bad "main push 잠금 없음" "→ SETUP §5"
  [ -x "$(git -C "$NESTED" rev-parse --absolute-git-dir)/hooks/pre-commit" ] && ok "pre-commit 훅" || bad "pre-commit 훅 없음" "→ SETUP §5"
  info "브랜치 $(git -C "$NESTED" symbolic-ref --short HEAD 2>/dev/null)" "$(git -C "$NESTED" log --oneline -1 | cut -c1-60)"
  src_ver="$(grep -oE '<version>[^<]+' "$NESTED/autoware_launch/package.xml" 2>/dev/null | sed 's/<version>//')"
  if [ -n "${img_ver:-}" ] && [ -n "$src_ver" ]; then
    [ "${img_ver%.*}" = "${src_ver%.*}" ] && ok "세대 일치: fork $src_ver ↔ 이미지 $img_ver" || bad "세대 불일치: fork $src_ver ↔ 이미지 $img_ver" "→ 이미지 pull 또는 fork 갱신"
  fi
else
  bad "중첩 fork 없음" "→ SETUP §4 (vcs import)"
fi

# ---------------------------------------------------------------- §6 rover on PATH
sec "§6 rover 명령"
if p="$(command -v rover)"; then
  [ "$(readlink -f "$p")" = "$ROOT/tools/rover" ] && ok "rover → 이 repo" "($p)" || warn "rover 가 다른 곳을 가리킴" "($p → $(readlink -f "$p")) → SETUP §6"
else
  warn "rover 가 PATH 에 없음" "지금은 $ROOT/tools/rover 로 호출 (→ SETUP §6)"
fi

# ---------------------------------------------------------------- §7 map
sec "§7 지도 ($MAP_HOST)"
if [ -d "$MAP_HOST" ]; then
  for f in lanelet2_map.osm pointcloud_map.pcd map_projector_info.yaml; do
    [ -e "$MAP_HOST/$f" ] && ok "$f" || bad "$f 없음" "→ SETUP §7"
  done
else
  bad "지도 폴더 없음" "→ SETUP §7"
fi

# ---------------------------------------------------------------- §8 build
sec "§8 빌드 (install/)"
if [ -d "$ROOT/install" ]; then
  for p in $OVERLAY_PKGS; do [ -d "$ROOT/install/$p" ] && ok "$p" || bad "$p 없음" "→ SETUP §8"; done
else
  bad "install/ 없음" "→ SETUP §8"
fi

# ---------------------------------------------------------------- summary
echo
if [ $FAIL = 0 ]; then printf "${G}${B}전부 통과${N}${D} (경고 %d)${N} — 다음: rover psim up (SETUP §9)\n" "$WARN"
else printf "${R}${B}✘ %d 개${N}${D}, 경고 %d — 위에서부터 SETUP 해당 절로${N}\n" "$FAIL" "$WARN"; fi
exit $FAIL
