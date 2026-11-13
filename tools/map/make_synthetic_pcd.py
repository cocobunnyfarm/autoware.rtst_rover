#!/usr/bin/env python3
"""실내 합성 점군(가짜 점군) 생성 — 도면 치수로 바닥(0.1 m 격자)·벽(높이 0~1 m) 점을 찍는다.
기본 배치(연습용): 복도 10 x 1.5 m + 끝에 방 4 x 4 m, 사이에 문 구멍.
용도: Vector Map Builder 밑그림 + planning_simulator 배경(psim 은 측위가 이상적이라 점군 내용을 쓰지 않음).
출력 이름은 실측 점군과 구분되게 synthetic_*.pcd. psim 에선 pointcloud_map_file:=<이름> 으로 지정.
  python3 make_synthetic_pcd.py [출력.pcd]   (기본: ./synthetic_indoor.pcd)
"""
import sys

STEP = 0.1          # 바닥 격자 간격 [m]
WALL_H = 1.0        # 벽 높이 [m]
# 직사각형 (x0, y0, x1, y1) — 좌표는 양수로(VMB 가 MGRS 격자 안 좌표로 다룸)
CORRIDOR = (10.0, 10.0, 20.0, 11.5)
ROOM = (20.0, 8.75, 24.0, 12.75)
DOOR = (20.0, 10.0, 20.0, 11.5)    # 복도와 방이 이어지는 구간(벽 없음)


def frange(a, b, s):
    n = int(round((b - a) / s))
    return [a + i * s for i in range(n + 1)]


def floor(r):
    x0, y0, x1, y1 = r
    return [(x, y, 0.0) for x in frange(x0, x1, STEP) for y in frange(y0, y1, STEP)]


def wall(p, q):
    (xa, ya), (xb, yb) = p, q
    length = ((xb - xa) ** 2 + (yb - ya) ** 2) ** 0.5
    n = max(1, int(round(length / STEP)))
    pts = []
    for i in range(n + 1):
        t = i / n
        x, y = xa + (xb - xa) * t, ya + (yb - ya) * t
        if DOOR[0] == x == DOOR[2] and DOOR[1] < y < DOOR[3]:
            continue
        pts += [(x, y, z) for z in frange(0.0, WALL_H, STEP)]
    return pts


def box_walls(r):
    x0, y0, x1, y1 = r
    c = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    return sum((wall(c[i], c[(i + 1) % 4]) for i in range(4)), [])


pts = floor(CORRIDOR) + floor(ROOM) + box_walls(CORRIDOR) + box_walls(ROOM)
out = sys.argv[1] if len(sys.argv) > 1 else "synthetic_indoor.pcd"
with open(out, "w") as f:
    f.write("VERSION .7\nFIELDS x y z\nSIZE 4 4 4\nTYPE F F F\nCOUNT 1 1 1\n")
    f.write(f"WIDTH {len(pts)}\nHEIGHT 1\nVIEWPOINT 0 0 0 1 0 0 0\nPOINTS {len(pts)}\nDATA ascii\n")
    f.writelines(f"{x:.3f} {y:.3f} {z:.3f}\n" for x, y, z in pts)
print(f"{out}: {len(pts)} points")
