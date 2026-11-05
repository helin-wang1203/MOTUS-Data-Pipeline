"""Write simulated SensorGnome station files.

LOCAL USE ONLY. The output looks like real station data. Never upload it to
motus.org (CLAUDE.md rule 1). The default output directory is under
output/, which is gitignored, and every file carries the serial
``SG-SIMULATED00`` so it cannot be mistaken for a real receiver.

Produces hourly ``<serno>-<boot>-<timestamp>-all.txt.gz`` files with the
line types in docs/interface.md section 2.2:

* ``S`` lines at boot, one per port, tuning each FUNcube to 166.376 MHz
* ``G`` lines every ``--gps-minutes``
* ``p`` lines: background pulses at a diurnal rate per port, plus bursts
  from a few simulated Lotek tags that pass the station
* ``T`` lines: an occasional CTT tag hit on the internal radio

Faults can be injected to exercise the health monitor:

* ``--dead-port P --dead-from-hour H``   port P stops producing pulses
* ``--hot-port P --hot-hour H --hot-hours N``   noise burst on port P
* ``--outage-hour H --outage-hours N``   no file at all for those hours

Standard library only. Example::

    python3 python/sg_simulate.py --days 3 --dead-port 3 --dead-from-hour 48 \
        --out output/simulated_station
"""

from __future__ import annotations

import argparse
import gzip
import math
import random
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

SERNO = "SG-SIMULATED00"
CENTRE_MHZ = 166.376
TAG_MHZ = 166.380

# A handful of simulated Lotek tags: (id label, burst interval s, pulse gaps ms)
SIM_TAGS = [
    ("simA", 4.9, (19.1, 33.3, 25.7)),
    ("simB", 6.1, (22.9, 31.1, 20.3)),
    ("simC", 10.3, (18.3, 27.5, 30.1)),
]


def diurnal_rate(base: float, hour_of_day: int, port: int) -> float:
    """Pulses per hour: more at night (migrants), with a per-port offset."""
    return base * (1 + 0.6 * math.sin((hour_of_day - 6) / 24 * 2 * math.pi)) * (0.8 + 0.1 * port)


def simulate(out_dir: Path, days: float, ports: list[int], start: datetime, base_rate: float,
             dead_port: int | None, dead_from_hour: int, hot_port: int | None, hot_hour: int,
             hot_hours: int, outage_hour: int | None, outage_hours: int, gps_minutes: int,
             tag_passes: int, lat: float, lon: float, alt: float, seed: int) -> list[Path]:
    rng = random.Random(seed)
    out_dir.mkdir(parents=True, exist_ok=True)
    n_hours = int(round(days * 24))
    boot = 1
    written: list[Path] = []

    # Schedule tag passes: each is (start ts, duration s, tag, peak port)
    passes = []
    for _ in range(tag_passes):
        h = rng.uniform(0, n_hours)
        if outage_hour is not None and outage_hour <= h < outage_hour + outage_hours:
            continue
        passes.append((start.timestamp() + h * 3600, rng.uniform(120, 900),
                       rng.choice(SIM_TAGS), rng.choice(ports)))

    for h in range(n_hours):
        if outage_hour is not None and outage_hour <= h < outage_hour + outage_hours:
            continue                                   # receiver down: no file
        t0 = start + timedelta(hours=h)
        ts0 = t0.timestamp()
        lines: list[str] = []
        after_outage = outage_hour is not None and h == outage_hour + outage_hours
        if h == 0 or after_outage:
            if after_outage:
                boot += 1
            for p in ports:                            # settings at boot
                lines.append(f"S,{ts0:.4f},{p},-m,{CENTRE_MHZ},0,")
        # GPS fixes
        for m in range(0, 60, gps_minutes):
            ts = ts0 + m * 60 + rng.uniform(0, 2)
            lines.append(f"G,{ts:.4f},{lat + rng.gauss(0, 2e-5):.5f},{lon + rng.gauss(0, 2e-5):.5f},{alt + rng.gauss(0, 1.5):.1f}")
        # Background pulses per port
        for p in ports:
            if dead_port is not None and p == dead_port and h >= dead_from_hour:
                continue
            rate = diurnal_rate(base_rate, t0.hour, p)
            n = rng.poisson(rate) if hasattr(rng, "poisson") else _poisson(rng, rate)
            if hot_port is not None and p == hot_port and hot_hour <= h < hot_hour + hot_hours:
                n += int(50 * base_rate)
            for _ in range(n):
                ts = ts0 + rng.uniform(0, 3600)
                lines.append(f"p{p},{ts:.4f},{rng.gauss(0, 1.5):.3f},{rng.gauss(-72, 4):.1f},{rng.gauss(-85, 2):.1f}")
        # Tag passes overlapping this hour: bursts of 4 pulses with fixed gaps
        for (pstart, dur, (label, bi, gaps), peak_port) in passes:
            t = pstart
            while t < pstart + dur:
                if ts0 <= t < ts0 + 3600:
                    frac = (t - pstart) / dur
                    for p in ports:
                        if dead_port is not None and p == dead_port and h >= dead_from_hour:
                            continue
                        sig = -45 - 30 * abs(frac - 0.5) * 2 - (0 if p == peak_port else 12) + rng.gauss(0, 2)
                        if sig < -78:
                            continue
                        tt = t
                        for g in (0.0, *gaps):
                            tt += g / 1000
                            lines.append(f"p{p},{tt:.4f},{(TAG_MHZ - CENTRE_MHZ) * 1000 + rng.gauss(0, 0.2):.3f},{sig:.1f},{rng.gauss(-85, 2):.1f}")
                t += bi
        # Occasional CTT tag hit on the internal radio (port "CTT", format VERIFY)
        if rng.random() < 0.3:
            lines.append(f"TCTT,{ts0 + rng.uniform(0, 3600):.4f},{rng.choice(['3B2A91F0', '7C11D402'])},{rng.gauss(-70, 5):.1f}")

        lines.sort(key=lambda s: float(s.split(",")[1]))
        name = f"{SERNO}-{boot:06d}-{t0.strftime('%Y-%m-%dT%H-%M-%S')}.0000-all.txt.gz"
        path = out_dir / name
        with gzip.open(path, "wt", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
        written.append(path)
    return written


def _poisson(rng: random.Random, lam: float) -> int:
    """Knuth's method; fine for the rates used here."""
    L = math.exp(-lam)
    k, p = 0, 1.0
    while True:
        p *= rng.random()
        if p <= L:
            return k
        k += 1


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default="output/simulated_station")
    ap.add_argument("--days", type=float, default=2)
    ap.add_argument("--ports", default="1,2,3,4")
    ap.add_argument("--start", default="2027-02-01T00:00:00", help="UTC")
    ap.add_argument("--base-rate", type=float, default=40, help="background pulses/hour/port")
    ap.add_argument("--dead-port", type=int)
    ap.add_argument("--dead-from-hour", type=int, default=0)
    ap.add_argument("--hot-port", type=int)
    ap.add_argument("--hot-hour", type=int, default=0)
    ap.add_argument("--hot-hours", type=int, default=3)
    ap.add_argument("--outage-hour", type=int)
    ap.add_argument("--outage-hours", type=int, default=6)
    ap.add_argument("--gps-minutes", type=int, default=5)
    ap.add_argument("--tag-passes", type=int, default=4)
    ap.add_argument("--lat", type=float, default=43.7216)
    ap.add_argument("--lon", type=float, default=-72.2468)
    ap.add_argument("--alt", type=float, default=160.0)
    ap.add_argument("--seed", type=int, default=42)
    a = ap.parse_args(argv)

    start = datetime.fromisoformat(a.start).replace(tzinfo=timezone.utc)
    files = simulate(Path(a.out), a.days, [int(p) for p in a.ports.split(",")], start, a.base_rate,
                     a.dead_port, a.dead_from_hour, a.hot_port, a.hot_hour, a.hot_hours,
                     a.outage_hour, a.outage_hours, a.gps_minutes, a.tag_passes, a.lat, a.lon, a.alt, a.seed)
    print(f"Wrote {len(files)} simulated files to {a.out}  (serial {SERNO}; LOCAL ONLY, never upload)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
