# clean_motus.R
# Motus station data pipeline, stage 5–6: download, clean, and build handoff tables.
#
# Input:  a Motus project or receiver, via the motus R package (tagme)
# Output: five handoff tables in OUT_DIR, plus a cleaning log
#   detections        one row per filtered hit
#   visits            one row per tag-at-a-station visit
#   legs              one row per move between two stations by one tag
#   stations          one row per receiver deployment
#   antenna_activity  one row per antenna per hour (if pulse counts exist)
#   cleaning_log      rows removed by each rule (document this in the report)
#
# To switch from sample data to the Organic Farm station after registration,
# change only PROJ_RECV below (to the receiver serial, e.g. "CTT-XXXXXXXXXXXX").
# Every downstream view reads the output tables, so nothing else changes.

suppressPackageStartupMessages({
  library(dplyr)
  library(lubridate)
})

# ---- Configuration ---------------------------------------------------------

PROJ_RECV        <- 176          # sample project; later the farm receiver serial
USE_BUNDLED      <- FALSE        # TRUE = use tagmeSample() offline copy, no login
DATA_DIR         <- "data"       # where the .motus SQLite file lives
OUT_DIR          <- "output"     # where handoff tables are written

MIN_RUN_LEN      <- 3            # runs this short or shorter are treated as noise
VISIT_GAP_HOURS  <- 2            # gap that splits one visit into two at a station
DROP_AMBIGUOUS   <- TRUE         # ambiguous hits go to a review file, not detections

# ---- Helpers ---------------------------------------------------------------

# Great-circle distance in km between two lat/lon points (vectorized).
haversine_km <- function(lat1, lon1, lat2, lon2) {
  rad <- pi / 180
  dlat <- (lat2 - lat1) * rad
  dlon <- (lon2 - lon1) * rad
  a <- sin(dlat / 2)^2 + cos(lat1 * rad) * cos(lat2 * rad) * sin(dlon / 2)^2
  2 * 6371 * asin(pmin(1, sqrt(a)))
}

# Motus stores times as seconds since 1970 (UTC). Convert numeric columns only.
to_utc <- function(x) if (is.numeric(x)) as_datetime(x, tz = "UTC") else x

# Columns we use from alltags. Names follow motus package v6; any missing
# column is reported rather than crashing, so version drift is visible.
WANTED_COLS <- c(
  "hitID", "runID", "batchID", "ts", "sig", "noise", "freq", "freqsd",
  "runLen", "motusFilter", "probability", "ambigID",
  "motusTagID", "tagDeployID", "tagDeployStart", "tagDeployEnd", "speciesEN",
  "recv", "recvDeployID", "recvDeployName", "recvDeployLat", "recvDeployLon",
  "port", "antBearing", "antType"
)

# ---- Step 1: get the raw detections ---------------------------------------

load_raw <- function() {
  if (!requireNamespace("motus", quietly = TRUE)) {
    stop("Install the motus package first:\n",
         "  install.packages(c('motus','motusData'),\n",
         "    repos = c(birdscanada = 'https://birdscanada.r-universe.dev',\n",
         "              CRAN = 'https://cloud.r-project.org'))")
  }
  if (USE_BUNDLED) {
    sql <- motus::tagmeSample()
  } else {
    dir.create(DATA_DIR, showWarnings = FALSE)
    db_file <- file.path(DATA_DIR, paste0(
      if (is.numeric(PROJ_RECV)) "project-" else "", PROJ_RECV, ".motus"))
    # Credentials come from the environment so nothing private is in the repo.
    # Sample project 176 uses the public login "motus.sample" (both fields);
    # it is the default so the sample run works with no setup. For the farm
    # receiver, set MOTUS_USER and MOTUS_PASSWORD in .env or the shell.
    is_sample <- identical(PROJ_RECV, 176)
    # Same env-var names the motus package itself uses (local_auth()).
    set_var <- get("sessionVariable", envir = asNamespace("motus"))
    set_var(name = "userLogin",
            val = Sys.getenv("MOTUS_USER",     if (is_sample) "motus.sample" else ""))
    set_var(name = "userPassword",
            val = Sys.getenv("MOTUS_PASSWORD", if (is_sample) "motus.sample" else ""))
    sql <- motus::tagme(PROJ_RECV, new = !file.exists(db_file),
                        update = TRUE, dir = DATA_DIR)
  }

  # filterByActivity() adds a 'probability' column (0 = likely noise) based on
  # how many short runs a receiver produced in each hour.
  raw <- tryCatch(
    motus::filterByActivity(sql, return = "all"),
    error = function(e) {
      message("filterByActivity() unavailable (", conditionMessage(e),
              "); continuing without activity filter.")
      dplyr::tbl(sql, "alltags")
    }
  )

  available <- colnames(raw)
  missing <- setdiff(WANTED_COLS, available)
  if (length(missing)) message("Columns not found in alltags: ",
                               paste(missing, collapse = ", "))

  raw <- raw %>% select(any_of(WANTED_COLS)) %>% collect()
  list(sql = sql, raw = raw)
}

# ---- Step 2: cleaning rules -----------------------------------------------
# Each rule flags rows instead of silently dropping them, so the log can say
# exactly how many detections each decision removed.

clean_detections <- function(raw) {
  df <- raw %>% mutate(across(any_of(c("ts", "tagDeployStart", "tagDeployEnd")),
                              to_utc))

  has <- function(col) col %in% names(df)

  df <- df %>% mutate(
    f_activity = if (has("probability")) coalesce(probability == 0, FALSE) else FALSE,
    f_motus    = if (has("motusFilter")) coalesce(motusFilter == 0, FALSE) else FALSE,
    f_short    = coalesce(runLen <= MIN_RUN_LEN, FALSE),
    f_ambig    = if (has("ambigID")) !is.na(ambigID) else FALSE,
    f_outside  = if (has("tagDeployStart"))
                   coalesce(ts < tagDeployStart, FALSE) |
                   coalesce(ts > tagDeployEnd, FALSE) else FALSE,
    f_no_recv  = is.na(recvDeployLat) | is.na(recvDeployLon)
  )

  rules <- c(
    f_activity = "Noisy hour (filterByActivity probability = 0)",
    f_motus    = "Flagged by motusFilter",
    f_short    = paste0("Run length <= ", MIN_RUN_LEN),
    f_ambig    = "Ambiguous: burst matched more than one tag",
    f_outside  = "Outside the tag's deployment dates",
    f_no_recv  = "Receiver deployment location missing"
  )
  if (!DROP_AMBIGUOUS) rules <- rules[names(rules) != "f_ambig"]

  # Apply rules in order; log rows removed by each one that weren't already removed.
  keep <- rep(TRUE, nrow(df))
  log <- data.frame(rule = "Raw hits", removed = NA_integer_,
                    remaining = nrow(df))
  for (r in names(rules)) {
    drop <- keep & df[[r]]
    keep <- keep & !df[[r]]
    log <- rbind(log, data.frame(rule = rules[[r]], removed = sum(drop),
                                 remaining = sum(keep)))
  }

  ambiguous <- df %>% filter(f_ambig)
  clean <- df[keep, ] %>% select(-starts_with("f_"))
  list(clean = clean, ambiguous = ambiguous, log = log)
}

# ---- Step 3: handoff tables ------------------------------------------------

make_detections <- function(clean) {
  clean %>%
    transmute(ts, motusTagID,
              species    = if ("speciesEN" %in% names(.)) speciesEN else NA_character_,
              station    = recvDeployName, recvDeployID,
              lat        = recvDeployLat, lon = recvDeployLon,
              port, antBearing, sig, runID, runLen) %>%
    arrange(motusTagID, ts)
}

# A visit = consecutive detections of one tag at one station with no gap
# longer than VISIT_GAP_HOURS and no detection at another station in between.
make_visits <- function(det) {
  det %>%
    arrange(motusTagID, ts) %>%
    group_by(motusTagID) %>%
    mutate(gap_h   = as.numeric(difftime(ts, lag(ts), units = "hours")),
           new_vis = is.na(gap_h) | gap_h > VISIT_GAP_HOURS |
                     recvDeployID != lag(recvDeployID),
           visitID = cumsum(new_vis)) %>%
    group_by(motusTagID, visitID) %>%
    summarise(
      species      = first(species),
      station      = first(station),
      recvDeployID = first(recvDeployID),
      lat          = first(lat),
      lon          = first(lon),
      t_start      = min(ts),
      t_end        = max(ts),
      n_hits       = n(),
      max_sig      = max(sig, na.rm = TRUE),
      # bearing of the antenna with the strongest mean signal during the visit
      best_bearing = {
        b <- tapply(sig, antBearing, mean, na.rm = TRUE)
        if (length(b) && any(!is.na(b))) as.numeric(names(b)[which.max(b)]) else NA_real_
      },
      .groups = "drop"
    ) %>%
    mutate(duration_h = as.numeric(difftime(t_end, t_start, units = "hours")))
}

# A leg = one tag leaving one station and next being detected at a different one.
make_legs <- function(visits) {
  visits %>%
    arrange(motusTagID, t_start) %>%
    group_by(motusTagID) %>%
    mutate(to = lead(station), to_id = lead(recvDeployID),
           arrive = lead(t_start), to_lat = lead(lat), to_lon = lead(lon)) %>%
    ungroup() %>%
    filter(!is.na(to_id), to_id != recvDeployID) %>%
    transmute(motusTagID, species, from = station, to,
              depart = t_end, arrive,
              distance_km = haversine_km(lat, lon, to_lat, to_lon),
              hours       = as.numeric(difftime(arrive, depart, units = "hours")),
              speed_kmh   = ifelse(hours > 0, distance_km / hours, NA_real_))
}

make_stations <- function(sql) {
  rd <- dplyr::tbl(sql, "recvDeps") %>% collect()
  rd %>%
    transmute(recvDeployID = deployID,
              station      = if ("name" %in% names(rd)) name else NA_character_,
              lat = latitude, lon = longitude,
              active_from  = to_utc(tsStart),
              active_to    = to_utc(tsEnd)) %>%
    distinct()
}

make_antenna_activity <- function(sql) {
  if (!"pulseCounts" %in% DBI::dbListTables(sql)) return(NULL)
  pc <- dplyr::tbl(sql, "pulseCounts") %>% collect()
  if (!nrow(pc)) return(NULL)
  pc %>% transmute(batchID, port = ant,
                   hour = as_datetime(hourBin * 3600, tz = "UTC"),
                   n_pulses = numPulses)
}

# ---- Step 4: write ---------------------------------------------------------

write_table <- function(x, name) {
  if (is.null(x)) { message("  ", name, ": no data, skipped"); return(invisible()) }
  saveRDS(x, file.path(OUT_DIR, paste0(name, ".rds")))   # keeps datetimes intact
  write.csv(x, file.path(OUT_DIR, paste0(name, ".csv")), row.names = FALSE)
  if (requireNamespace("arrow", quietly = TRUE))
    arrow::write_parquet(x, file.path(OUT_DIR, paste0(name, ".parquet")))
  message(sprintf("  %-17s %d rows", name, nrow(x)))
}

# ---- Main ------------------------------------------------------------------

run_pipeline <- function() {
  dir.create(OUT_DIR, showWarnings = FALSE)
  message("Loading ", if (USE_BUNDLED) "bundled sample" else PROJ_RECV, " ...")
  src <- load_raw()

  message("Cleaning ...")
  cl <- clean_detections(src$raw)
  print(cl$log, row.names = FALSE)

  det  <- make_detections(cl$clean)
  vis  <- make_visits(det)
  legs <- make_legs(vis)

  message("Writing tables to ", OUT_DIR, "/")
  write_table(det, "detections")
  write_table(vis, "visits")
  write_table(legs, "legs")
  write_table(make_stations(src$sql), "stations")
  write_table(make_antenna_activity(src$sql), "antenna_activity")
  write_table(cl$ambiguous, "ambiguous_for_review")
  write_table(cl$log, "cleaning_log")

  message(sprintf("Done: %d tags, %d visits, %d legs.",
                  n_distinct(det$motusTagID), nrow(vis), nrow(legs)))
}

if (!exists("SOURCE_ONLY")) run_pipeline()
