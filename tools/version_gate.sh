#!/usr/bin/env bash
# version_gate.sh — 코드 · pin · 이미지 버전 대조 (rover 실행 잠금 + doctor 표시 공용)
#   source 해서 vg_run 을 부르면 결과가 VG_* 변수에 채워진다. 네트워크 안 씀(로컬 git·docker 만) → 빠름.
#   단독 실행: tools/version_gate.sh  → 문제 있으면 이유와 선택지를 찍고 exit 1 (rover 가 이걸로 잠근다)
#
#   어긋남을 "어느 쪽으로 맞출지"는 사용자 판단 — 여기서는 보여주기만 하고 아무것도 바꾸지 않는다.

VG_ROOT="${VG_ROOT:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
VG_PIN="$VG_ROOT/repositories/rtst_rover.pin"
VG_NESTED="$VG_ROOT/src/launcher/autoware_launch.rtst_rover"

vg_repos_wo_launcher() { awk '/^  [^ #]/{skip=($1 ~ /^launcher\//)} !skip'; }
vg_tag_repos() { git -C "$VG_ROOT" show "$1:repositories/autoware.repos" 2>/dev/null | vg_repos_wo_launcher; }
vg_repo_ver() { awk -v k="  $1:" 'index($0,k)==1{f=1;next} f&&/version:/{print $2;exit}' "${2:-$VG_ROOT/repositories/autoware.repos}"; }

# 결과:
#   VG_ISSUES[]  "제목|설명"   — 하나라도 있으면 잠김
#   VG_WAITS[]   "제목|이유"   — 앞 단계가 안 돼서 대조 못 함 (setup 전) → 이것도 잠김
#   VG_CODE_TAG  지금 코드(autoware.repos)와 일치하는 upstream 릴리스 태그 (없으면 빈 값)
#   VG_NEWEST    로컬에 있는 가장 새 upstream 릴리스 태그
#   VG_IMG_DIGESTS  로컬 pin 이미지의 RepoDigests
vg_run() {
  VG_ISSUES=(); VG_WAITS=(); VG_CODE_TAG=""; VG_NEWEST=""; VG_IMG_DIGESTS=""
  if [ ! -f "$VG_PIN" ]; then VG_ISSUES+=("pin 파일 없음|$VG_PIN"); return; fi
  # shellcheck source=/dev/null
  . "$VG_PIN"

  # ① 코드: 우리 autoware.repos 가 어느 upstream 릴리스와 같은가 (launcher 줄 제외)
  local tags t mine
  tags="$(git -C "$VG_ROOT" tag -l | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -rV)"
  if [ -z "$tags" ]; then
    VG_WAITS+=("upstream 릴리스 태그 없음|git fetch upstream --tags (rover setup 이 함)")
  else
    VG_NEWEST="$(head -1 <<<"$tags")"
    mine="$(vg_repos_wo_launcher < "$VG_ROOT/repositories/autoware.repos")"
    for t in $(head -20 <<<"$tags"); do
      [ "$(vg_tag_repos "$t")" = "$mine" ] && { VG_CODE_TAG="$t"; break; }
    done
    local tagc; tagc="$(git -C "$VG_ROOT" rev-parse -q --verify "refs/tags/$UPSTREAM_TAG^{commit}" 2>/dev/null)"
    if [ -z "$tagc" ]; then
      VG_ISSUES+=("pin 의 upstream 태그 $UPSTREAM_TAG 가 로컬에 없음|git fetch upstream --tags, 또는 pin 오타")
    elif [ "$tagc" != "$UPSTREAM_COMMIT" ]; then
      VG_ISSUES+=("upstream 태그 $UPSTREAM_TAG 커밋이 pin 과 다름|태그 ${tagc:0:7} ≠ pin ${UPSTREAM_COMMIT:0:7} — upstream 이 태그를 옮겼거나 pin 오타")
    fi
    if [ "$VG_CODE_TAG" != "$UPSTREAM_TAG" ]; then
      if [ -n "$VG_CODE_TAG" ]; then
        if [ "$(printf '%s\n%s\n' "$VG_CODE_TAG" "$UPSTREAM_TAG" | sort -V | tail -1)" = "$VG_CODE_TAG" ]; then
          VG_ISSUES+=("코드 ≠ pin (pin 이 stale)|코드(autoware.repos) = upstream $VG_CODE_TAG 로 올라감, pin 은 아직 $UPSTREAM_TAG")
        else
          VG_ISSUES+=("코드 ≠ pin (코드가 더 옛 릴리스)|코드(autoware.repos) = upstream $VG_CODE_TAG, pin = $UPSTREAM_TAG")
        fi
      else
        VG_ISSUES+=("코드 ≠ pin|코드(autoware.repos) 가 어떤 upstream 릴리스 태그와도 다름 (main 중간을 당겼거나 손으로 바꿈). pin = $UPSTREAM_TAG — git diff $UPSTREAM_TAG -- repositories/autoware.repos")
      fi
    fi
  fi

  # ② 이미지: pin 이미지가 로컬에 있고 digest 가 pin 과 같은가
  if [ -n "${ROVER_IMAGE:-}" ] && [ "$ROVER_IMAGE" != "$PIN_IMAGE" ]; then
    VG_ISSUES+=("ROVER_IMAGE 덮어씀|$ROVER_IMAGE — 고정 이미지가 아님. unset ROVER_IMAGE")
  fi
  if ! docker info >/dev/null 2>&1; then
    VG_WAITS+=("이미지 digest 대조|docker 접근 불가")
  elif ! docker image inspect "$PIN_IMAGE" >/dev/null 2>&1; then
    VG_ISSUES+=("pin 이미지 없음|${PIN_IMAGE##*/} — rover setup 으로 받기")
  else
    VG_IMG_DIGESTS="$(docker image inspect "$PIN_IMAGE" --format '{{range .RepoDigests}}{{.}} {{end}}')"
    [[ "$VG_IMG_DIGESTS" == *"$PIN_IMAGE_DIGEST"* ]] || \
      VG_ISSUES+=("이미지 digest ≠ pin|로컬 ${PIN_IMAGE##*/} = ${VG_IMG_DIGESTS:-없음} / pin = $PIN_IMAGE_DIGEST — 태그가 재빌드됐거나 pin 오타")
  fi

  # ③ 중첩 fork: upstream LAUNCHER_BASE_TAG 위, 더 새 upstream 태그 섞임 없음
  if [ ! -d "$VG_NESTED/.git" ]; then
    VG_WAITS+=("중첩 fork 기준 태그 대조|vcs import 전")
  elif ! git -C "$VG_NESTED" rev-parse -q --verify "refs/tags/$LAUNCHER_BASE_TAG" >/dev/null; then
    VG_WAITS+=("중첩 fork 기준 태그 대조|중첩 fork 에 태그 $LAUNCHER_BASE_TAG 없음 — git -C src/launcher/autoware_launch.rtst_rover fetch upstream --tags")
  else
    local nnew; nnew="$(git -C "$VG_NESTED" tag --merged HEAD | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
    if ! git -C "$VG_NESTED" merge-base --is-ancestor "$LAUNCHER_BASE_TAG" HEAD; then
      VG_ISSUES+=("중첩 fork ≠ pin|HEAD 가 upstream $LAUNCHER_BASE_TAG 를 포함 안 함")
    elif [ "$nnew" != "$LAUNCHER_BASE_TAG" ]; then
      VG_ISSUES+=("중첩 fork ≠ pin (pin 이 stale)|중첩 fork 에 upstream $nnew 가 들어옴, pin LAUNCHER_BASE_TAG = $LAUNCHER_BASE_TAG")
    fi
    # 코드의 autoware.repos 가 가리키는 launch 기준(upstream 릴리스의 launcher 버전)과 pin 이 같은지
    if [ -n "$VG_CODE_TAG" ]; then
      local want; want="$(git -C "$VG_ROOT" show "$VG_CODE_TAG:repositories/autoware.repos" | awk '/^  launcher\/autoware_launch:/{f=1;next} f&&/version:/{print $2;exit}')"
      [ -n "$want" ] && [ "$want" != "$LAUNCHER_BASE_TAG" ] && \
        VG_ISSUES+=("launch 기준 ≠ 코드의 릴리스|upstream $VG_CODE_TAG 는 autoware_launch $want 를 쓰는데 pin LAUNCHER_BASE_TAG = $LAUNCHER_BASE_TAG")
    fi
  fi
}

# 어긋났을 때 선택지 (사용자가 고른다 — 자동으로 하지 않음)
vg_options() {
  local t="${VG_CODE_TAG:-<맞출 릴리스>}"
  cat <<EOF
  어느 쪽에 맞출지는 직접 정한다 (자동으로 바꾸지 않음):
    (a) 코드를 따라 pin 을 올린다 → upstream $t 기준
        · repositories/rtst_rover.pin: UPSTREAM_TAG/COMMIT, LAUNCHER_BASE_TAG, PIN_IMAGE(universe-cuda-jazzy-$t), PIN_IMAGE_DIGEST
        · 중첩 fork 를 그 릴리스의 autoware_launch 태그 위로 merge
        · ./tools/rover doctor 가 그 릴리스의 이미지 digest 를 조회해 보여줌 → pin 에 기입 → ./tools/rover setup 으로 pull
    (b) pin 을 따라 코드를 되돌린다 → upstream $UPSTREAM_TAG 기준
        · 바깥 fork autoware.repos 를 $UPSTREAM_TAG 의 것으로 (launcher 줄은 우리 fork 유지), vcs import 다시
  절차: SETUP.md "버전 고정" 절
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  vg_run
  [ ${#VG_ISSUES[@]} = 0 ] && [ ${#VG_WAITS[@]} = 0 ] && exit 0
  R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
  printf "${R}${B}🔒 rover 잠김 — 코드·pin·이미지 버전이 맞지 않음${N}\n" >&2
  for x in "${VG_ISSUES[@]}"; do printf "  ${R}✘${N} %s ${D}— %s${N}\n" "${x%%|*}" "${x#*|}" >&2; done
  for x in "${VG_WAITS[@]}";  do printf "  ${Y}⏸${N} %s ${D}— %s${N}\n" "${x%%|*}" "${x#*|}" >&2; done
  if [ ${#VG_ISSUES[@]} -gt 0 ] && printf '%s\n' "${VG_ISSUES[@]}" | grep -q "stale\|코드 ≠ pin\|중첩 fork ≠ pin\|launch 기준"; then vg_options >&2; fi
  printf "  ${D}자세히: ./tools/rover doctor   (setup 전이면: ./tools/rover setup)${N}\n" >&2
  exit 1
fi
