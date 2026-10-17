#!/usr/bin/env python3
"""Synthetic Shepherd record data for the Stone Soup tracker bench.

Generates one 60 s run at 4 Hz: two crossing targets (A: west->east,
B: south->north, crossing mid-run) plus one distractor walker (C, small
signature, random walk). Four mesh nodes, six links. Each link's dip is
the sum of per-target Gaussian proximity dips plus noise and rare
clutter spikes.

Output schema (Shepherd record CSV):
  t_iso,link_key,from_node,to_node,snr_db,dip_db,truth_x,truth_y,truth_id

truth_* columns are the DOMINANT contributor on that link at that time
(empty when no target is near any link) -- they exist so the bench can
score tracks, not as something the real recorder would know.
"""
import csv
import math
import os
import random
import sys
from datetime import datetime, timedelta, timezone

SEED = 7
DURATION_S = 60.0
DT = 0.25  # 4 Hz
T0 = datetime(2026, 10, 16, 22, 0, 0, tzinfo=timezone.utc)

NODES = {
    "n0": (0.0, 0.0),
    "n1": (40.0, 0.0),
    "n2": (40.0, 40.0),
    "n3": (0.0, 40.0),
}
LINKS = [("n0", "n1"), ("n1", "n2"), ("n2", "n3"),
         ("n3", "n0"), ("n0", "n2"), ("n1", "n3")]

SIGMA_M = 5.0        # disturbance falloff distance (m)
BASE_SNR = 22.0      # quiet link SNR (dB)
NOISE_DB = 0.4       # measurement noise on dip (dB)
CLUTTER_P = 0.02     # per link-step chance of a clutter spike
CLUTTER_DB = (2.0, 4.0)


def seg_dist(px, py, ax, ay, bx, by):
    """Distance from point P to segment AB."""
    dx, dy = bx - ax, by - ay
    l2 = dx * dx + dy * dy
    if l2 == 0:
        return math.hypot(px - ax, py - ay)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / l2))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


class Target:
    def __init__(self, tid, x0, y0, vx, vy, d0, walker=False):
        self.tid = tid
        self.x, self.y = x0, y0
        self.vx, self.vy = vx, vy
        self.d0 = d0
        self.walker = walker
        self.heading = math.atan2(vy, vx) if (vx or vy) else 0.0

    def step(self, rng):
        if self.walker:
            # slow random walk, bounced inside the field
            self.heading += rng.gauss(0.0, 0.45)
            speed = 0.8
            nx = self.x + math.cos(self.heading) * speed * DT
            ny = self.y + math.sin(self.heading) * speed * DT
            if not (2.0 <= nx <= 38.0):
                self.heading = math.pi - self.heading
                nx = min(max(nx, 2.0), 38.0)
            if not (2.0 <= ny <= 38.0):
                self.heading = -self.heading
                ny = min(max(ny, 2.0), 38.0)
            self.x, self.y = nx, ny
        else:
            self.x += self.vx * DT
            self.y += self.vy * DT

    def dip_on(self, ax, ay, bx, by):
        d = seg_dist(self.x, self.y, ax, ay, bx, by)
        return self.d0 * math.exp(-(d * d) / (2 * SIGMA_M * SIGMA_M))


def generate():
    rng = random.Random(SEED)
    targets = [
        Target("A", -6.0, 18.0, 1.55, 0.08, 8.0),   # west -> east
        Target("B", 22.0, -6.0, 0.06, 1.32, 8.0),   # south -> north
        Target("C", 33.0, 9.0, 0.8, 0.0, 3.0, walker=True),  # distractor
    ]
    rows = []
    n_steps = int(DURATION_S / DT)
    for s in range(n_steps):
        t = T0 + timedelta(seconds=s * DT)
        t_iso = t.isoformat()
        for (fa, fb) in LINKS:
            ax, ay = NODES[fa]
            bx, by = NODES[fb]
            contribs = [(tg.dip_on(ax, ay, bx, by), tg) for tg in targets]
            dom_dip, dom = max(contribs, key=lambda c: c[0])
            dip = sum(c[0] for c in contribs) + rng.gauss(0.0, NOISE_DB)
            if rng.random() < CLUTTER_P:
                dip += rng.uniform(*CLUTTER_DB)
            dip = max(0.0, dip)
            snr = BASE_SNR - dip + rng.gauss(0.0, 0.3)
            if dom_dip >= 0.5:
                tx, ty, tid = f"{dom.x:.2f}", f"{dom.y:.2f}", dom.tid
            else:
                tx, ty, tid = "", "", ""
            rows.append({
                "t_iso": t_iso,
                "link_key": f"{fa}>{fb}",
                "from_node": fa,
                "to_node": fb,
                "snr_db": f"{snr:.2f}",
                "dip_db": f"{dip:.2f}",
                "truth_x": tx,
                "truth_y": ty,
                "truth_id": tid,
            })
        for tg in targets:
            tg.step(rng)
    return rows


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "sample_run.csv")
    rows = generate()
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=[
            "t_iso", "link_key", "from_node", "to_node",
            "snr_db", "dip_db", "truth_x", "truth_y", "truth_id"])
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {len(rows)} rows -> {out}")


if __name__ == "__main__":
    main()
