# SETUP — 새 PC 에서 autoware.rtst_rover 워크스페이스 세우기

clone 하고 `./tools/rover setup` 을 돌리면 planning_simulator 를 띄울 수 있는 상태까지 간다.
호스트에는 ROS 를 설치하지 않는다. 빌드·실행은 전부 Autoware 공식 이미지 컨테이너 안에서 한다.

- 지원 호스트: **Omarchy**, **Ubuntu** (+ NVIDIA GPU). 패키지 설치는 스크립트가 OS 를 보고 알아서 한다.
- 명령은 전부 **호스트**에서, **이 repo 루트**에서. `/ws/…` 는 컨테이너 안 경로(= 이 repo 루트).

---

## 0. 구성 한눈에

```
autoware.rtst_rover/                         ← 이 repo (fork of autowarefoundation/autoware)
├── repositories/autoware.repos              ← 의존 repo 30개 목록. launcher 줄만 우리 fork
├── repositories/rtst_rover.pin              ← ⭐ 버전 고정: upstream 릴리스 태그 · 이미지 태그+digest
├── tools/rover                              ← CLI: doctor · setup · build · psim · shell
├── SETUP.md                                 ← 이 파일
├── src/                                     ← vcs import 로 채움 (git 추적 안 함, src/.gitignore)
│   ├── …upstream repo 29개 (읽기 전용)
│   └── launcher/autoware_launch.rtst_rover/ ← ⭐ 중첩 fork: 차량·센서킷 패키지, 플래닝·제어 config
└── install/ build/ log/                     ← 우리 패키지 오버레이 빌드 산출물 (PC 마다 새로)
```

| 무엇 | 값 | 비고 |
|---|---|---|
| 이 repo | `cocobunnyfarm/autoware.rtst_rover`, 브랜치 `master` | `main` = upstream 거울(커밋·push 금지) |
| 중첩 fork | `cocobunnyfarm/autoware_launch.rtst_rover`, `master` + `feat/*` | `vcs import` 가 `master` 로 받음 |
| 기준 upstream | `autowarefoundation/autoware` 릴리스 **`2.0.0`** | core 1.10.0 · universe 0.53.1 · launch 0.53.0 |
| 실행 이미지 | `ghcr.io/autowarefoundation/autoware:universe-cuda-jazzy-2.0.0` + digest | **같은 릴리스로 빌드된 것만**. 플로팅 `universe-cuda-jazzy` 금지 |
| 지도 | `~/autoware_data/maps/sample-map-planning` | §7 |

---

## 버전 고정 (가장 중요)
코드(`src/` = `autoware.repos` 핀)와 실행 이미지(`/opt/autoware` = 프리빌트 Autoware)는 **같은 upstream 릴리스**에서 나와야 한다.
어긋나면 이미지 바이너리가 우리 config 에 없는 파라미터를 찾다 죽는 식으로 깨진다.
그래서 `repositories/rtst_rover.pin` 한 파일에 고정하고, `rover` 는 이 파일의 이미지만 쓰며, `rover doctor` 가 매번 대조한다:

| doctor 점검 | 어긋나면 |
|---|---|
| upstream 태그 `UPSTREAM_TAG` 의 커밋 = `UPSTREAM_COMMIT` | 태그가 바뀜 — pin 확인 |
| 우리 `autoware.repos` = 그 태그의 `autoware.repos` (launcher 줄만 우리 fork) | 핀이 릴리스에서 벗어남 |
| 로컬 이미지 digest = `PIN_IMAGE_DIGEST` | 다시 pull (`rover setup`) |
| 중첩 fork 가 upstream `LAUNCHER_BASE_TAG` 위에 있고 더 새 upstream 태그를 품지 않음 | launch 쪽만 앞서감 |

doctor/setup 은 시작할 때 고정 버전(upstream 태그·core·universe·launcher 기준·이미지 digest)을 먼저 찍는다.

**🔒 rover 잠금**: `rover build` · `rover psim up|restart|watch` · `rover shell` 은 실행 전에 `tools/version_gate.sh` 로 위 대조를 하고, 하나라도 어긋나면 이유와 선택지를 찍고 **실행하지 않는다**. 풀려면 어긋남을 해결하는 수밖에 없다(우회 옵션 없음). 대조는 로컬 git·docker 만 써서 빠르다.
- 어긋났을 때 **어느 쪽에 맞출지는 사용자가 정한다** — (a) 코드를 따라 pin·이미지를 올리거나 (b) pin 을 따라 코드를 되돌리거나. 스크립트는 아무것도 바꾸지 않고, `rover doctor` 가 코드가 가리키는 릴리스의 이미지 digest 를 ghcr 에서 조회해 보여준다.
- 예외: 코드 = pin 인데 이미지만 없거나 digest 가 다르면 `rover setup` 이 pin 이미지를 다시 받는다(선택이 필요 없는 경우).

⚠ `universe-cuda-jazzy` 같은 **플로팅 태그는 매일 upstream main 으로 다시 빌드**된다. 2026-11-02 실제로 플로팅을 받아 universe main(> 0.53.1)이 섞였고, `map_based_prediction` 이 `lane_change_path_suppression.*`(#13525) 파라미터 없음으로 abort → AUTO 버튼이 죽었다. 다른 버전이 필요하면 `ROVER_IMAGE=` 로 덮을 수 있지만 doctor 가 경고한다.

**upstream 을 올릴 때** (새 릴리스 태그 X 로):
1. 바깥 fork: `git fetch upstream --tags` → master 에 `git merge X`(또는 그 커밋) → `autoware.repos` 의 launcher 줄은 우리 fork 유지
2. 중첩 fork: X 의 `autoware.repos` 가 가리키는 launch 태그로 master 를 올림(merge) → `LAUNCHER_BASE_TAG`
3. 이미지 태그 `universe-cuda-jazzy-X` 의 digest 확인:
   `docker pull ghcr.io/autowarefoundation/autoware:universe-cuda-jazzy-X && docker image inspect … --format '{{index .RepoDigests 0}}'`
4. `rtst_rover.pin` 4개 값 갱신 → `rover doctor` 전부 ✔ → `vcs import src < repositories/autoware.repos`(새 핀) → `rover build`

---

## 빠른 길: clone → setup
```bash
git clone git@github.com:cocobunnyfarm/autoware.rtst_rover.git
cd autoware.rtst_rover
./tools/rover doctor      # 점검만 (읽기 전용). 절 순서대로 ✔ / ✘ / !, ✘ 마다 → SETUP §x
./tools/rover setup       # 점검 + 고칠 수 있는 ✘ 를 차례로 묻고(Y/n) 고침. sudo 는 필요한 단계에서만
./tools/rover setup -y    # 묻지 않고 전부
```
- `setup` 이 하는 일 = 아래 §0~§7 그대로 (환경 준비까지). 실행 전에 `$ 명령` 을 찍고, 고친 뒤 다시 점검해 새로 풀린 단계를 이어서 한다.
- **docker 그룹을 추가하면 거기서 멈춘다** — 그룹은 다시 로그인해야 적용된다. 재로그인 후 `./tools/rover setup` 을 한 번 더.
- 자동으로 안 하는 것(직접): NVIDIA 드라이버, GitHub SSH 키 등록, 중첩 fork 작업 브랜치 선택(§5), `rover` PATH 링크(§6), 기본이 아닌 지도(`ROVER_MAP`).
- 전부 ✔ 면 §8 `rover build` → §9 `rover psim up`.

최소 버전 (doctor 가 판정):
| 항목 | 최소 | 이유 |
|---|---|---|
| docker | 20.10 | cgroup v2 지원 시작 |
| NVIDIA 드라이버 | 580 | 이미지가 CUDA 13 — R580 이상 필요 |
| nvidia-container-toolkit | 1.12.0 | §2.2 의 `nvidia-ctk runtime configure` |
| 디스크 여유 | 40 GB | 이미지 ~17 GB (이미지 없을 때만 확인) |

아래 절들은 각 단계가 **무엇을 왜** 하는지의 설명이다. 손으로 할 때는 각 절의 명령을 쓰면 되고, 패키지 설치만 OS 패키지 관리자로 직접.

---

## 0. 시스템 · 기본 도구
OS 를 확인하고(Omarchy / Ubuntu), `git` `curl` `unzip` 이 없으면 설치한다.

## 1. git (작성자 · GitHub · 이 repo)
커밋 작성자와 GitHub 접근, 이 repo 의 브랜치 규칙을 먼저 맞춘다. docker 와 무관해 가장 먼저 끝낼 수 있다.
```bash
git config --global user.name  "<이름>"            # 없으면 커밋이 Author identity unknown 으로 거부
git config --global user.email "<이메일>"
ssh -T git@github.com                               # "Hi <계정>" — 안 되면 ssh-add / GitHub 에 키 등록 (직접)

git switch master                                   # main 이면
git remote add upstream https://github.com/autowarefoundation/autoware.git
git fetch upstream --tags
git branch --track main upstream/main               # main = upstream 거울 (이미 있으면: git branch -u upstream/main main)
git config branch.main.pushRemote no_push           # main 에서 push 불가
git config remote.pushDefault origin
```
그리고 main 에서 커밋을 막는 훅 `.git/hooks/pre-commit` (훅은 clone 으로 따라오지 않는다):
```sh
#!/bin/sh
[ "$(git symbolic-ref --short HEAD 2>/dev/null)" = main ] && { echo "main 은 upstream 거울 — 커밋 금지 (master 나 feat/* 에서)"; exit 1; }
exit 0
```

---

## 2. 호스트 준비 (sudo)

### 2.1 Docker
docker 엔진(+ compose, buildx)을 설치하고 데몬(`docker.socket`)을 켠 뒤, **내 계정을 docker 그룹에** 넣는다 — 그래야 sudo 없이 `docker` 를 쓰고, `rover` 가 동작한다.
```bash
sudo systemctl enable --now docker.socket
sudo usermod -aG docker "$USER"                     # ⚠ 다시 로그인해야 적용 (지금 셸만: newgrp docker)
```

### 2.2 GPU 를 컨테이너로 (nvidia-container-toolkit)
호스트 NVIDIA 드라이버(`nvidia-smi`)는 이미 있어야 한다. toolkit 을 설치하고 docker 에 nvidia 런타임을 등록한다 — 이게 있어야 `docker run --gpus all` 이 된다.
```bash
sudo nvidia-ctk runtime configure --runtime=docker  # /etc/docker/daemon.json 에 nvidia 런타임 추가
sudo systemctl restart docker
```

### 2.3 DDS 커널 버퍼
Autoware(CycloneDDS) 의 큰 메시지용 수신 버퍼. 배포판 기본값(수 MB)으로는 부족해 노드가 `rmw_create_node: failed to create domain` 으로 죽는다.
```bash
sudo tee /etc/sysctl.d/60-autoware-dds.conf > /dev/null <<'EOF'
net.core.rmem_max=2147483647
net.ipv4.ipfrag_time=3
net.ipv4.ipfrag_high_thresh=134217728
EOF
sudo sysctl --system
```

### 2.4 화면 (RViz)
RViz 는 컨테이너에서 X11(`/tmp/.X11-unix`, `DISPLAY`)로 뜬다. 보통 추가 설정 불필요.
`could not connect to display` 가 나면 `xhost +local:`. 화면이 없으면(SSH 접속 등) `ROVER_HEADLESS=1`.

---

## 3. 이미지 받기 (~18 GB)
`rtst_rover.pin` 의 이미지(태그)를 받고 digest 가 pin 과 같은지 확인한다 (위 "버전 고정").
```bash
. repositories/rtst_rover.pin
docker pull "$PIN_IMAGE"
docker image inspect "$PIN_IMAGE" --format '{{range .RepoDigests}}{{.}} {{end}}'   # PIN_IMAGE_DIGEST 가 보여야 함
docker run --rm --gpus all "$PIN_IMAGE" nvidia-smi                               # GPU 표가 나오면 OK
```

---

## 4. 의존 repo 30개 받기 (`src/`)
`vcs` 는 호스트에 없으므로 이미지 컨테이너에서 돌린다:
```bash
docker run --rm -it -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) -v "$PWD":/ws -w /ws \
  "$PIN_IMAGE" \
  bash -c 'vcs import src < repositories/autoware.repos'      # PIN_IMAGE: §3 처럼 pin 파일을 source
```
- 엔트리포인트(`/docker-entrypoint.sh`)를 **살려 둔다** — `HOST_UID/GID` 로 내 uid 로 바꿔 실행해 준다.
  `--entrypoint bash` 로 건너뛰면 root 로 돌아 `src/` 가 root 소유가 된다(→ git `dubious ownership`).
  doctor 는 `src/` 에 내 uid 가 아닌 파일이 있는지 본다. 복구: `sudo chown -R $(id -u):$(id -g) src` (safe.directory 로 덮지 말 것).
- 일부만 받아졌으면 같은 명령을 다시 (이미 있는 repo 는 건너뜀).

---

## 5. 중첩 fork 설정 (`src/launcher/autoware_launch.rtst_rover`)
`vcs` 는 https 로 받는다. push 만 ssh 로 바꾸고, §1 과 같은 upstream·main 잠금·훅을 단다.
```bash
N=src/launcher/autoware_launch.rtst_rover
git -C $N remote set-url --push origin git@github.com:cocobunnyfarm/autoware_launch.rtst_rover.git
git -C $N remote add upstream https://github.com/autowarefoundation/autoware_launch.git
git -C $N fetch upstream --tags
git -C $N config branch.main.pushRemote no_push
cp .git/hooks/pre-commit "$(git -C $N rev-parse --absolute-git-dir)/hooks/pre-commit"
```
작업 브랜치는 직접 고른다 (기준선만 볼 거면 master 그대로):
```bash
git -C $N branch -r
git -C $N switch <작업 브랜치>                       # 예: feat/rover-planning-params
```
⚠ 차량·센서킷·config 변경은 **이 중첩 repo 에서 커밋**한다. 바깥 repo 는 `src/` 를 추적하지 않는다.
doctor `중첩 fork 에 더 새 upstream 태그` → launch 쪽만 앞서감. pin 과 이미지를 같이 올려야 한다 (위 "버전 고정").

---

## 6. `rover` CLI 를 PATH 에 (선택)
`tools/rover` 를 어디서든 `rover` 로 부르기 위한 링크 (스크립트가 링크를 따라가 repo 루트를 스스로 찾는다).
```bash
mkdir -p ~/.local/bin && ln -sf "$PWD/tools/rover" ~/.local/bin/rover
```
링크 없이도 repo 루트에서 `./tools/rover …` 로 전부 된다. 아래 `rover` 는 둘 중 아무거나.

---

## 7. 지도
Autoware 공식 튜토리얼의 샘플 지도 (Autoware Foundation S3).
```bash
mkdir -p ~/autoware_data/maps
curl -fL -o ~/autoware_data/maps/sample-map-planning.zip \
  https://autoware-files.s3.us-west-2.amazonaws.com/maps/demos/sample-map-planning.zip
unzip -oq ~/autoware_data/maps/sample-map-planning.zip -d ~/autoware_data/maps && rm ~/autoware_data/maps/sample-map-planning.zip
```
폴더 = `lanelet2_map.osm` + `pointcloud_map.pcd` + `map_projector_info.yaml`.
다른 지도는 같은 구성의 폴더를 `~/autoware_data/maps/<이름>/` 에 두고 `ROVER_MAP=~/autoware_data/maps/<이름>` 로 지정 (doctor 도 이 변수를 본다).

---

## 8. 빌드 (우리 패키지만 오버레이)
Autoware 전체는 이미지 안에 이미 빌드돼 있다(`/opt/autoware`, underlay). 우리가 고치는 패키지만 컨테이너에서 colcon 으로 빌드해 `install/` 에 올리면(overlay), 실행할 때 `/opt/autoware` 위에 `install/` 을 겹쳐 source 해서 **같은 이름의 패키지는 우리 것이 이긴다**.
```bash
rover build                                         # 인자 없으면 아래 5개 전부
rover build <pkg> [...]                             # 일부만
```
환경 준비(setup)와 달리 이건 작업의 일부라 직접 돌린다. `install/` 이 없으면 `rover psim up` 이 "먼저 rover build" 로 멈춘다.
| 패키지 | 내용 |
|---|---|
| `rtst_rover_description` | 차량 치수(`vehicle_info`)·시뮬 모델·URDF·mesh |
| `rtst_rover_launch` | 차량 인터페이스 launch |
| `rtst_rover_sensor_kit_description` | 센서 위치(캘리브 yaml)·센서 URDF |
| `rtst_rover_sensor_kit_launch` | 센서 드라이버 launch |
| `autoware_planning_config` | 플래닝 파라미터 — 이미지에도 있지만 fork 의 yaml 을 쓰려고 덮어씀 |

- `--symlink-install` 이라 이후 yaml·xacro 수정은 **재빌드 불필요**(`rover psim restart` 만).
  새 파일 추가·`package.xml`·`CMakeLists.txt` 변경 때만 해당 패키지를 `rover build <pkg>`.
- ⚠ `--packages-up-to` 금지: `src/` 에 30개 repo 가 다 있어 의존 80여 개를 소스 빌드하려다 실패한다.

---

## 9. 기동 · 확인
`rover doctor` 전부 ✔ + `rover build` 한 상태에서:
```bash
rover psim up                                       # 중첩 fork 가 master 일 때
rover psim up planning_module_preset:=rover         # 작업 브랜치에 config/preset/rover_preset.yaml 이 있을 때
```
- 마지막에 `✔ 노드 전부 생존 (N 노드)` + RViz 창.
- RViz: **2D Pose Estimate**(차선 위) → **2D Goal Pose**(같은 차선·진행 방향) → **AUTO** → 주행·도착.
- `rover psim check` — 로드된 차량 mesh·TF(`lidar_frame` ≈ (0.132, 0, 0.132))·시뮬 파라미터·config 출처(`/ws/install/…` 이면 fork yaml 반영).

---

## 10. 일상 명령
| 명령 | 용도 |
|---|---|
| `rover doctor` | 환경 점검 (뭔가 이상할 때 먼저) |
| `rover psim restart [args]` | yaml·xacro 고친 뒤 재기동 |
| `rover psim logs` / `logs -f` | 에러·죽은 프로세스·route 실패만 / 원본 follow |
| `rover psim watch` | 주행 중 한 줄 모니터(시나리오·기어·속도·조향·오차) |
| `rover shell` | 실행 중 컨테이너 bash (setup.bash 소싱됨) |
| `rover psim down` | 종료 |
| `ROVER_HEADLESS=1 rover psim up` | RViz 없이 |

## 11. 실행 중 막히면 (doctor 로 안 잡히는 것)
| 증상 | 원인 → 해결 |
|---|---|
| `could not select device driver "" with capabilities: [[gpu]]` | nvidia 런타임 미등록 → §2.2 |
| `rmw_create_node: failed to create domain` | DDS 버퍼 → §2.3 |
| 노드 수십 개가 기동 직후 즉사 | `--cap-add=NET_ADMIN` 빠짐(엔트리포인트가 lo multicast 를 켬). `rover` 를 쓰면 들어가 있음 |
| `could not connect to display` | §2.4 |
| `Goal's footprint exceeds lane!` | goal 이 차선 밖 — 차선 중앙 근처에 진행 방향으로 |
| 노드가 `ParameterTypeException … expected [bool] got [not set]` 으로 abort | 이미지와 코드 버전 어긋남 → `rover doctor` §3 digest·§5 기준 태그 (위 "버전 고정") |
| upstream 을 당긴 뒤 이상함 | pin·이미지를 같이 안 올림 → 위 "upstream 을 올릴 때" |
