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
│   └── views/                # stage 7: one script per view (to build)
├── python/                   # station-side tools: raw-file parser, simulator (to build)
├── tests/
│   └── test_cleaning.R       # synthetic-data tests for clean_motus.R
├── docs/
│   └── interface.md          # interface control document (to write)
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
| `antenna_activity` | Antenna per hour | `batchID`, `port`, `hour`, `n_pulses` |

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
   configuration block of `R/clean_motus.R` (`MIN_RUN_LEN = 3`, `VISIT_GAP_HOURS = 2`). If
   you change one, update this file and say why in the commit message.
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
install.packages(c("dplyr", "lubridate", "arrow", "ggplot2", "sf", "leaflet"))
```

Python 3.11+ for anything in `python/` (none yet). Use a virtual environment in `.venv/`.

**Motus login.** `R/clean_motus.R` reads `MOTUS_USER` and `MOTUS_PASSWORD` from the
environment (the same names the `motus` package uses). For project 176 they default to
the public sample login, so the sample run needs no setup. For the farm receiver, put
them in `.env` (gitignored) and export before running; never in the script.

## Commands

```sh
Rscript R/clean_motus.R        # download + clean + write handoff tables
Rscript tests/test_cleaning.R  # synthetic tests; must pass before committing
```

## Testing

`tests/test_cleaning.R` builds fake detections designed to trip every cleaning rule and
checks the exact outcome: rows removed per rule, visits split by gap, legs only between
different stations, and leg distance. When you add a rule or change table logic, add a
case to this test. Tests must not need network access.

`load_raw()` runs cleanly against project 176 with `motus` 6.1.2: every column in
`WANTED_COLS` was present. If a future `motus` version renames columns, the script
prints the missing ones at load time. Fix the mapping in `WANTED_COLS`; don't work
around it downstream.

## Backlog, in priority order

1. ~~Run the pipeline on project 176~~ Done 2026-11-05; no column mismatches.
2. **Implausible legs.** On project 176, `legs$speed_kmh` ranges up to millions of km/h:
   some tags are detected at far-apart stations minutes apart (likely false positives).
   Decide a max plausible speed, add an `f_speed` flag to `legs` (needs a column change,
   so agree on it first), and log how many legs it affects.
3. **Regional station map** (`R/views/station_map.R`): active receivers near Hanover with
   detection-radius circles and the farm site marked. Label the radius as an estimate.
4. **Flyby plot** (`R/views/flyby.R`): signal strength vs. time for one run, one line per
   antenna bearing. This is also the visual check that port-to-antenna mapping is right.
5. **Track map** (`R/views/track_map.R`): one tag's visits in time order, colored by date,
   points sized by stopover duration.
6. **Seasonal activity calendar**: date × hour-of-night heatmap of tags detected, by species.
7. **Antenna health**: pulses per hour per antenna, flagging flat lines. Uses
   `antenna_activity`; likely empty in project downloads, so test against simulated data.
8. **Interface control document** (`docs/interface.md`): station file formats, units,
   timing guarantees, port-to-antenna map, upload cadence, and health signals.
9. **Station-side tools** (`python/`): a parser for raw SensorGnome files and a simulator
   that writes files in the same format, for the health monitor and range-test analysis.
10. **Public "this month at the farm" page**, last, once real farm data exists.

## Success metrics for this repo

- All views render unchanged when `PROJ_RECV` is switched from 176 to the farm receiver.
- The health monitor flags a silent antenna port within a set number of hours (to be set).
- Every cleaning decision is visible as a number in `cleaning_log`.

## Glossary

- **Hit**: one tag burst matched by the Motus tag finder.
- **Run**: consecutive hits of one tag on one antenna. `runLen` is the hit count.
- **Batch**: a set of files processed together from one receiver.
- **Port**: the USB/antenna input number on the receiver; maps to an antenna bearing.
- **Ambiguous detection**: a burst that matched more than one registered tag.
- **p-line / T-line**: raw station file records for a Lotek pulse / a CTT tag hit.
- **Burst interval (BI)**: time between a Lotek tag's bursts; part of its identity.
