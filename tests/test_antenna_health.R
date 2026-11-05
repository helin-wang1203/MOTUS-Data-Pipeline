# Tests for R/antenna_health.R on simulated data. No network needed.
# Run from the repo root: Rscript tests/test_antenna_health.R
source("R/antenna_health.R")
source("R/simulate_antenna_activity.R")

act <- simulate_antenna_activity()
h   <- antenna_health(act)
sp  <- h$spells
check <- function(cond, msg) { if (!cond) stop("FAIL: ", msg); cat("pass:", msg, "\n") }

flat <- sp[sp$type == "flat", ]
check(nrow(flat) == 1 && flat$port == "3", "exactly one flat spell, on the dead port")
check(flat$start == as_datetime("2027-02-10", tz = "UTC"), "flat spell starts when the port died")
check(flat$hours == 5 * 24, "flat spell runs to the end of the data")
check(!any(sp$port != "3" & sp$type == "flat"), "healthy ports are not flagged flat")

hot <- sp[sp$type == "hot", ]
check(nrow(hot) == 1 && hot$port == "2" && hot$hours == 4, "one 4-hour hot spell on port 2")
check(as.Date(hot$start) == as.Date("2027-02-05"), "hot spell on the right day")

outage <- h$hourly[as.Date(h$hourly$hour) == as.Date("2027-02-07") & hour(h$hourly$hour) < 6, ]
check(nrow(outage) == 0, "receiver outage hours are not filled as zeros")
check(!any(as.Date(sp$start) == as.Date("2027-02-07")), "receiver outage is not flagged as an antenna fault")

# Time-to-detect: the dead port is flagged once FLAT_HOURS silent hours have passed.
first_detect <- flat$start + hours(FLAT_HOURS)
check(as.numeric(difftime(first_detect, as_datetime("2027-02-10", tz = "UTC"), units = "hours")) == FLAT_HOURS,
      sprintf("silent port is detectable after %d hours", FLAT_HOURS))
cat("All antenna health tests passed.\n")
