# simulate_antenna_activity.R — Synthetic antenna_activity table for testing
# the health monitor. LOCAL USE ONLY: never upload simulated data to Motus.
#
# One receiver, hourly rows for `days` days, with a diurnal pulse rate and
# Poisson noise, plus injected faults:
#   - port `dead_port` stops reporting from `dead_from_day` (flat line)
#   - port `hot_port` has a noise burst of `hot_hours` hours on `hot_day`
#   - the whole receiver is down (no rows on any port) on `outage_day` 00:00-05:59
suppressPackageStartupMessages({ library(dplyr); library(lubridate) })

simulate_antenna_activity <- function(days = 14, ports = 1:4, start = as_datetime("2027-02-01", tz = "UTC"),
                                      dead_port = 3, dead_from_day = 10,
                                      hot_port = 2, hot_day = 5, hot_hours = 4,
                                      outage_day = 7, base_rate = 40, seed = 42) {
  set.seed(seed)
  hrs <- start + hours(seq_len(days * 24) - 1)
  grid <- expand.grid(hour = hrs, port = ports) %>% as_tibble() %>%
    mutate(batchID = 1L,
           day  = as.integer(floor(as.numeric(difftime(hour, start, units = "days")))) + 1L,
           hod  = hour(hour),
           rate = base_rate * (1 + 0.6 * sin((hod - 6) / 24 * 2 * pi)) * (0.8 + 0.1 * port),
           n_pulses = rpois(n(), rate))
  grid %>%
    mutate(n_pulses = if_else(port == hot_port & day == hot_day & hod < hot_hours,
                              n_pulses + as.integer(50 * base_rate), n_pulses)) %>%
    filter(!(port == dead_port & day >= dead_from_day)) %>%
    filter(!(day == outage_day & hod < 6)) %>%
    select(batchID, port, hour, n_pulses) %>%
    mutate(port = as.character(port))
}
