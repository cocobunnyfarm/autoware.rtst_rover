#!/usr/bin/env python3
"""rover psim watch — 주행 중 제어·플래닝 상태를 0.5 s 마다 한 줄로. 컨테이너 안에서 실행(rover 가 호출)."""
import math, subprocess, sys, time
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, DurabilityPolicy
from rosidl_runtime_py.utilities import get_message

TOPICS = {  # 이름: (토픽, 저장 키)
    "ego":   "/localization/kinematic_state",
    "traj":  "/planning/trajectory",
    "cmd":   "/control/command/control_cmd",
    "steer": "/vehicle/status/steering_status",
    "gear":  "/vehicle/status/gear_status",
    "scen":  "/planning/scenario_planning/scenario",
    "mode":  "/api/operation_mode/state",
    "pval":  "/planning/planning_validator/validation_status",
    "cval":  "/control/control_validator/validation_status",
}
GEAR = {1: "N", 2: "D", 20: "R", 22: "P"}
MODE = {1: "STOP", 2: "AUTO", 3: "LOCAL", 4: "REMOTE"}

def yaw_of(q):
    return math.atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))

def topic_type(topic):
    out = subprocess.run(["ros2", "topic", "type", topic], capture_output=True, text=True).stdout.strip()
    return out.splitlines()[0] if out else None

class Watch(Node):
    def __init__(self):
        super().__init__("rover_psim_watch")
        self.msgs = {}
        qos_v = QoSProfile(depth=1, reliability=ReliabilityPolicy.BEST_EFFORT)
        qos_t = QoSProfile(depth=1, reliability=ReliabilityPolicy.RELIABLE, durability=DurabilityPolicy.TRANSIENT_LOCAL)
        for key, topic in TOPICS.items():
            t = topic_type(topic)
            if not t:
                print(f"(토픽 없음: {topic})", file=sys.stderr); continue
            qos = qos_t if key == "mode" else qos_v
            self.create_subscription(get_message(t), topic, lambda m, k=key: self.msgs.__setitem__(k, m), qos)
        self.create_timer(0.5, self.tick)
        print("   시각 | scen | gear | mode | ego v | cmd v | cmd acc | steer 실측/명령 [rad] | 근접점 v | 횡오차[m] | yaw오차[deg] | 궤적끝까지[m] | plan ok | ctrl ok")

    def tick(self):
        m = self.msgs
        row = [time.strftime("%H:%M:%S")]
        scen = getattr(m.get("scen"), "current_scenario", "?")
        row.append(f"{str(scen)[:4]:>4}")
        row.append(f"{GEAR.get(getattr(m.get('gear'), 'report', 0), '?'):>4}")
        row.append(f"{MODE.get(getattr(m.get('mode'), 'mode', 0), '?'):>5}")
        ego = m.get("ego"); traj = m.get("traj"); cmd = m.get("cmd")
        ev = ego.twist.twist.linear.x if ego else float("nan")
        row.append(f"{ev:6.2f}")
        if cmd:
            row.append(f"{cmd.longitudinal.velocity:6.2f}"); row.append(f"{cmd.longitudinal.acceleration:7.2f}")
            sc = cmd.lateral.steering_tire_angle
        else:
            row += ["     ?", "      ?"]; sc = float("nan")
        sm = m["steer"].steering_tire_angle if m.get("steer") else float("nan")
        row.append(f"{sm:6.3f}/{sc:6.3f}")
        if ego and traj and len(traj.points) > 1:
            px, py, pyaw = ego.pose.pose.position.x, ego.pose.pose.position.y, yaw_of(ego.pose.pose.orientation)
            pts = traj.points
            i = min(range(len(pts)), key=lambda k: (pts[k].pose.position.x - px) ** 2 + (pts[k].pose.position.y - py) ** 2)
            p = pts[i]; tyaw = yaw_of(p.pose.orientation)
            dx, dy = px - p.pose.position.x, py - p.pose.position.y
            lat = -math.sin(tyaw) * dx + math.cos(tyaw) * dy
            yerr = math.degrees((pyaw - tyaw + math.pi) % (2 * math.pi) - math.pi)
            rem = sum(math.hypot(pts[k + 1].pose.position.x - pts[k].pose.position.x, pts[k + 1].pose.position.y - pts[k].pose.position.y) for k in range(i, len(pts) - 1))
            row += [f"{p.longitudinal_velocity_mps:6.2f}", f"{lat:7.2f}", f"{yerr:8.0f}", f"{rem:8.1f}"]
        else:
            row += ["     ?", "      ?", "       ?", "       ?"]
        pv = m.get("pval"); cv = m.get("cval")
        row.append(f"{'ok' if pv is None or all(getattr(pv, f) for f in dir(pv) if f.startswith('is_valid')) else 'NG':>7}")
        row.append(f"{'ok' if cv is None or all(getattr(cv, f) for f in dir(cv) if f.startswith('is_valid')) else 'NG':>7}")
        print(" | ".join(row), flush=True)

def main():
    rclpy.init()
    n = Watch()
    try:
        rclpy.spin(n)
    except KeyboardInterrupt:
        pass
    finally:
        n.destroy_node(); rclpy.try_shutdown()

if __name__ == "__main__":
    main()
