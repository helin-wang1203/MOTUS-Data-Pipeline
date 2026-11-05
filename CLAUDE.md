# CLAUDE.md — Motus Station Data Pipeline

Read this first. It tells you what this repo is, how it is laid out, the rules for
working in it, and what to build next.

## What this project is

An ENGS 89/190 capstone at Dartmouth (Fall 2026 – Winter 2027). The team is installing a
Motus wildlife-tracking station at the Dartmouth Organic Farm. Motus is a shared network of
radio receivers that detect tiny transmitters ("tags") carried by migratory birds, bats,
and insects. Detections from every station go to motus.org, where they are matched to
registered tags and shared with researchers.

This repo holds the **data side** of the station, owned by Helin Wang: turning station
output into clean tables, tracks, and visualizations for researchers, students, and the
public. The hardware (antennas, cabling, power, mast) is handled by teammates and is not
in this repo.

### The station hardware, in one paragraph

A CTT SensorStation V3 (a Raspberry Pi Compute Module running SensorGnome software) records
two bands. **434 MHz CTT LifeTags** are decoded by radios built into the SensorStation.
**166.380 MHz Lotek NanoTags** are received by four FUNcube Dongle Pro+ SDRs on its USB
ports, one per 166 MHz antenna (3 Yagis and 1 omni), tuned to 166.376 MHz. Lotek tags send
bursts of pulses whose spacing encodes the tag ID, so the station records raw pulses and the
Motus server identifies tags later. Files upload over the barn's Ethernet, with Wi-Fi and
manual offload as fallbacks.

## End-to-end data flow

| # | Stage | Who does it | Form of the data |
|---|---|---|---|
| 1 | Recording on SensorStation | Existing (SensorGnome, CTT firmware) | Hourly `.txt.gz` files: pulse lines, CTT tag lines, GPS, settings |
| 2 | Upload to motus.org | Existing; we configure and verify | Same files, unchanged |
| 3 | Tag finding on Motus servers | Existing | Hits and runs matched to registered tags |
| 4 | Download into R | Existing (`motus` R package, `tagme()`) | Local SQLite `.motus` file |
| 5 | Cleaning | **This repo** | Filtered detections + cleaning log |
| 6 | Visits, legs, summaries | **This repo** | Handoff tables |
| 7 | Visualizations | **This repo** | Plots, maps, Quarto site |
| — | Station health (side path) | **This repo** | Raw station files → per-antenna health metrics |

Do not reimplement stages 1–4. Build on them.

## Repo layout

```
.
├── CLAUDE.md                 # this file
├── README.md                 # human-facing overview (keep short)
├── R/
│   ├── clean_motus.R         # stages 4–6: download, clean, build handoff tables
│   ├── antenna_health.R      # health rules + thresholds (no side effects)
│   ├── simulate_antenna_activity.R  # synthetic antenna_activity with known faults (local only)
│   └── views/                # stage 7: one script per view
│       ├── station_map.R     # regional receiver map → output/figures/
│       ├── flyby.R           # signal vs time per antenna for one visit
│       ├── track_map.R       # one tag's stops in time order + all-tag overview
│       ├── activity_calendar.R  # date × hour heatmap of tags detected, by species
│       └── antenna_health.R  # pulses/hour per antenna with flat/hot spells flagged
├── python/                   # station-side tools (stdlib only)
│   ├── sg_files.py           # parse raw SensorGnome files → CSV incl. hourly pulse counts
│   ├── sg_simulate.py        # write simulated station files with faults (LOCAL ONLY)
│   └── tests/test_sg_files.py
├── tests/
│   ├── test_cleaning.R       # synthetic-data tests for clean_motus.R
│   └── test_antenna_health.R # simulated-fault tests for antenna_health.R
├── docs/
│   └── interface.md          # interface control document (boundaries, units, port map, health)
├── data/                     # downloaded .motus files — gitignored
└── output/                   # generated tables and figures — gitignored
```

Run everything from the repo root, for example `Rscript R/clean_motus.R`.

## The handoff tables (the interface)

Every visualization reads **only** from these tables in `output/`, never from Motus
directly. This is what lets us develop now on sample data and swap in the farm station
later without changing any view. Do not rename columns without updating every consumer
and `docs/interface.md`.

| Table | One row per | Key columns |
|---|---|---|
| `detections` | Filtered hit | `ts` (UTC), `motusTagID`, `species`, `station`, `recvDeployID`, `lat`, `lon`, `port`, `antBearing`, `sig`, `runID`, `runLen` |
| `visits` | Tag at a station | `motusTagID`, `visitID`, `species`, `station`, `lat`, `lon`, `t_start`, `t_end`, `n_hits`, `max_sig`, `best_bearing`, `duration_h` |
| `legs` | Move between two different stations | `motusTagID`, `species`, `from`, `to`, `depart`, `arrive`, `distance_km`, `hours`, `speed_kmh` |
| `stations` | Receiver deployment | `recvDeployID`, `station`, `lat`, `lon`, `active_from`, `active_to` |

`stations` covers the whole Motus network when `NETWORK_STATIONS = TRUE` (the default),
via `motus::metadata()`; the sample login returns ~2,100 deployments, which may not be
the complete network. `active_to = NA` means the deployment was never closed on
motus.org, which is the best available signal that a station is still running.
| `antenna_activity` | Antenna per hour | `batchID`, `port`, `hour`, `n_pulses` |

`antenna_activity` comes from `pulseCounts` (receiver downloads: every antenna-hour) or,
failing that, from `activity` (project downloads: only hours with tag detections, so an
absent hour is not a silent antenna). The pipeline prints which one it used.

Also written: `cleaning_log` (rows removed by each rule) and `ambiguous_for_review`.

Each table is saved as `.rds` (preserves datetimes; use this from R), `.csv`, and
`.parquet` when the `arrow` package is installed.

## Data sources available now

The farm station registers with Motus around January 10, 2027. Until then, develop on:

- **Motus sample project 176.** `tagme(176, new = TRUE)`; username and password are both
  `motus.sample`. Offline copy: `motus::tagmeSample()` (set `USE_BUNDLED <- TRUE`).
  First download takes several minutes and yields ~109k raw hits (2014–2015 shorebird
  data from James Bay / Atlantic coast), 15 tags after cleaning.
- **`motusData` package.** A pre-filtered flat file of the sample data.
- **Rusty Blackbird dataset on Dryad.** Cleaned runs, flights, and stopovers, including
  New England deployments. Good for track and stopover views.
- **Network receiver metadata** via the `motus` package, for the regional station map.

Sample data is not from the Upper Valley. Never present it as what the farm detects.

## Rules

1. **Never upload simulated or test data to Motus.** It is a shared scientific network;
   fake detections contaminate other people's research. Simulated files stay local.
2. **No credentials in the repo.** No Motus passwords, Wi-Fi keys, or tokens in code,
   commits, or comments. The sample login above is public and is the only exception.
3. **Never commit `data/` or `output/`.** `.motus` files can be large and may contain
   other projects' restricted detections.
4. **All times are UTC.** Convert to local time only at display, and label it.
5. **Cleaning thresholds are documented decisions, not defaults.** They live in the
   configuration block of `R/clean_motus.R` (`MIN_RUN_LEN = 3`, `VISIT_GAP_HOURS = 2`) and
   the top of `R/antenna_health.R` (`FLAT_HOURS = 6`, `FLAT_MAX = 0`, `HOT_MULT = 10`,
   `HOT_HOURS = 3`). If you change one, update this file and say why in the commit message.
6. **Flag, don't silently drop.** New cleaning rules add an `f_` flag column and a row in
   the cleaning log, following the pattern in `clean_detections()`.
7. **Ambiguous detections are never discarded.** They go to `ambiguous_for_review`.
8. **Stop and ask before** adding a dependency outside the tidyverse, motus, arrow, sf,
   leaflet, or ggplot2; changing a handoff table's columns; or deleting anything.
9. **This is coursework.** Helin is accountable for every line. Keep changes small and
   explain what you did and why, so the work can be reviewed and disclosed under the
   course's generative-AI policy.

## Environment setup

R 4.3 or newer. On macOS, `brew install r udunits gdal geos proj apache-arrow` first:
`motus` depends on `sf`, which needs those system libraries, and the `arrow` R package
only links cleanly against the Homebrew Arrow (set `ARROW_USE_PKG_CONFIG=true` when
installing it; the bundled source build fails to link). Then install once:

```r
install.packages(c("motus", "motusData"),
  repos = c(birdscanada = "https://birdscanada.r-universe.dev",
            CRAN = "https://cloud.r-project.org"))
install.packages(c("dplyr", "lubridate", "arrow", "ggplot2", "sf", "leaflet", "htmlwidgets"))
```

Python 3.11+ for `python/`. Standard library only so far, so no virtual environment is
needed; if a dependency is ever added, use `.venv/` (gitignored).

**Motus login.** `R/clean_motus.R` reads `MOTUS_USER` and `MOTUS_PASSWORD` from the
environment (the same names the `motus` package uses). For project 176 they default to
the public sample login, so the sample run needs no setup. For the farm receiver, put
them in `.env` (gitignored) and export before running; never in the script.

## Commands

```sh
Rscript R/clean_motus.R        # download + clean + write handoff tables
Rscript tests/test_cleaning.R  # synthetic tests; must pass before committing
Rscript tests/test_antenna_health.R  # simulated-fault tests; must pass before committing
python3 -m unittest discover -s python/tests  # station-file round-trip tests
python3 python/sg_simulate.py --days 3 --dead-port 3 --dead-from-hour 48 --out output/simulated_station
python3 python/sg_files.py output/simulated_station --out output/station  # → hourly.csv etc.
Rscript R/views/station_map.R  # regional map → output/figures/station_map.{png,html}
Rscript R/views/flyby.R        # best flyby + grid of candidates → output/figures/flyby_*.png
Rscript R/views/track_map.R    # one tag's track (png+html) + overview → output/figures/track_*
Rscript R/views/activity_calendar.R  # date × hour heatmap + daily totals → output/figures/activity_*
Rscript R/views/antenna_health.R     # pulses/hour per antenna, real + simulated → output/figures/antenna_health*
```

Views read only `output/*.rds`. Each has its own configuration block at the top (for
the station map: farm coordinates, region radius, estimated detection radius).

## Testing

`tests/test_cleaning.R` builds fake detections designed to trip every cleaning rule and
checks the exact outcome: rows removed per rule, visits split by gap, legs only between
different stations, and leg distance. When you add a rule or change table logic, add a
case to this test. Tests must not need network access.

`tests/test_antenna_health.R` runs the health rules on `simulate_antenna_activity()`,
which has a port that dies on day 10, a 4-hour noise burst on day 5, and a 6-hour
receiver outage on day 7. It checks that exactly those are flagged, that the outage is
not blamed on an antenna, and that a silent port is detectable after `FLAT_HOURS`.

`python/tests/test_sg_files.py` simulates station files, parses them back, and checks
file naming, boot counts across an outage, settings and GPS cadence, the hourly table
shape, injected faults, and that bad lines are counted rather than fatal.
`output/station/hourly.csv` from the parser can be fed straight to `antenna_health()`.

`load_raw()` runs cleanly against project 176 with `motus` 6.1.2: every column in
`WANTED_COLS` was present. If a future `motus` version renames columns, the script
prints the missing ones at load time. Fix the mapping in `WANTED_COLS`; don't work
around it downstream.

## Backlog, in priority order

1. ~~Run the pipeline on project 176~~ Done 2026-11-05; no column mismatches.
2. **Overlapping stations fragment visits and legs.** On project 176, 64 of 115 legs
   imply > 150 km/h. 49 of those are two station pairs ~6 km apart (FINWR/BULL,
   Bennett Meadow/Shelburne) that both hear the same bird, alternating every few
   seconds; `make_visits()` splits a visit at every station change, so one stopover
   becomes dozens of visits and legs. Options, to decide together: (a) merge stations
   within a set distance into one site for visits; (b) keep visits as they are and add
   an `f_overlap`/`f_speed` flag to `legs`. Either touches handoff semantics, so agree
   first. Relevant to the farm: Mount Ascutney is 36 km away, so no overlap expected.
3. ~~Regional station map~~ Done 2026-11-05 (`R/views/station_map.R`). Open items: the
   farm coordinates are approximate (replace with the surveyed antenna position) and
   the 15 km radius is a placeholder until the range test.
4. ~~Flyby plot~~ Done 2026-11-05 (`R/views/flyby.R`). Plots a visit (not a run, since a
   run is one antenna by definition), one line per antenna, labelled by bearing or by
   port when the bearing is missing (63% of sample hits). Rerun on farm data to check
   the port-to-antenna map.
5. ~~Track map~~ Done 2026-11-05 (`R/views/track_map.R`). Merges consecutive visits at
   one station into a "stop" before plotting; static map has no basemap (would need a
   new dependency such as `rnaturalearth`; the leaflet HTML has tiles).
6. ~~Seasonal activity calendar~~ Done 2026-11-05 (`R/views/activity_calendar.R`). Hour
   axis is local time (`DISPLAY_TZ`, labelled), running noon→noon so a night is one
   block. "Hour of night" relative to sunset would need sunrise/sunset times (the
   `suncalc` package is already installed as a motus dependency) — add if wanted.
7. ~~Antenna health~~ Done 2026-11-05 (`R/antenna_health.R` rules, `R/views/antenna_health.R`
   view, simulator + tests). Flat-line detection is only meaningful on `pulseCounts`
   (receiver downloads) or simulated data; the view says so on the real-data figure.
   `antenna_activity` has no receiver column, so spells are found per batch.
8. ~~Interface control document~~ Draft 0.1 written 2026-11-05 (`docs/interface.md`).
   Items marked VERIFY need the hardware team or the running station; the port-to-antenna
   table is blank until installation. Keep it in sync with any handoff-table change.
9. ~~Station-side tools~~ Done 2026-11-05 (`python/`). Parser + simulator + tests,
   stdlib only. Line formats follow `docs/interface.md` §2.2 and still need checking
   against a real file from the CTT image (the `T` and `C` line fields especially).
   Range-test analysis itself is not written yet; the parser gives it `pulses.csv`.
10. **Public "this month at the farm" page**, last, once real farm data exists.

## Success metrics for this repo

- All views render unchanged when `PROJ_RECV` is switched from 176 to the farm receiver.
- The health monitor flags a silent antenna port within `FLAT_HOURS` = 6 hours (set
  2026-11-05 as a starting point; revisit once we know the farm's quiet-hour pulse floor).
- Every cleaning decision is visible as a number in `cleaning_log`.

## Glossary

- **Hit**: one tag burst matched by the Motus tag finder.
- **Run**: consecutive hits of one tag on one antenna. `runLen` is the hit count.
- **Batch**: a set of files processed together from one receiver.
- **Port**: the USB/antenna input number on the receiver; maps to an antenna bearing.
- **Ambiguous detection**: a burst that matched more than one registered tag.
- **p-line / T-line**: raw station file records for a Lotek pulse / a CTT tag hit.
- **Burst interval (BI)**: time between a Lotek tag's bursts; part of its identity.
