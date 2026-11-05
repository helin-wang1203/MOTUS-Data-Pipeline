# Interface Control Document — Dartmouth Organic Farm Motus Station

Version 0.1, 2026-11-05. Owner: Helin Wang (data). Hardware counterpart: the
antenna/power/mast team.

This document fixes the boundaries between the station hardware, the Motus
network, this data pipeline, and the visualizations that read from it. Each
section states what crosses the boundary, in what units, and who is
responsible for it. Anything marked **VERIFY** is a working assumption that
needs confirmation from the hardware team, from the station once it is
running, or from Motus/CTT documentation. Change this document in the same
commit as any change to a boundary it describes.

## 1. System context

```
 Birds with tags                  Station (barn, Organic Farm)               motus.org                 This repo
 ───────────────                  ────────────────────────────               ─────────                 ─────────
 166.380 MHz Lotek NanoTag ──▶ 4× FUNcube Dongle Pro+ (USB) ──┐
   (pulse bursts)                 ports 1–4, one per antenna  │
                                                              ├──▶ SensorGnome software ──▶ hourly .txt.gz ──▶ upload ──▶ tag finder ──▶ tagme() ──▶ clean_motus.R ──▶ output/ tables ──▶ views
 434 MHz CTT LifeTag ────────▶ CTT SensorStation V3 radios ───┘       (A)                   (B)                    (C)                 (D)                   (E)
   (ID-coded)                     (internal)
```

| Boundary | From → To | Owner of the producer side | Section |
|---|---|---|---|
| A | Radios/antennas → SensorGnome raw files | Hardware team | 2, 3 |
| B | Station → motus.org (upload) | Hardware team configures; data team verifies | 4 |
| C | motus.org → local `.motus` database | Motus (existing); data team runs it | 5 |
| D | `.motus` database → handoff tables in `output/` | Data team (this repo) | 6 |
| E | Handoff tables → visualizations | Data team (this repo) | 6, 7 |
| — | Station health signals (side path across A and D) | Both | 8 |

## 2. Boundary A: station raw files

### 2.1 What the station writes

The SensorGnome software records everything it hears into compressed text
files, one line per event. **VERIFY** the exact filename pattern on the
installed image; the SensorGnome convention is

```
<receiver serial>-<boot count>-<YYYY-MM-DDTHH-MM-SS.ffff>-all.txt.gz
```

with a new file started roughly every hour or when the file reaches a size
limit (**VERIFY** which rule the installed version uses). The receiver
serial for a CTT SensorStation has the form `CTT-<12 hex digits>` and is the
value that goes into `PROJ_RECV` in `R/clean_motus.R` after registration.

### 2.2 Line types

Each line is comma-separated. The first field says what kind of record it is.

| Record | Format | Produced by | Used by |
|---|---|---|---|
| Pulse (`p` line) | `p<port>,<ts>,<dfreq>,<sig>,<noise>` | FUNcube SDRs, 166 MHz | Motus tag finder (not this repo directly); pulse counts feed §8 |
| CTT tag (`T` line) | `T<port>,<ts>,<tagID>,<sig>` (**VERIFY** field list on CTT image) | SensorStation 434 MHz radios | Motus tag finder |
| GPS (`G` line) | `G,<ts>,<lat>,<lon>,<alt>` | Station GPS | Clock discipline; receiver position in metadata |
| Setting (`S` line) | `S,<ts>,<port>,<param>,<value>,<rc>,<err>` | SensorGnome at boot and on change | Confirms each FUNcube is tuned to 166.376 MHz |
| Clock (`C` line) | `C,<ts>,<source>,...` (**VERIFY**) | SensorGnome | Timing guarantee (§3) |

Fields and units:

| Field | Unit / type | Notes |
|---|---|---|
| `port` | integer 1–4 (166 MHz USB ports); CTT internal radios use their own port numbers (**VERIFY**) | Maps to a physical antenna (§7). Port `-1` or `0` in Motus data means "unknown/not an antenna"; the sample project contains both. |
| `ts` | seconds since 1970-01-01 00:00:00 UTC, fractional | Always UTC. Never written in local time anywhere in the chain. |
| `dfreq` | kHz offset from the tuned centre frequency | 166.380 MHz tag on a 166.376 MHz centre gives ≈ +4 kHz. |
| `sig`, `noise` | dB (relative, uncalibrated) | Comparable within one receiver and antenna; not across receivers. More negative = weaker. |
| `lat`, `lon` | decimal degrees, WGS84 | From the station GPS. |
| `alt` | metres | |

Lotek tag identity is **not** in the file: a NanoTag is identified by the
spacing of pulses within a burst and the interval between bursts (the burst
interval, BI). The Motus server does that matching. The station's only job
at boundary A is to record every pulse with an accurate timestamp.

### 2.3 Where files live and how long

**VERIFY** on the installed image: files accumulate on the station's storage
and are retained after upload. Plan for the data team to pull a copy of raw
files at least once per term for the health monitor and range-test analysis
(§8), independent of the Motus upload path.

## 3. Timing guarantees

| Guarantee | Value | Basis |
|---|---|---|
| Timestamp zone | UTC, always | SensorGnome convention; rule 4 of CLAUDE.md |
| Timestamp precision | sub-millisecond as written | Needed because Lotek tag ID comes from pulse spacing of a few ms |
| Clock source | GPS-disciplined when a fix is available | **VERIFY** behaviour without GPS fix: SensorGnome marks files/time as unreliable and Motus may reject or delay them |
| Required GPS fix | A fix within the first minutes after boot and periodically thereafter | Both for time and for the receiver's position in Motus metadata |
| File rotation | ~hourly | **VERIFY** |
| Hit timestamps in Motus data | `ts` of the first pulse of the burst, UTC | What `detections.ts` carries |

What breaks if these fail: without GPS time, pulse spacing is still right
(it is relative) but file timestamps drift and the Motus tag finder may not
align bursts across files; the station then shows up as "no data" in
Motus even though files are uploading.

## 4. Boundary B: upload to motus.org

| Item | Value |
|---|---|
| Primary path | Station on the barn's Ethernet; SensorGnome's built-in uploader pushes new files to motus.org (**VERIFY** the mechanism and cadence on the CTT image: SensorGnome images upload on a schedule of the order of hourly when connected) |
| Fallback 1 | Wi-Fi, same uploader |
| Fallback 2 | Manual offload: copy files from the station (USB stick or the station's web interface, **VERIFY**) and upload through the motus.org "Upload data" page under the project |
| Receiver registration | Must happen on motus.org before any data is accepted. Target: around 2027-01-10. Until then the station can record locally; nothing is lost |
| Receiver deployment record | Created on motus.org with position, start date, and **one antenna record per port with its bearing** (§7). This is where `antBearing` in every downstream table comes from |
| What never goes up | Simulated or test files (CLAUDE.md rule 1). Simulation output stays in `output/` and `data/` locally |

Latency budget from a bird passing to its appearing in `tagme()`: file
rotation (≤ 1 h) + upload cadence (**VERIFY**, assume ≤ 1 h) + Motus tag
finder processing (**VERIFY**, typically hours to about a day) + our next
`clean_motus.R` run. Plan on "next day" for anything that depends on fresh
data, not "same hour".

## 5. Boundary C: motus.org to the local database

Existing interface, run by the `motus` R package (v6.1.2 at time of writing).

| Item | Value |
|---|---|
| Call | `motus::tagme(PROJ_RECV, new = ..., update = TRUE, dir = "data")` |
| Credentials | `MOTUS_USER` / `MOTUS_PASSWORD` environment variables; the public `motus.sample` login is the default for project 176 only |
| Result | SQLite file `data/project-176.motus` or `data/<receiver serial>.motus`; gitignored |
| Tables this repo reads | `alltags` (view; the columns in `WANTED_COLS`), `recvDeps`, `pulseCounts` if present, otherwise `activity` |
| Project vs receiver download | A **project** download has detections of the project's tags anywhere, and the `activity` table only for hours with detections. A **receiver** download has everything that receiver heard, plus `pulseCounts` for every antenna-hour. Health monitoring (§8) needs the receiver download |
| Network metadata | `motus::metadata(sql)` fills `recvDeps` with every receiver deployment the login can see (~2,100 with the sample login); used for the regional station map |

Columns that must exist in `alltags` for the pipeline to run unchanged are
listed in `WANTED_COLS` in `R/clean_motus.R`. The script prints any that are
missing instead of crashing. If the `motus` package renames one, fix the
mapping there; views do not see `alltags`.

## 6. Boundaries D and E: the handoff tables

Written by `R/clean_motus.R` to `output/` as `.rds` (authoritative, keeps
types and UTC), `.csv`, and `.parquet`. Views read **only** these. The rows
quoted are from sample project 176 on 2026-11-05.

### 6.1 `detections` — one row per hit that survived cleaning (42,356 rows)

| Column | Type | Unit | Meaning |
|---|---|---|---|
| `ts` | POSIXct | UTC | Time of the hit |
| `motusTagID` | integer | — | Motus tag ID (stable across deployments of the same physical tag) |
| `species` | character | — | English name from the tag deployment; `NA` if not recorded |
| `station` | character | — | Receiver deployment name as entered on motus.org |
| `recvDeployID` | integer | — | Receiver deployment ID; the join key to `stations` |
| `lat`, `lon` | numeric | decimal degrees | Receiver deployment position (not the bird's) |
| `port` | character | — | Antenna port on the receiver, as a string because Motus mixes `"1"`, `"-1"`, `"A1"` etc. |
| `antBearing` | numeric | degrees true, 0 = north | From the receiver deployment's antenna record; `NA` if not entered (63% of sample hits) |
| `sig` | numeric | dB, relative | Signal strength |
| `runID` | integer | — | Motus run (consecutive hits of one tag on one antenna) |
| `runLen` | integer | hits | Length of that run |

### 6.2 `visits` — one row per tag-at-a-station visit (275 rows)

A visit is consecutive detections of one tag at one station with no gap
longer than `VISIT_GAP_HOURS` (2 h) and no detection elsewhere in between.

| Column | Type | Unit | Meaning |
|---|---|---|---|
| `motusTagID`, `species`, `station`, `recvDeployID`, `lat`, `lon` | as in `detections` | | |
| `visitID` | integer | — | Sequence number within the tag, in time order |
| `t_start`, `t_end` | POSIXct | UTC | First and last hit |
| `n_hits` | integer | hits | |
| `max_sig` | numeric | dB | Strongest hit |
| `best_bearing` | numeric | degrees | Bearing of the antenna with the strongest mean signal during the visit; `NA` if no bearings |
| `duration_h` | numeric | hours | `t_end - t_start` |

Known limitation: two stations within range of each other that both hear a
bird split one stopover into many alternating visits (see CLAUDE.md backlog
item 2). Views that need "stops" merge consecutive visits at the same station
themselves (`R/views/track_map.R`).

### 6.3 `legs` — one row per move between two different stations (115 rows)

| Column | Type | Unit | Meaning |
|---|---|---|---|
| `motusTagID`, `species` | | | |
| `from`, `to` | character | — | Station names |
| `depart`, `arrive` | POSIXct | UTC | `t_end` of the first visit, `t_start` of the next |
| `distance_km` | numeric | km | Great-circle distance between receiver positions |
| `hours` | numeric | hours | `arrive - depart` |
| `speed_kmh` | numeric | km/h | `distance_km / hours`; `NA` if `hours` is 0. Not yet filtered for plausibility |

### 6.4 `stations` — one row per receiver deployment (2,092 rows, whole network)

| Column | Type | Unit | Meaning |
|---|---|---|---|
| `recvDeployID` | integer | — | Join key |
| `station` | character | — | Deployment name |
| `lat`, `lon` | numeric | decimal degrees | |
| `active_from`, `active_to` | POSIXct | UTC | `active_to` is `NA` when the deployment was never closed on motus.org, which is the best available signal that it is still running |

### 6.5 `antenna_activity` — one row per antenna per hour (56,511 rows)

| Column | Type | Unit | Meaning |
|---|---|---|---|
| `batchID` | integer | — | Motus processing batch; stands in for "receiver" because the table has no receiver column |
| `port` | character | — | As in `detections` |
| `hour` | POSIXct | UTC, on the hour | Start of the hour |
| `n_pulses` | integer | pulses | Pulses recorded on that port in that hour, all tags and noise |

Source matters: from `pulseCounts` (receiver download) every antenna-hour is
present and a missing port-hour means zero. From `activity` (project
download) only hours with tag detections are present and a missing hour
means nothing. The pipeline prints which source it used.

### 6.6 Side tables

| Table | Purpose |
|---|---|
| `cleaning_log` | One row per rule: `rule`, `removed`, `remaining`. Every number that appears in the report about data cleaning comes from here |
| `ambiguous_for_review` | Every hit whose burst matched more than one registered tag, with all `alltags` columns and the `f_*` flag columns. Never deleted, never shown in views |

### 6.7 Change control for the handoff tables

- Adding a column: allowed after agreement; update §6 here, CLAUDE.md, and
  every view that selects columns explicitly.
- Renaming or removing a column, or changing a unit or time zone: requires
  updating every consumer in the same commit; grep `R/views/` for the name.
- Changing a threshold (`MIN_RUN_LEN`, `VISIT_GAP_HOURS`, antenna health
  thresholds): update CLAUDE.md rule 5 and say why in the commit message.
- All times stay UTC in every table. Views convert for display and label the
  zone (`DISPLAY_TZ` in `R/views/activity_calendar.R`).

## 7. Port-to-antenna map

This table is the single source of truth for which physical antenna is on
which port. The hardware team fills in bearings and heights at installation;
the data team enters the same values in the receiver deployment on motus.org
so that `antBearing` is populated downstream.

| Port | Radio | Antenna | Bearing (° true) | Height AGL (m) | Notes |
|---|---|---|---|---|---|
| 1 | FUNcube Dongle Pro+ #1, 166.376 MHz | Yagi 1 | **TBD** | **TBD** | |
| 2 | FUNcube Dongle Pro+ #2, 166.376 MHz | Yagi 2 | **TBD** | **TBD** | |
| 3 | FUNcube Dongle Pro+ #3, 166.376 MHz | Yagi 3 | **TBD** | **TBD** | |
| 4 | FUNcube Dongle Pro+ #4, 166.376 MHz | Omni | n/a (omni) | **TBD** | Enter bearing as `NA`/blank on motus.org, not 0 |
| CTT | SensorStation internal 434 MHz radios | **TBD** | **TBD** | **TBD** | **VERIFY** how CTT ports are numbered in Motus data |

Rules:

- A port number is fixed by the USB socket the dongle is in. Label each
  dongle, cable, and antenna with its port number at installation and
  photograph the result for this document.
- Bearings are degrees true, not magnetic; Hanover's magnetic declination is
  about 14° W (**VERIFY** current value), so a compass reading of 0° is
  roughly 346° true.
- Verification after installation: run the flyby view
  (`R/views/flyby.R`) on the first few weeks of farm data. A bird passing
  the station should peak on antennas in bearing order. If the peaks come in
  the wrong order, the ports are mislabelled either here or on motus.org.

## 8. Health signals

What the data side can observe about the station, where it comes from, and
what the hardware team should expect to be asked about.

| Signal | Source | Normal | Alert | Where implemented |
|---|---|---|---|---|
| Files arriving at motus.org | motus.org receiver page; `tagme()` batch count growing | New batch at least daily | None for > 48 h (**VERIFY** cadence) | Manual check for now |
| GPS fix | `G` lines in raw files; receiver deployment position | A fix every few minutes | No fix for > 1 h | Not yet; needs raw-file parser (backlog 9) |
| Pulses per hour per 166 MHz port | `pulseCounts` → `antenna_activity` | Tens to thousands per hour, with a day/night pattern | `FLAT_HOURS` = 6 consecutive receiver-up hours at 0 pulses: silent port (cable, dongle, or antenna). `HOT_HOURS` = 3 hours above 10× the port's median: noise source | `R/antenna_health.R`, `R/views/antenna_health.R` |
| Receiver up/down | Any port reporting in the hour | Every hour | A gap with no port reporting is receiver or power downtime, not an antenna fault, and is reported separately | `R/antenna_health.R` (`complete_hours()`) |
| FUNcube tuning | `S` lines at boot | Each port shows `-m 166.376` (**VERIFY** parameter name) | Any other value | Not yet; needs raw-file parser |

Thresholds are starting points set on 2026-11-05 against simulated data.
Revisit after the first month of farm data, when the real quiet-hour pulse
floor is known.

## 9. Open items and verification checklist

| # | Item | Who | Needed by |
|---|---|---|---|
| 1 | Confirm filename pattern, rotation rule, and `T`/`C` line formats on the installed CTT SensorGnome image (§2) | Hardware | Before first offload |
| 2 | Confirm upload mechanism and cadence (§4) | Hardware | Before registration |
| 3 | Fill in the port-to-antenna table with bearings and heights; photograph labels (§7) | Hardware | Installation day |
| 4 | Enter the receiver deployment and antenna records on motus.org (§4, §7) | Data, with hardware's numbers | Registration, ~2027-01-10 |
| 5 | Replace the farm coordinates in `R/views/station_map.R` with the surveyed position | Data | After installation |
| 6 | Set `PROJ_RECV` to the receiver serial and run the pipeline on a receiver download; confirm `pulseCounts` is present | Data | First week after registration |
| 7 | Decide the overlapping-stations handling for `visits`/`legs` (CLAUDE.md backlog 2) | Data | Before the first report |
| 8 | Run the flyby check on the port map (§7) | Data | First weeks of data |
| 9 | Revisit health thresholds against real data (§8) | Data | After one month |
