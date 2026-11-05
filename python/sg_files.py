"""Parse raw SensorGnome station files.

Reads the hourly ``<serno>-<boot>-<timestamp>-all.txt.gz`` files a SensorGnome
writes and turns them into flat tables:

* ``pulses``   one row per 166 MHz pulse (``p`` lines)
* ``tags``     one row per CTT tag hit (``T`` lines)
* ``gps``      one row per GPS fix (``G`` lines)
* ``settings`` one row per radio setting (``S`` lines)
* ``hourly``   pulses per port per UTC hour, in the same shape as the
               ``antenna_activity`` handoff table (batchID, port, hour,
               n_pulses) so ``R/antenna_health.R`` can read it directly.

The line formats follow docs/interface.md section 2.2. Fields marked VERIFY
there are parsed leniently: extra fields are kept in ``extra``, and lines
that do not parse are counted, not fatal.

Standard library only. Usage::

    python3 python/sg_files.py <dir-or-file>... --out output/station

which writes pulses.csv, tags.csv, gps.csv, settings.csv, hourly.csv and
summary.json into ``--out``.
"""

from __future__ import annotations

import argparse
import csv
import gzip
import io
import json
import re
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Iterator

# <serno>-<bootcount>-<YYYY-MM-DDTHH-MM-SS.ffff>-<suffix>.txt(.gz)
FILENAME_RE = re.compile(
    r"^(?P<serno>[A-Za-z0-9]+-[A-Za-z0-9]+)-(?P<boot>\d+)-"
    r"(?P<stamp>\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}(?:\.\d+)?)-(?P<suffix>[a-z]+)\.txt(?:\.gz)?$"
)


@dataclass
class FileInfo:
    path: str
    serno: str
    boot: int
    started: datetime
    suffix: str


@dataclass
class Pulse:
    file: str
    boot: int
    port: str
    ts: float
    dfreq: float
    sig: float
    noise: float


@dataclass
class TagHit:
    file: str
    boot: int
    port: str
    ts: float
    tag_id: str
    sig: float | None
    extra: list[str] = field(default_factory=list)


@dataclass
class GpsFix:
    file: str
    boot: int
    ts: float
    lat: float
    lon: float
    alt: float | None


@dataclass
class Setting:
    file: str
    boot: int
    ts: float
    port: str
    param: str
    value: str
    rc: str
    err: str


@dataclass
class ParseResult:
    files: list[FileInfo] = field(default_factory=list)
    pulses: list[Pulse] = field(default_factory=list)
    tags: list[TagHit] = field(default_factory=list)
    gps: list[GpsFix] = field(default_factory=list)
    settings: list[Setting] = field(default_factory=list)
    skipped: Counter = field(default_factory=Counter)   # record type -> count of unparsed lines
    unknown_types: Counter = field(default_factory=Counter)

    def hourly(self) -> list[dict]:
        """Pulses per port per UTC hour, shaped like antenna_activity.

        batchID is the boot count: one receiver session. Only port-hours that
        had at least one pulse appear; R/antenna_health.R fills the rest with
        zeros for hours in which any port reported.
        """
        counts: dict[tuple[int, str, int], int] = defaultdict(int)
        for p in self.pulses:
            hour = int(p.ts // 3600) * 3600
            counts[(p.boot, p.port, hour)] += 1
        rows = [
            {"batchID": boot, "port": port,
             "hour": datetime.fromtimestamp(hour, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S"),
             "n_pulses": n}
            for (boot, port, hour), n in counts.items()
        ]
        rows.sort(key=lambda r: (r["batchID"], r["port"], r["hour"]))
        return rows

    def summary(self) -> dict:
        def span(ts: Iterable[float]) -> dict:
            ts = list(ts)
            if not ts:
                return {"n": 0}
            return {"n": len(ts),
                    "first_utc": datetime.fromtimestamp(min(ts), tz=timezone.utc).isoformat(),
                    "last_utc": datetime.fromtimestamp(max(ts), tz=timezone.utc).isoformat()}
        return {
            "files": len(self.files),
            "receivers": sorted({f.serno for f in self.files}),
            "boots": sorted({f.boot for f in self.files}),
            "pulses": span(p.ts for p in self.pulses),
            "pulses_by_port": dict(sorted(Counter(p.port for p in self.pulses).items())),
            "tags": span(t.ts for t in self.tags),
            "gps": span(g.ts for g in self.gps),
            "settings": len(self.settings),
            "skipped_lines": dict(self.skipped),
            "unknown_record_types": dict(self.unknown_types),
        }


def parse_filename(path: Path) -> FileInfo | None:
    m = FILENAME_RE.match(path.name)
    if not m:
        return None
    stamp = m.group("stamp")
    fmt = "%Y-%m-%dT%H-%M-%S.%f" if "." in stamp else "%Y-%m-%dT%H-%M-%S"
    started = datetime.strptime(stamp, fmt).replace(tzinfo=timezone.utc)
    return FileInfo(str(path), m.group("serno"), int(m.group("boot")), started, m.group("suffix"))


def open_text(path: Path) -> io.TextIOBase:
    if path.suffix == ".gz":
        return io.TextIOWrapper(gzip.open(path, "rb"), encoding="utf-8", errors="replace")
    return open(path, encoding="utf-8", errors="replace")


def parse_line(line: str, info: FileInfo, out: ParseResult) -> None:
    line = line.rstrip("\r\n")
    if not line:
        return
    kind = line[0]
    fields = line.split(",")
    try:
        if kind == "p":                                   # p<port>,ts,dfreq,sig,noise
            out.pulses.append(Pulse(info.path, info.boot, fields[0][1:], float(fields[1]),
                                    float(fields[2]), float(fields[3]), float(fields[4])))
        elif kind == "T":                                 # T<port>,ts,tagID[,sig[,...]]  (VERIFY)
            sig = float(fields[3]) if len(fields) > 3 and fields[3] != "" else None
            out.tags.append(TagHit(info.path, info.boot, fields[0][1:], float(fields[1]),
                                   fields[2], sig, fields[4:]))
        elif kind == "G":                                 # G,ts,lat,lon[,alt]
            alt = float(fields[4]) if len(fields) > 4 and fields[4] != "" else None
            out.gps.append(GpsFix(info.path, info.boot, float(fields[1]),
                                  float(fields[2]), float(fields[3]), alt))
        elif kind == "S":                                 # S,ts,port,param,value,rc,err
            f = fields + [""] * (7 - len(fields))
            out.settings.append(Setting(info.path, info.boot, float(f[1]), f[2], f[3], f[4], f[5], f[6]))
        elif kind == "C":                                 # clock records: not used yet
            out.skipped["C"] += 1
        else:
            out.unknown_types[kind] += 1
    except (IndexError, ValueError):
        out.skipped[kind] += 1


def iter_files(paths: Iterable[str | Path]) -> Iterator[Path]:
    for p in paths:
        p = Path(p)
        if p.is_dir():
            yield from sorted(q for q in p.rglob("*.txt*") if q.is_file())
        elif p.is_file():
            yield p


def parse(paths: Iterable[str | Path]) -> ParseResult:
    out = ParseResult()
    for path in iter_files(paths):
        info = parse_filename(path)
        if info is None:
            out.skipped["unrecognised filename"] += 1
            continue
        out.files.append(info)
        with open_text(path) as fh:
            for line in fh:
                parse_line(line, info, out)
    return out


def write_csv(rows: list, path: Path) -> None:
    if not rows:
        path.write_text("")
        return
    rows = [asdict(r) if not isinstance(r, dict) else r for r in rows]
    with open(path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="+", help="SensorGnome files or directories")
    ap.add_argument("--out", required=True, help="directory for CSV/JSON output")
    args = ap.parse_args(argv)

    res = parse(args.paths)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    write_csv(res.pulses, out / "pulses.csv")
    write_csv(res.tags, out / "tags.csv")
    write_csv(res.gps, out / "gps.csv")
    write_csv(res.settings, out / "settings.csv")
    write_csv(res.hourly(), out / "hourly.csv")
    summary = res.summary()
    (out / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))
    return 0 if res.files else 1


if __name__ == "__main__":
    sys.exit(main())
