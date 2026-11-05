# antenna_health.R — Antenna health rules over the antenna_activity table.
# Sourced by R/views/antenna_health.R and tests/test_antenna_health.R.
# No side effects: defines thresholds and functions only.
#
# Input: antenna_activity (batchID, port, hour [UTC], n_pulses), one row per
# antenna-hour. Hours with no row for ANY port are treated as receiver
# downtime, not antenna failure. Hours where some ports report and one does
# not are treated as zero pulses on that port.

suppressPackageStartupMessages({ library(dplyr); library(lubridate) })

# ---- Thresholds (documented decisions; see CLAUDE.md) ----------------------

FLAT_HOURS <- 6     # an antenna at <= FLAT_MAX pulses for this many consecutive
                    # receiver-up hours is flagged "flat" (silent port)
FLAT_MAX   <- 0     # pulses/hour at or below this count as silent
HOT_MULT   <- 10    # an hour above HOT_MULT x the antenna's own median is "hot"
HOT_HOURS  <- 3     # ...and HOT_HOURS consecutive hot hours are flagged (noise burst)

# ---- Functions -------------------------------------------------------------

# Fill the antenna-hour grid: for every hour in which the receiver (the `by`
# group) reported on any port, add a zero row for ports that did not report.
complete_hours <- function(act, by = "batchID") {
  act <- act %>% mutate(hour = floor_date(hour, "hour"))
  ports <- act %>% distinct(.data[[by]], port)
  hours <- act %>% distinct(.data[[by]], hour)
  hours %>% inner_join(ports, by = by, relationship = "many-to-many") %>%
    left_join(act %>% group_by(.data[[by]], port, hour) %>%
                summarise(n_pulses = sum(n_pulses, na.rm = TRUE), .groups = "drop"),
              by = c(by, "port", "hour")) %>%
    mutate(n_pulses = coalesce(n_pulses, 0)) %>%
    arrange(.data[[by]], port, hour)
}

# Collapse consecutive flagged hours into spells (one row per run of TRUE).
spells_of <- function(grid, cond_col, by, type) {
  grid %>%
    group_by(.data[[by]], port) %>%
    arrange(hour, .by_group = TRUE) %>%
    mutate(cond = .data[[cond_col]],
           run  = cumsum(coalesce(cond != lag(cond), TRUE) |
                         coalesce(as.numeric(difftime(hour, lag(hour), units = "hours")) > 1, TRUE))) %>%
    filter(cond) %>%
    group_by(.data[[by]], port, run) %>%
    summarise(type = type, start = min(hour), end = max(hour) + hours(1),
              hours = n(), mean_pulses = mean(n_pulses), .groups = "drop") %>%
    select(-run)
}

# Main entry point. Returns list(hourly = completed grid with per-hour flags,
# spells = flagged runs that meet the duration thresholds).
antenna_health <- function(act, by = "batchID") {
  grid <- complete_hours(act, by) %>%
    group_by(.data[[by]], port) %>%
    mutate(median_pulses = median(n_pulses[n_pulses > FLAT_MAX]),
           is_flat = n_pulses <= FLAT_MAX,
           is_hot  = !is.na(median_pulses) & n_pulses > HOT_MULT * median_pulses) %>%
    ungroup()
  spells <- bind_rows(
    spells_of(grid, "is_flat", by, "flat") %>% filter(hours >= FLAT_HOURS),
    spells_of(grid, "is_hot",  by, "hot")  %>% filter(hours >= HOT_HOURS)
  ) %>% arrange(.data[[by]], port, start)
  list(hourly = grid, spells = spells)
}
