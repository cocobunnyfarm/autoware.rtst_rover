# SETUP — 새 PC 에서 autoware.rtst_rover 워크스페이스 세우기

위에서 아래로 따라 하면 `rtst_rover` 차량·센서킷으로 planning_simulator 가 뜬다.
호스트에는 ROS 를 설치하지 않는다. 빌드·실행은 전부 Autoware 공식 이미지 컨테이너 안에서 한다.

- 기준 호스트: **Omarchy**(Arch 기반 → 패키지 관리자 `pacman`), Hyprland/Wayland, NVIDIA GPU. Ubuntu 는 설치 명령만 다르다.
- 명령은 전부 **호스트**에서. `/ws/…` 는 컨테이너 안 경로(= 이 repo 루트).

---

## 0. 구성 한눈에

```
autoware.rtst_rover/                         ← 이 repo (fork of autowarefoundation/autoware)
├── repositories/autoware.repos              ← 의존 repo 30개 목록. launcher 줄만 우리 fork
├── tools/rover                              ← CLI: doctor(점검) · build · psim(기동·확인) · shell
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
| 실행 이미지 | `ghcr.io/autowarefoundation/autoware:universe-cuda-jazzy` | **0.53.x** 세대. 중첩 fork 와 같은 세대여야 함 |
| 지도 | `~/autoware_data/maps/sample-map-planning` | §7 |

---

## 시작: 점검 → 자동 설치
repo 를 clone 한 직후(§3 의 `git clone` 한 줄만 먼저), repo 루트에서:
```bash
./tools/rover doctor      # 점검만 (읽기 전용). SETUP 절 순서대로 ✔ / ✘ / !, ✘ 마다 → SETUP §x
./tools/rover setup       # 점검 + 고칠 수 있는 ✘ 를 차례로 묻고(Y/n) 고침. sudo 는 필요한 단계에서만 비밀번호
./tools/rover setup -y    # 묻지 않고 전부
```
- `setup` 이 하는 일 = 아래 §1~§8 의 명령 그대로(실행 전에 `$ 명령` 을 찍는다). 고친 뒤 다시 점검하고, 새로 풀린 단계를 이어서 한다.
- **docker 그룹을 추가하면 거기서 멈춘다** — 재로그인 후 `./tools/rover setup` 을 다시 돌리면 이미지·vcs import·빌드로 이어진다.
- 자동으로 안 하는 것(직접): NVIDIA 드라이버, GitHub SSH 키 등록, 중첩 fork 작업 브랜치 선택(§5), `rover` PATH 링크(§6), 기본이 아닌 지도(`ROVER_MAP`), pacman 이 없는 배포판의 패키지 설치.
- 아래 절들은 `setup` 이 실제로 하는 일의 설명이자, 손으로 할 때의 절차다.

최소 버전 (doctor 가 판정):
| 항목 | 최소 | 이유 |
|---|---|---|
| docker | 20.10 | cgroup v2 지원 시작 (Omarchy/Arch 는 cgroup v2) |
| NVIDIA 드라이버 | 580 | 이미지가 CUDA 13 — R580 이상 필요 |
| nvidia-container-toolkit | 1.12.0 | §1.2 의 `nvidia-ctk runtime configure` |
| 디스크 여유 | 40 GB | 이미지 ~17 GB (이미지 없을 때만 확인) |

---

## 1. 호스트 준비 (1회, sudo)

### 1.1 Docker
Omarchy 는 docker 가 **기본 설치**돼 있다(`docker`·`docker-compose`·`docker-buildx`). 데몬은 `docker.socket` 이 켜져 있어 첫 접근 때 자동으로 뜬다.
그래서 보통 필요한 건 **내 계정을 docker 그룹에** 넣는 것뿐:
```bash
sudo usermod -aG docker "$USER"
# ⚠ 다시 로그인해야 적용 (지금 셸만: newgrp docker)
```
- doctor `docker 그룹 아님` / `현재 세션 미적용` → 위 명령 / 재로그인.
- doctor `docker 없음` (Omarchy 가 아닌 Arch) → `sudo pacman -S docker docker-compose docker-buildx && sudo systemctl enable --now docker.socket`. Ubuntu → docs.docker.com/engine/install/ubuntu.
- doctor `데몬 꺼짐` → `sudo systemctl enable --now docker.socket`.

### 1.2 GPU 를 컨테이너로 (nvidia-container-toolkit)
호스트 NVIDIA 드라이버는 이미 있어야 한다(`nvidia-smi`). Omarchy 는 toolkit 이 **기본에 없다**.
```bash
sudo pacman -S --needed nvidia-container-toolkit   # Ubuntu: NVIDIA apt repo 에서 같은 이름
sudo nvidia-ctk runtime configure --runtime=docker # /etc/docker/daemon.json 에 nvidia 런타임 추가
sudo systemctl restart docker
```

### 1.3 DDS 커널 버퍼
Autoware(CycloneDDS) 큰 메시지용. Omarchy 기본값(`rmem_max` 4 MB)으로는 부족하다 — 없으면 노드가 `rmw_create_node: failed to create domain` 으로 죽는다.
```bash
sudo tee /etc/sysctl.d/60-autoware-dds.conf > /dev/null <<'EOF'
net.core.rmem_max=2147483647
net.ipv4.ipfrag_time=3
net.ipv4.ipfrag_high_thresh=134217728
EOF
sudo sysctl --system
```

### 1.4 화면 (RViz)
RViz 는 컨테이너에서 X11(`/tmp/.X11-unix`, `DISPLAY`)로 뜬다. Hyprland 는 Xwayland 가 로컬 소켓을 허용해 **추가 설정 불필요**.
다른 데스크톱에서 `could not connect to display` 가 나면: `sudo pacman -S xorg-xhost && xhost +local:`.
SSH 접속 등 화면이 없으면 `ROVER_HEADLESS=1`.

### 1.5 git 작성자 · GitHub SSH 키
```bash
git config --global user.name  "Ted Lee"
git config --global user.email "cocobunnyfarm@gmail.com"
```
(없으면 커밋이 `Author identity unknown` 으로 거부된다.)
push 는 ssh(`git@github.com:…`). doctor `GitHub SSH 실패` → 키가 agent 에 없으면 `ssh-add`, GitHub 에 미등록이면 등록.

---

## 2. 이미지 받기 (~17 GB)
```bash
docker pull ghcr.io/autowarefoundation/autoware:universe-cuda-jazzy
docker run --rm --gpus all ghcr.io/autowarefoundation/autoware:universe-cuda-jazzy nvidia-smi   # GPU 표가 나오면 OK
```
doctor 가 이미지 안 `autoware_launch` 버전을 읽어 §5 에서 중첩 fork 와 세대를 비교한다.

---

## 3. 이 repo clone + git 설정
원하는 폴더에서:
```bash
git clone git@github.com:cocobunnyfarm/autoware.rtst_rover.git      # 기본 브랜치 = master
cd autoware.rtst_rover

git remote add upstream https://github.com/autowarefoundation/autoware.git
git fetch upstream --tags
git branch -u upstream/main main 2>/dev/null || git branch --track main upstream/main   # main = upstream 거울
git config branch.main.pushRemote no_push           # main 에서 push 불가
git config remote.pushDefault origin

# main 에서 실수로 커밋 못 하게 (훅은 clone 으로 안 따라온다)
cat > .git/hooks/pre-commit <<'EOF'
#!/bin/sh
[ "$(git symbolic-ref --short HEAD 2>/dev/null)" = main ] && { echo "main 은 upstream 거울 — 커밋 금지 (master 나 feat/* 에서)"; exit 1; }
exit 0
EOF
chmod +x .git/hooks/pre-commit
```

---

## 4. 의존 repo 30개 받기 (`src/`)
`vcs` 는 호스트에 없으므로 이미지 컨테이너에서 돌린다. **이 repo 루트에서** (§1.1·§2 가 끝나 있어야 함):
```bash
docker run --rm -it -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) -v "$PWD":/ws -w /ws \
  ghcr.io/autowarefoundation/autoware:universe-cuda-jazzy \
  bash -c 'vcs import src < repositories/autoware.repos'
```
- 엔트리포인트(`/docker-entrypoint.sh`)를 **살려 둔다** — `HOST_UID/GID` 로 내 uid 로 바꿔 실행해 준다.
  `--entrypoint bash` 로 건너뛰면 root 로 돌아 `src/` 가 root 소유가 된다(→ git `dubious ownership`).
  doctor `다른 소유자 파일 있음` → `sudo chown -R $(id -u):$(id -g) src` (safe.directory 로 덮지 말 것).
- 일부만 받아졌으면 같은 명령을 다시 (이미 있는 repo 는 건너뜀).

---

## 5. 중첩 fork 설정 (`src/launcher/autoware_launch.rtst_rover`)
`vcs` 는 https 로 받는다. push 만 ssh 로 바꾸고, upstream 과 main 잠금을 단다.
```bash
N=src/launcher/autoware_launch.rtst_rover
git -C $N remote set-url --push origin git@github.com:cocobunnyfarm/autoware_launch.rtst_rover.git
git -C $N remote add upstream https://github.com/autowarefoundation/autoware_launch.git
git -C $N fetch upstream --tags
git -C $N config branch.main.pushRemote no_push
cp .git/hooks/pre-commit "$(git -C $N rev-parse --absolute-git-dir)/hooks/pre-commit"

git -C $N branch -r                                 # 작업 브랜치 확인
git -C $N switch <작업 브랜치>                       # 예: feat/rover-planning-params. 기준선만 볼 거면 master 그대로
```
⚠ 차량·센서킷·config 변경은 **이 중첩 repo 에서 커밋**한다. 바깥 repo 는 `src/` 를 추적하지 않는다.
doctor `세대 불일치` → 이미지와 중첩 fork 의 `autoware_launch` 버전(앞 두 자리)이 다르다. `docker pull` 또는 fork 갱신.

---

## 6. `rover` CLI 를 PATH 에 (선택)
`tools/rover` 를 어디서든 `rover` 로 부르기 위한 링크 (스크립트가 링크를 따라가 repo 루트를 스스로 찾는다).
```bash
mkdir -p ~/.local/bin
ln -sf "$PWD/tools/rover" ~/.local/bin/rover
```
링크 없이도 repo 루트에서 `./tools/rover …` 로 전부 된다. 아래 `rover` 는 둘 중 아무거나.

---

## 7. 지도
Autoware 공식 튜토리얼의 샘플 지도 (Autoware Foundation S3).
```bash
mkdir -p ~/autoware_data/maps && cd ~/autoware_data/maps
curl -fLO https://autoware-files.s3.us-west-2.amazonaws.com/maps/demos/sample-map-planning.zip
unzip -o sample-map-planning.zip && rm sample-map-planning.zip
cd -
```
폴더 = `lanelet2_map.osm` + `pointcloud_map.pcd` + `map_projector_info.yaml`.
다른 지도는 같은 구성의 폴더를 `~/autoware_data/maps/<이름>/` 에 두고 `ROVER_MAP=~/autoware_data/maps/<이름>` 로 지정 (doctor 도 이 변수를 본다).

---

## 8. 빌드 (우리 패키지만 오버레이)
Autoware 전체는 이미지에 프리빌트(`/opt/autoware`)로 있다. 우리 패키지만 `--packages-select` 로 올린다. **repo 루트에서**:
```bash
rover build rtst_rover_description rtst_rover_launch \
            rtst_rover_sensor_kit_description rtst_rover_sensor_kit_launch \
            autoware_planning_config
```
- `--symlink-install` 이라 이후 yaml·xacro 수정은 **재빌드 불필요**(`rover psim restart` 만).
  새 파일 추가·`package.xml`·`CMakeLists.txt` 변경 때만 해당 패키지를 `rover build <pkg>`.
- ⚠ `--packages-up-to` 금지: `src/` 에 30개 repo 가 다 있어 의존 80여 개를 소스 빌드하려다 실패한다.

---

## 9. 기동 · 확인
`rover doctor` 가 전부 ✔ 인 상태에서:
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
| `could not select device driver "" with capabilities: [[gpu]]` | nvidia 런타임 미등록 → §1.2 |
| `rmw_create_node: failed to create domain` | DDS 버퍼 → §1.3 |
| 노드 수십 개가 기동 직후 즉사 | `--cap-add=NET_ADMIN` 빠짐(엔트리포인트가 lo multicast 를 켬). `rover` 를 쓰면 들어가 있음 |
| `could not connect to display` | §1.4 |
| `Goal's footprint exceeds lane!` | goal 이 차선 밖 — 차선 중앙 근처에 진행 방향으로 |
| upstream 을 당긴 뒤 이상함 | 중첩 fork 와 이미지 세대 불일치 → `docker pull` 같이 (doctor §5) |
