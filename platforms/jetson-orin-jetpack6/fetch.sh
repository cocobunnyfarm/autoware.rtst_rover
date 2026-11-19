#!/usr/bin/env bash
# fetch.sh — 이 플랫폼에서 컨테이너에 얹을 NVIDIA 라이브러리를 받아 푼다.
#   호스트에는 아무것도 설치하지 않는다. 결과는 $PLATFORM_HOST_DIR (git 밖):
#     debs/   받은 deb (체크섬 대조 끝난 것)
#     root/   deb 를 푼 것 — 컨테이너에 $PLATFORM_MOUNT/root 로 마운트된다
#   다시 실행해도 된다: 체크섬이 맞는 파일은 다시 받지 않는다.
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=platform.env
. "$HERE/platform.env"

command -v curl >/dev/null || { echo "curl 이 없다" >&2; exit 1; }
command -v dpkg >/dev/null || { echo "dpkg 가 없다 (deb 를 풀 때 쓴다)" >&2; exit 1; }

DEBS="${PLATFORM_HOST_DIR:?}/debs"
ROOT="${PLATFORM_HOST_DIR:?}/root"
mkdir -p "$DEBS" "$ROOT"

fetch_list() {   # $1 = "sha256  파일이름" 줄들
  local sha file
  while read -r sha file; do
    [ -n "${sha:-}" ] || continue
    if [ -f "$DEBS/$file" ] && echo "$sha  $DEBS/$file" | sha256sum -c --status; then
      echo "  있음   $file"
    else
      echo "  받는 중 $file"
      curl -fsSL --retry 3 -o "$DEBS/$file.part" "$PLATFORM_APT_REPO/$file"
      echo "$sha  $DEBS/$file.part" | sha256sum -c --status || { echo "체크섬이 다르다: $file" >&2; exit 1; }
      mv "$DEBS/$file.part" "$DEBS/$file"
    fi
    # 이 deb 를 이미 풀었는지는 표시 파일로 본다 (deb 가 바뀌면 이름이 바뀐다)
    if [ ! -f "$ROOT/.unpacked.$file" ]; then
      dpkg -x "$DEBS/$file" "$ROOT"
      : > "$ROOT/.unpacked.$file"
      echo "  풀음   $file"
    fi
  done <<< "$1"
}

echo "[$PLATFORM_NAME] 실행에 필요한 것"
fetch_list "$PLATFORM_DEBS_RUNTIME"
echo "[$PLATFORM_NAME] 다시 빌드할 때 필요한 헤더"
fetch_list "$PLATFORM_DEBS_BUILD"

# 링크할 때 찾는 이름(libnvinfer.so 등). 2 GB 짜리 -dev 패키지에서 필요한 것은 이 이름뿐이라 직접 만든다.
L="$ROOT/usr/lib/aarch64-linux-gnu"
for n in nvinfer nvinfer_plugin nvonnxparser; do
  [ -e "$L/lib$n.so.10" ] || { echo "없음: $L/lib$n.so.10" >&2; exit 1; }
  [ -e "$L/lib$n.so" ] || ln -s "lib$n.so.10" "$L/lib$n.so"
done

echo "[$PLATFORM_NAME] 준비됨: $ROOT"
echo "  TensorRT  $(basename "$(readlink -f "$L/libnvinfer.so.10")")"
echo "  호환 드라이버 $(ls "$ROOT"/usr/local/cuda-*/compat_orin/libcuda.so.1.1 2>/dev/null | head -1)"
