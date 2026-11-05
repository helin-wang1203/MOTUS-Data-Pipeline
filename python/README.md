# Station-side tools

Python 3.11+, standard library only. Run everything from the repo root.

| Script | Purpose |
|---|---|
| `sg_files.py` | Parse raw SensorGnome files into CSV tables, including an hourly pulse-count table shaped like the `antenna_activity` handoff table |
| `sg_simulate.py` | Write simulated station files with injected faults, for testing the health monitor. **Local only; never upload to Motus** |
| `tests/` | Round-trip tests: simulate, parse, check |

```sh
python3 -m unittest discover -s python/tests            # tests
python3 python/sg_simulate.py --days 3 --dead-port 3 --dead-from-hour 48 \
    --outage-hour 30 --out output/simulated_station     # fake station
python3 python/sg_files.py output/simulated_station --out output/station   # parse
Rscript -e 'source("R/antenna_health.R"); a <- read.csv("output/station/hourly.csv");
            a$hour <- as.POSIXct(a$hour, tz = "UTC"); print(antenna_health(a)$spells)'
```

The parser is tolerant: lines it cannot parse are counted in `summary.json`
under `skipped_lines`, and record types it does not know under
`unknown_record_types`. If either is non-zero on real farm files, the line
formats in `docs/interface.md` section 2.2 need updating, and so does
`parse_line()` here.

The line formats and filename pattern are the SensorGnome conventions as
documented in `docs/interface.md`. Items marked VERIFY there (the `T` and
`C` line fields, the exact filename of the CTT image) have not yet been
checked against a real file from the farm station.
