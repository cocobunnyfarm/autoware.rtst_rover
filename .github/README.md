# autoware.rtst_rover

[Autoware](https://github.com/autowarefoundation/autoware) 를 RTST 로버(`rtst_rover`) 차량·센서킷으로 돌리는 워크스페이스 (ROS 2 Jazzy).

**버전 고정**: upstream autoware 릴리스 `2.0.0` · 이미지 `universe-cuda-jazzy-2.0.0`(digest 고정) — [`repositories/rtst_rover.pin`](https://github.com/cocobunnyfarm/autoware.rtst_rover/blob/master/repositories/rtst_rover.pin). 플로팅 태그 금지.

## ▶ 새 PC 셋업: [SETUP.md](https://github.com/cocobunnyfarm/autoware.rtst_rover/blob/master/SETUP.md)

호스트 준비 → clone → `vcs import` → 빌드 → planning_simulator 기동까지 순서대로.

| 브랜치 | 의미 |
|---|---|
| `master` | 우리 기준선 (기본 브랜치) |
| `main` | upstream `autowarefoundation/autoware` 거울 — 커밋 금지 |
| `feat/*` | 작업, `master` 로 `--no-ff` 머지 |

차량·센서킷 패키지와 플래닝·제어 config 는 중첩 fork [`autoware_launch.rtst_rover`](https://github.com/cocobunnyfarm/autoware_launch.rtst_rover) 에 있다 (`src/launcher/` 로 import 됨).

원본 Autoware README: [README.md](https://github.com/cocobunnyfarm/autoware.rtst_rover/blob/master/README.md)
