#!/usr/bin/env bash
# detect.sh — 지금 이 기계가 platforms/ 아래 어느 플랫폼인지 찾아 폴더 이름을 한 줄로 찍는다.
#   맞는 것이 없으면 아무것도 안 찍고 exit 1. 판정 값은 각 폴더의 platform.env (PLATFORM_MATCH_*).
#   읽는 곳: /proc/device-tree/compatible (보드·칩), /etc/nv_tegra_release (Jetson Linux 버전).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

soc_list="$(tr '\0' '\n' < /proc/device-tree/compatible 2>/dev/null || true)"
l4t_major="$(sed -n 's/^# R\([0-9]*\) .*/\1/p' /etc/nv_tegra_release 2>/dev/null | head -1)"

for env in "$HERE"/*/platform.env; do
  [ -f "$env" ] || continue
  name="$(
    # shellcheck source=/dev/null
    . "$env"
    grep -qx "nvidia,${PLATFORM_MATCH_SOC:-none}" <<<"$soc_list" || exit 1
    [ "${PLATFORM_MATCH_L4T_MAJOR:-none}" = "$l4t_major" ] || exit 1
    echo "$PLATFORM_NAME"
  )" && { echo "$name"; exit 0; }
done
echo "맞는 플랫폼 없음 (칩: $(tr '\n' ' ' <<<"$soc_list"), Jetson Linux R${l4t_major:-?}) — platforms/README.md 의 '새 플랫폼 추가'" >&2
exit 1
