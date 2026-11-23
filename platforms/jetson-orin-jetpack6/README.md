# jetson-orin-jetpack6

Jetson Orin 계열 + JetPack 6 에서 Autoware 의 GPU(CUDA·TensorRT) 패키지를 돌리기 위한 구성.
호스트는 건드리지 않는다 — 컨테이너에 라이브러리를 얹고, Autoware 패키지 하나를 다시 빌드해 오버레이한다.

## 확인된 조합 [실측 2026-11-19]
| 항목 | 값 |
|---|---|
| 모듈 | Jetson Orin NX 16GB (P3767-0000) |
| 캐리어 보드 | Hiwonder 제품. 시스템에는 NVIDIA 기준 캐리어(P3768-0000) 구성으로 잡힌다 |
| JetPack / Jetson Linux | 6.2.3 / R36.5.2 |
| 호스트 CUDA 드라이버 | 12.6 |
| Autoware 이미지 | `universe-cuda-jazzy-2.0.0` (arm64). 이미지 안: CUDA 13.0, TensorRT 10.13.3 |

같은 계열의 다른 모듈(Orin Nano, AGX Orin)이나 다른 6.x 는 돌려 보지 않았다.

## 왜 그대로는 안 되는가
Autoware 의 arm64 이미지는 Jetson 전용이 아니라 일반 arm64 서버용으로 빌드된 것이다. Orin 에서는 두 군데가 막힌다.

| 막힘 | 증상 | 여기서 하는 일 |
|---|---|---|
| CUDA: 이미지 런타임 13.0 > 호스트 드라이버 12.6 | `CUDA driver version is insufficient for CUDA runtime version` (오류 35) | NVIDIA 의 `cuda-compat-orin-13-2`(드라이버의 사용자 쪽 절반, 13.2)를 라이브러리 경로 맨 앞에 둔다 |
| TensorRT: 이미지의 10.13.3 에 Orin(sm_87) 코드가 없다 | 엔진 빌드·실행 불가 | Orin 코드가 들어 있는 10.16.1 로 바꿔 얹는다 |
| 엔진 캐시: `autoware_tensorrt_common` 이 엔진의 버전을 **컴파일 때의** TensorRT 버전과 비교한다 | 켤 때마다 `Plan was created with a different version of TensorRT!` → 엔진 재빌드(모델마다 몇 분) | 그 패키지를 10.16.1 헤더로 다시 빌드해 오버레이한다 |

세 번째는 TensorRT 를 바꿔 얹기 때문에 생긴다. JetPack 을 올려도 이미지의 TensorRT 는 같으므로 두 번째·세 번째는 그대로 남는다.

## 쓰는 법
```bash
./platforms/jetson-orin-jetpack6/fetch.sh    # 라이브러리 받기 (약 2.4 GB, 체크섬 대조)
./platforms/jetson-orin-jetpack6/build.sh    # 패키지 다시 빌드 (1분 안쪽)
```
결과는 git 밖 `~/autoware_data/platforms/jetson-orin-jetpack6/` (`ROVER_PLATFORM_DIR` 로 바꿀 수 있다).

| 폴더 | 내용 |
|---|---|
| `debs/` | 받은 deb |
| `root/` | deb 를 푼 것 — 컨테이너에 `/opt/rover_platform/root` 로 보인다 |
| `ws/src`, `ws/install` | 다시 빌드한 패키지의 소스와 오버레이 |

컨테이너는 이렇게 띄운다(값은 전부 `platform.env`):
```bash
docker run --runtime nvidia -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=all \
  -v ~/autoware_data/platforms/jetson-orin-jetpack6:/opt/rover_platform ...
# 컨테이너 안, Autoware 를 source 한 뒤:
source /opt/rover_platform/ws/install/setup.bash
export LD_LIBRARY_PATH=$PLATFORM_LD_PREPEND:$LD_LIBRARY_PATH
```
Tegra 에서는 `--gpus all` 이 아니라 `--runtime nvidia` 와 두 환경변수다.

## 실측 기록
| 시험 | 결과 |
|---|---|
| 호환 드라이버 없이 CUDA 런타임 13.0 | 오류 35 |
| 호환 드라이버 13.2 를 앞에 둠 | `cudaDriverGetVersion` 13020, 메모리 할당·스트림 생성 정상 |
| `trtexec` 10.16.1 로 신호등 분류기 | 엔진 빌드 79 s, 추론 1.03 ms, PASSED |
| `autoware_lidar_centerpoint` 엔진 빌드 | 됨 (큰 엔진 약 7분) |
| 같은 노드 재실행, 패키지 다시 빌드 전 | 엔진 재빌드, 446 s |
| 같은 노드 재실행, 패키지 다시 빌드 후 | 엔진 재사용, 7 s |

아직 안 본 것: 실제 입력을 넣은 추론, 여러 모델을 함께 띄웠을 때의 메모리, centerpoint 이외의 모델.

## 값을 바꿀 때
- Autoware 릴리스를 올리면 `build.sh` 를 다시 돌린다(소스 버전이 `autoware.repos` 를 따른다). 이미지의 TensorRT 가 Orin 을 지원하는 버전(10.16.1 이상)으로 올라가면 TensorRT 교체와 재빌드는 필요 없어진다.
- TensorRT 버전을 바꾸면 `platform.env` 의 버전·파일 이름·체크섬을 같이 바꾸고, 만들어 둔 `.engine` 은 다시 빌드된다.
- 체크섬은 `$PLATFORM_APT_REPO/Packages` 의 `SHA256` 값이다.
