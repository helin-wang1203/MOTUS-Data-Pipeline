# flyby.R — Signal strength vs. time for one tag passing one station,
# one line per antenna. (Backlog item: flyby plot.)
#
# Reads ONLY output/detections.rds and output/visits.rds. A "flyby" here is a
# visit (tag × station, see make_visits()) that is short and was heard on more
# than one antenna. The shape of the curves is the visual check that the
# port → antenna-bearing map is right: a bird moving past a station should
# peak on antennas in the order it passes their bearings.
#
# Run from the repo root:  Rscript R/views/flyby.R
#   Picks the best candidate flybys automatically; set TAG_ID / VISIT_ID to
#   plot a specific one.

suppressPackageStartupMessages({ library(dplyr); library(ggplot2) })
SOURCE_ONLY <- TRUE
source("R/clean_motus.R")   # for OUT_DIR

# ---- Configuration ---------------------------------------------------------

TAG_ID      <- NULL        # e.g. 22897; NULL = choose automatically
VISIT_ID    <- NULL        # visitID within that tag; NULL = choose automatically
MIN_ANTS    <- 2           # a flyby must be heard on at least this many antennas
MAX_MINUTES <- 90          # longer visits are stopovers, not flybys
MIN_HITS    <- 20
N_PANELS    <- 6           # how many candidate flybys to show in the grid
GAP_BREAK_MIN <- 3         # don't connect points on one antenna across a gap this long
FIG_DIR     <- file.path(OUT_DIR, "figures")

# ---- Data ------------------------------------------------------------------

det    <- readRDS(file.path(OUT_DIR, "detections.rds"))
visits <- readRDS(file.path(OUT_DIR, "visits.rds"))

# Antenna label: bearing when known, otherwise the port number. On the farm
# station every port will have a bearing; in sample data most do not.
det <- det %>% mutate(
  antenna = if_else(is.na(antBearing), paste0("port ", port, " (bearing unknown)"),
                    sprintf("%g° (port %s)", antBearing, port)))
ant_levels <- det %>% distinct(antenna, antBearing, port) %>%
  arrange(is.na(antBearing), antBearing, port) %>% pull(antenna)
det <- det %>% mutate(antenna = factor(antenna, levels = ant_levels))

# Attach each detection to its visit by tag, station and time window.
hits <- det %>%
  inner_join(visits %>% select(motusTagID, recvDeployID, visitID, t_start, t_end),
             by = c("motusTagID", "recvDeployID"),
             relationship = "many-to-many") %>%
  filter(ts >= t_start, ts <= t_end) %>%
  mutate(minutes = as.numeric(difftime(ts, t_start, units = "mins"))) %>%
  # Break each antenna's line where the tag went quiet on it.
  arrange(motusTagID, visitID, antenna, ts) %>%
  group_by(motusTagID, visitID, antenna) %>%
  mutate(segment = cumsum(coalesce(minutes - lag(minutes) > GAP_BREAK_MIN, FALSE))) %>%
  ungroup()

candidates <- hits %>%
  group_by(motusTagID, visitID, species, station) %>%
  summarise(n_hits = n(), n_ants = n_distinct(antenna),
            duration_min = as.numeric(difftime(max(ts), min(ts), units = "mins")),
            t_start = first(t_start), .groups = "drop") %>%
  filter(n_ants >= MIN_ANTS, duration_min <= MAX_MINUTES, n_hits >= MIN_HITS) %>%
  arrange(desc(n_ants), desc(n_hits))

if (!is.null(TAG_ID)) {
  candidates <- candidates %>% filter(motusTagID == TAG_ID)
  if (!is.null(VISIT_ID)) candidates <- candidates %>% filter(visitID == VISIT_ID)
}
if (!nrow(candidates)) stop("No visit matches the flyby criteria; relax MIN_ANTS/MAX_MINUTES.")

dir.create(FIG_DIR, showWarnings = FALSE, recursive = TRUE)
write.csv(candidates, file.path(FIG_DIR, "flyby_candidates.csv"), row.names = FALSE)

panel_title <- function(c) sprintf("Tag %d (%s) at %s\n%s UTC, %d hits on %d antennas",
                                    c$motusTagID, c$species, c$station,
                                    format(c$t_start, "%Y-%m-%d %H:%M"), c$n_hits, c$n_ants)

flyby_plot <- function(h, title) {
  ggplot(h, aes(minutes, sig, colour = antenna)) +
    geom_line(aes(group = interaction(antenna, segment)), alpha = 0.6, linewidth = 0.4) +
    geom_point(size = 1.2) +
    scale_colour_brewer(palette = "Dark2", name = "Antenna") +
    labs(title = title, x = "Minutes since first hit", y = "Signal strength (dB)") +
    theme_minimal(base_size = 11) + theme(legend.position = "bottom")
}

# ---- Single flyby (best candidate, or the one requested) ------------------

best <- candidates[1, ]
h1 <- hits %>% filter(motusTagID == best$motusTagID, visitID == best$visitID)
p1 <- flyby_plot(h1, panel_title(best)) +
  labs(caption = "Each line is one antenna. Order of peaks = direction of travel past the station.")
single_file <- file.path(FIG_DIR, sprintf("flyby_tag%d_visit%d.png", best$motusTagID, best$visitID))
ggsave(single_file, p1, width = 8, height = 5, dpi = 150, bg = "white")

# ---- Grid of candidate flybys ---------------------------------------------

# One panel per tag × station so the grid shows different birds and receivers.
top <- candidates %>% group_by(motusTagID, station) %>% slice(1) %>% ungroup() %>%
  arrange(desc(n_ants), desc(n_hits)) %>% head(N_PANELS)
top <- top %>% mutate(panel = panel_title(top))
hg  <- hits %>% inner_join(top %>% select(motusTagID, visitID, panel),
                           by = c("motusTagID", "visitID")) %>%
  mutate(panel = factor(panel, levels = top$panel))
pg <- flyby_plot(hg, sprintf("Candidate flybys: best short multi-antenna visit for %d tag/station pairs", nrow(top))) +
  facet_wrap(~ panel, scales = "free", ncol = 2) +
  theme(strip.text = element_text(size = 8))
grid_file <- file.path(FIG_DIR, "flyby_grid.png")
ggsave(grid_file, pg, width = 10, height = 3.2 * ceiling(nrow(top) / 2) + 1, dpi = 150, bg = "white")

cat(sprintf("%d candidate flybys (<= %d min, >= %d antennas, >= %d hits)\n",
            nrow(candidates), MAX_MINUTES, MIN_ANTS, MIN_HITS))
print(head(as.data.frame(candidates %>% mutate(duration_min = round(duration_min, 1))), 10), row.names = FALSE)
cat("Wrote:", single_file, grid_file, "\n")
