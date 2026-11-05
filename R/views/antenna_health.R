# antenna_health.R (view) — Pulses per hour per antenna, with flat lines
# (silent ports) and noise bursts flagged. (Backlog item: antenna health.)
#
# Reads ONLY output/antenna_activity.rds, and applies the rules in
# R/antenna_health.R. Two outputs:
#   antenna_health.png / antenna_health_spells.csv      real data
#   antenna_health_simulated.png / ..._simulated_spells.csv
#       the same view on R/simulate_antenna_activity.R output, which has a
#       known dead port, noise burst and receiver outage. This is the
#       reference picture until the farm receiver produces pulseCounts.
#
# Caveat for project downloads: antenna_activity then comes from the Motus
# `activity` table, which only has hours with tag detections, so a missing
# hour is not evidence that an antenna was silent. Flat-line flags are only
# meaningful on receiver downloads (pulseCounts) or simulated data.
#
# Run from the repo root:  Rscript R/views/antenna_health.R

suppressPackageStartupMessages({ library(dplyr); library(ggplot2); library(lubridate) })
SOURCE_ONLY <- TRUE
source("R/clean_motus.R")               # OUT_DIR
source("R/antenna_health.R")            # thresholds + antenna_health()
source("R/simulate_antenna_activity.R")

# ---- Configuration ---------------------------------------------------------

FIG_DIR    <- file.path(OUT_DIR, "figures")
N_GROUPS   <- 4          # real data: show the N batches with the most antenna-hours
GROUP_BY   <- "batchID"  # antenna_activity has no receiver column; batches stand in
DISPLAY_TZ <- "UTC"      # pulse counts are per UTC hour; keep UTC unless you relabel

dir.create(FIG_DIR, showWarnings = FALSE, recursive = TRUE)

# ---- Plot helper -----------------------------------------------------------

health_plot <- function(h, title, subtitle, by = GROUP_BY) {
  hourly <- h$hourly %>% mutate(group = as.character(.data[[by]]),
                                panel = paste0(by, " ", group, " · port ", port)) %>%
    # don't draw a line across receiver downtime longer than a day
    group_by(panel) %>% arrange(hour, .by_group = TRUE) %>%
    mutate(segment = cumsum(coalesce(as.numeric(difftime(hour, lag(hour), units = "hours")) > 24, TRUE))) %>%
    ungroup()
  spells <- h$spells %>% mutate(group = as.character(.data[[by]]),
                                panel = paste0(by, " ", group, " · port ", port),
                                type = factor(type, levels = c("flat", "hot")))
  p <- ggplot(hourly, aes(hour, n_pulses)) +
    geom_line(aes(group = segment), linewidth = 0.3, colour = "grey30") +
    facet_wrap(~ panel, ncol = 1, scales = "free_y", strip.position = "right") +
    scale_x_datetime(date_labels = "%b %d", name = sprintf("Hour (%s)", DISPLAY_TZ)) +
    labs(title = title, subtitle = subtitle, y = "Pulses per hour",
         caption = sprintf(paste("Flat = <= %d pulses/h for >= %d consecutive receiver-up hours.",
                                 "Hot = > %dx the antenna's median for >= %d hours.",
                                 "Hours with no data on any port are receiver downtime, not shown."),
                           FLAT_MAX, FLAT_HOURS, HOT_MULT, HOT_HOURS)) +
    theme_minimal(base_size = 10) +
    theme(strip.text.y = element_text(angle = 0, size = 8), plot.caption = element_text(hjust = 0, size = 7),
          legend.position = "top")
  if (nrow(spells)) {
    p <- p + geom_rect(data = spells, inherit.aes = FALSE,
                       aes(xmin = start, xmax = end, ymin = -Inf, ymax = Inf, fill = type), alpha = 0.25) +
      scale_fill_manual(values = c(flat = "#d7301f", hot = "#fe9929"), name = "Flag", drop = FALSE)
  }
  p
}

write_health <- function(h, stem, title, subtitle, by = GROUP_BY) {
  png_file <- file.path(FIG_DIR, paste0(stem, ".png"))
  csv_file <- file.path(FIG_DIR, paste0(stem, "_spells.csv"))
  n_panels <- nrow(distinct(h$hourly, .data[[by]], port))
  ggsave(png_file, health_plot(h, title, subtitle, by), width = 10,
         height = max(4, 1.1 * n_panels + 2), dpi = 150, bg = "white", limitsize = FALSE)
  write.csv(h$spells, csv_file, row.names = FALSE)
  cat(sprintf("%s: %d spells flagged (%d flat, %d hot)\n", stem, nrow(h$spells),
              sum(h$spells$type == "flat"), sum(h$spells$type == "hot")))
  if (nrow(h$spells)) print(as.data.frame(h$spells %>% mutate(mean_pulses = round(mean_pulses))), row.names = FALSE)
  cat("Wrote:", png_file, csv_file, "\n")
}

# ---- 1. Simulated receiver (reference picture) -----------------------------

sim <- simulate_antenna_activity()
write_health(antenna_health(sim, by = "batchID"), "antenna_health_simulated",
             "Antenna health: SIMULATED receiver (local test data, never uploaded)",
             "Injected faults: port 3 dies on day 10, port 2 noise burst on day 5, receiver outage day 7 00:00-06:00")

# ---- 2. Real data ----------------------------------------------------------

act_file <- file.path(OUT_DIR, "antenna_activity.rds")
if (file.exists(act_file)) {
  act <- readRDS(act_file) %>% filter(!is.na(hour))
  top <- act %>% count(.data[[GROUP_BY]], name = "n") %>% slice_max(n, n = N_GROUPS)
  sub <- act %>% semi_join(top, by = GROUP_BY)
  h   <- antenna_health(sub, by = GROUP_BY)
  write_health(h, "antenna_health",
               sprintf("Antenna health: %d %ss with the most antenna-hours", nrow(top), GROUP_BY),
               "Project download: hours without tag detections are absent, so flat flags here are NOT evidence of silent antennas")
} else {
  message("No ", act_file, "; only the simulated view was written.")
}
