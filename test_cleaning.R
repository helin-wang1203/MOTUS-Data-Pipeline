# Synthetic-data tests for R/clean_motus.R. No network needed.
# Run from the repo root: Rscript tests/test_cleaning.R
SOURCE_ONLY <- TRUE
source("R/clean_motus.R")
set.seed(1)

t0 <- 1.6e9; h <- 3600
mk <- function(tag, recv, name, lat, lon, ts, runLen = 10, ambig = NA, prob = 1) data.frame(
  hitID = seq_along(ts), runID = tag * 10, batchID = 1, ts = ts, sig = -60 + rnorm(length(ts)),
  noise = -90, freq = 4, freqsd = 0.05, runLen = runLen, motusFilter = 1, probability = prob,
  ambigID = ambig, motusTagID = tag, tagDeployID = tag, tagDeployStart = t0 - 100 * h,
  tagDeployEnd = NA_real_, speciesEN = "Swainson's Thrush", recv = recv, recvDeployID = recv,
  recvDeployName = name, recvDeployLat = lat, recvDeployLon = lon, port = 1,
  antBearing = rep(c(0, 120), length.out = length(ts)), antType = "yagi-5")

raw <- rbind(
  mk(1, 10, "Farm",  43.70, -72.29, t0 + 0:20 * 30),          # visit 1 at farm
  mk(1, 10, "Farm",  43.70, -72.29, t0 + 5 * h + 0:5 * 30),   # visit 2 (gap > 2 h)
  mk(1, 20, "South", 42.70, -72.29, t0 + 12 * h + 0:10 * 30), # leg of ~111 km
  mk(2, 10, "Farm",  43.70, -72.29, t0 + 0:2 * 30, runLen = 2),   # short run
  mk(3, 10, "Farm",  43.70, -72.29, t0 + 0:5 * 30, ambig = -5),   # ambiguous
  mk(4, 10, "Farm",  43.70, -72.29, t0 - 200 * h + 0:5 * 30),     # before deployment
  mk(5, 20, "South", NA, NA,        t0 + 0:5 * 30),               # no receiver location
  mk(6, 10, "Farm",  43.70, -72.29, t0 + 0:5 * 30, prob = 0))     # noisy hour

cl   <- clean_detections(raw)
det  <- make_detections(cl$clean)
vis  <- make_visits(det)
legs <- make_legs(vis)

check <- function(cond, msg) { if (!cond) stop("FAIL: ", msg); cat("pass:", msg, "\n") }
check(identical(cl$log$removed[-1], c(6L, 0L, 3L, 6L, 6L, 6L)), "each rule removes its rows")
check(nrow(det) == 38, "38 detections survive")
check(nrow(cl$ambiguous) == 6, "ambiguous hits kept for review")
check(all(det$motusTagID == 1), "only the valid tag remains")
check(nrow(vis) == 3, "gap splits farm visits; third visit at South")
check(nrow(legs) == 1, "no leg between two visits at the same station")
check(abs(legs$distance_km - 111.19) < 0.1, "leg distance ~111 km")
check(inherits(det$ts, "POSIXct") && attr(det$ts, "tzone") == "UTC", "timestamps are UTC")
cat("All tests passed.\n")
