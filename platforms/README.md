# platforms — 실차 컴퓨터별 구성

Autoware 이미지가 그대로는 돌지 않는 컴퓨터에서, 무엇을 얹고 무엇을 다시 빌드하는지를 플랫폼별 폴더로 나눠 둔다.
플랫폼 = **GPU 계열 + OS(JetPack) 큰 버전**. 이 둘이 바뀌면 필요한 조치가 바뀌므로 폴더를 새로 만든다.
캐리어 보드나 작은 버전 차이는 폴더를 나누지 않고 그 폴더의 README 에 확인된 조합으로 적는다.

| 폴더 | 대상 | 하는 일 |
|---|---|---|
| `jetson-orin-jetpack6/` | Jetson Orin 계열, JetPack 6 (Jetson Linux R36.x) | CUDA 호환 드라이버·TensorRT 10.16.1 을 얹고 `autoware_tensorrt_common` 을 다시 빌드 |

PC(amd64 + NVIDIA 드라이버)는 이미지가 그대로 돌아서 폴더가 없다.

## 폴더에 들어가는 것
| 파일 | 역할 |
|---|---|
| `platform.env` | 값만: 판정 조건, 이미지 종류, 받을 파일과 체크섬, 라이브러리 경로 순서, 다시 빌드할 패키지 |
| `fetch.sh` | 얹을 것을 받아 git 밖(`~/autoware_data/platforms/<이름>/`)에 푼다 |
| `build.sh` | 다시 빌드할 패키지를 이미지 안에서 빌드해 오버레이를 만든다 |
| `README.md` | 왜 필요한지, 확인된 조합, 실측 기록 |

## 쓰는 법 (로버)
손으로 부를 것은 없다. `rover build` 가 순서대로 한다.
1. `platforms/detect.sh` 로 지금 기계에 맞는 폴더를 고른다(칩 이름 + Jetson Linux 큰 버전). 맞는 것이 없으면 멈춘다.
2. 오버레이가 아직 없으면 그 폴더의 `fetch.sh` → `build.sh`.
3. 개발 컨테이너가 없으면 pin 이미지로 만든다(GPU 옵션, 플랫폼 폴더 마운트 = `platform.env`) + `rosdep install`.
4. 우리 패키지 빌드.

`rover real …` 은 컨테이너를 만들지 않는다. 없거나, pin 이미지로 만든 것이 아니면 "먼저 rover build" 라고 하고 멈춘다.
실행할 때는 이미지의 Autoware → 우리 패키지 → 플랫폼 오버레이 순서로 읽고, 라이브러리 경로 앞에 `PLATFORM_LD_PREPEND` 를 붙인다.

## 새 플랫폼을 추가할 때
1. 그 컴퓨터에서 이미지를 그대로 띄워 무엇이 막히는지 먼저 잰다(GPU 인식, CUDA 런타임, TensorRT 가 지원하는 GPU 종류, 엔진 빌드와 재사용).
2. 가장 가까운 폴더를 복사해 이름을 `<GPU 계열>-<OS 큰 버전>` 으로 짓고 `platform.env` 의 값을 바꾼다.
3. 필요 없는 조치는 지운다. 예: JetPack 7 은 호스트 드라이버가 CUDA 13 이라 호환 드라이버가 필요 없을 것이다(미확인).
