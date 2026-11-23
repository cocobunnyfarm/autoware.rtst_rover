#!/usr/bin/env python3
"""real_probe.py — rover real check 가 컨테이너 안에서 돌리는 측정 (노드 하나, ros2 데몬 안 씀).

토픽마다 ros2 topic hz 를 따로 띄우면 부하가 있을 때 발견이 제한 시간 안에 안 끝나 "안 나옴"으로 잘못 찍힌다
[실측 2026-11-22]. 그래서 한 노드가 전부 구독하고, 처음 몇 초(발견 시간)는 버린 뒤 도착 간격을 잰다.
  real_probe.py [측정 초=8]
"""
import sys
import time
import unicodedata

import rclpy
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, QoSProfile, ReliabilityPolicy

from autoware_adapi_v1_msgs.msg import LocalizationInitializationState, RouteState
from autoware_control_msgs.msg import Control
from autoware_vehicle_msgs.msg import ControlModeReport, VelocityReport
from nav_msgs.msg import Odometry
from tier4_system_msgs.msg import OperationModeAvailability

WARMUP = 3.0
DURATION = float(sys.argv[1]) if len(sys.argv) > 1 else 8.0

RATES = {
    "/odom": Odometry,
    "/vehicle/status/velocity_status": VelocityReport,
    "/localization/kinematic_state": Odometry,
    "/control/command/control_cmd": Control,
}

rclpy.init()
node = Node("rover_real_probe")
node.get_logger().set_level(rclpy.logging.LoggingSeverity.ERROR)   # QoS 가 안 맞는 쪽 구독의 경고는 의도한 것 — 숨긴다
best_effort = QoSProfile(depth=50, reliability=ReliabilityPolicy.BEST_EFFORT)
latched = QoSProfile(depth=1, reliability=ReliabilityPolicy.RELIABLE, durability=DurabilityPolicy.TRANSIENT_LOCAL)

stamps = {k: [] for k in RATES}
last = {}
for topic, cls in RATES.items():
    node.create_subscription(cls, topic, lambda m, k=topic: (stamps[k].append(time.monotonic()), last.__setitem__(k, m)), best_effort)
# 상태 토픽: 발행 쪽 QoS 가 제각각이라 두 가지로 다 구독한다 (맞는 쪽으로만 온다)
STATES = {
    "/vehicle/status/control_mode": ControlModeReport,
    "/api/localization/initialization_state": LocalizationInitializationState,
    "/api/routing/state": RouteState,
    "/system/operation_mode/availability": OperationModeAvailability,
}
for topic, cls in STATES.items():
    for qos in (latched, best_effort):
        node.create_subscription(cls, topic, lambda m, k=topic: last.__setitem__(k, m), qos)

def pad(text, width=38):
    """한글은 화면에서 두 칸을 차지한다 — 보이는 폭으로 맞춘다."""
    w = sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in text)
    return text + " " * max(1, width - w)


t0 = time.monotonic()
while time.monotonic() - t0 < WARMUP + DURATION:
    rclpy.spin_once(node, timeout_sec=0.05)

for topic in RATES:
    v = [t for t in stamps[topic] if t > t0 + WARMUP]
    if len(v) < 3:
        print(f"  {pad(topic)}(안 나옴 — {DURATION:.0f}초 동안 메시지 {len(v)}개)")
        continue
    gaps = [(b - a) * 1000 for a, b in zip(v, v[1:])]
    print(f"  {pad(topic)}{(len(v) - 1) / (v[-1] - v[0]):5.1f} Hz   간격 최대 {max(gaps):5.0f} ms")


def show(label, topic, field):
    m = last.get(topic)
    print(f"  {pad(label)}{field(m) if m is not None else '?  (메시지 없음)'}")


show("제어 모드 (1 AUTONOMOUS, 4 MANUAL)", "/vehicle/status/control_mode", lambda m: m.mode)
show("측위 초기화 (1 미완, 3 완료)", "/api/localization/initialization_state", lambda m: m.state)
show("경로 (1 없음, 2 설정됨, 3 도착)", "/api/routing/state", lambda m: m.state)
show("AUTO 가능", "/system/operation_mode/availability", lambda m: m.autonomous)
m = last.get("/localization/kinematic_state")
print("  " + pad("위치 xy") + (f"x: {m.pose.pose.position.x:.2f}  y: {m.pose.pose.position.y:.2f}" if m else "(초기 위치 전)"))
