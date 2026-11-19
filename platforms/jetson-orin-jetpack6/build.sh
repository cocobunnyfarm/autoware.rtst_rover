#!/usr/bin/env bash
# build.sh — 얹은 TensorRT 헤더로 Autoware 패키지 일부를 다시 빌드한다 (fetch.sh 다음에).
#   결과: $PLATFORM_HOST_DIR/ws/install — 컨테이너에서 Autoware 다음에 source 하는 오버레이.
#   소스 버전은 repositories/autoware.repos 의 autoware_universe 버전을 그대로 따른다(이미지와 같은 릴리스).
#   빌드는 실행용 CUDA 이미지 안에서 한다(컴파일러·nvcc·CUDA 헤더가 들어 있다). 호스트에는 설치하지 않는다.
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=platform.env
. "$HERE/platform.env"
# shellcheck source=/dev/null
. "$REPO/repositories/rtst_rover.pin"

IMAGE="${ROVER_PLATFORM_IMAGE:-ghcr.io/autowarefoundation/autoware:${PLATFORM_IMAGE_KIND}-jazzy-${UPSTREAM_TAG}}"
UNIVERSE_VERSION="$(awk '/^  universe\/autoware_universe:/{f=1;next} f&&/version:/{print $2;exit}' "$REPO/repositories/autoware.repos")"
[ -n "$UNIVERSE_VERSION" ] || { echo "autoware.repos 에서 autoware_universe 버전을 못 읽었다" >&2; exit 1; }

ROOT="${PLATFORM_HOST_DIR:?}/root"
WS="${PLATFORM_HOST_DIR:?}/ws"
[ -f "$ROOT/usr/include/aarch64-linux-gnu/NvInfer.h" ] || { echo "TensorRT 헤더가 없다 — 먼저 fetch.sh" >&2; exit 1; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "이미지가 없다: $IMAGE" >&2; exit 1; }
mkdir -p "$WS/src"

# --- 소스 ---
U="$WS/src/autoware_universe"
if [ ! -d "$U/.git" ]; then
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$UNIVERSE_VERSION" --filter=blob:none --sparse \
    https://github.com/autowarefoundation/autoware_universe.git "$U"
fi
have="$(git -C "$U" describe --tags --exact-match 2>/dev/null || true)"
[ "$have" = "$UNIVERSE_VERSION" ] || { echo "받아 둔 autoware_universe($have) 가 autoware.repos($UNIVERSE_VERSION) 와 다르다 — $U 를 지우고 다시" >&2; exit 1; }
# shellcheck disable=SC2086
git -C "$U" sparse-checkout set $PLATFORM_REBUILD_UNIVERSE_PATHS

M="$WS/src/tensorrt_cmake_module"
if [ ! -d "$M/.git" ]; then
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$PLATFORM_TRT_CMAKE_MODULE_TAG" "$PLATFORM_TRT_CMAKE_MODULE_URL" "$M"
fi
[ "$(git -C "$M" rev-parse HEAD)" = "$PLATFORM_TRT_CMAKE_MODULE_COMMIT" ] || { echo "tensorrt_cmake_module 커밋이 platform.env 와 다르다" >&2; exit 1; }

# --- 빌드 (컨테이너 안) ---
TRT_INC="$PLATFORM_MOUNT/root/usr/include/aarch64-linux-gnu"
TRT_LIB="$PLATFORM_MOUNT/root/usr/lib/aarch64-linux-gnu"
echo "[$PLATFORM_NAME] 빌드: $PLATFORM_REBUILD_PKGS  (autoware_universe $UNIVERSE_VERSION, TensorRT $PLATFORM_TRT_VERSION, $IMAGE)"
docker run --rm --network host -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  -v "$PLATFORM_HOST_DIR:$PLATFORM_MOUNT" "$IMAGE" bash -c "
    set -e
    cd $PLATFORM_MOUNT/ws
    # -isystem: TensorRT 헤더를 시스템 헤더로 취급 — 없으면 헤더 안의 unused-parameter 경고가 -Werror 에 걸린다
    colcon build --packages-select $PLATFORM_REBUILD_PKGS --cmake-args \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
      -DCMAKE_INCLUDE_PATH=$TRT_INC -DCMAKE_LIBRARY_PATH=$TRT_LIB \
      '-DCMAKE_CXX_FLAGS=-isystem $TRT_INC'
  "

SO="$WS/install/autoware_tensorrt_common/lib/libautoware_tensorrt_common.so"
[ -f "$SO" ] || { echo "빌드 결과가 없다: $SO" >&2; exit 1; }
echo "[$PLATFORM_NAME] 오버레이 준비됨: $WS/install"
