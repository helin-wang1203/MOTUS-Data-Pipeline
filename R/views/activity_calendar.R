# activity_calendar.R — Seasonal activity calendar: date × hour-of-day heatmap
# of how many tags were detected, one panel per species.
# (Backlog item: seasonal activity calendar.)
#
# Reads ONLY output/detections.rds. Times are stored in UTC; this view
# converts to DISPLAY_TZ for plotting (rule 4: convert only at display, and
# label it). The hour axis starts at noon so that a night is one contiguous
# block, which is what matters for nocturnal migrants.
#
# Run from the repo root:  Rscript R/views/activity_calendar.R

suppressPackageStartupMessages({ library(dplyr); library(ggplot2); library(lubridate) })
SOURCE_ONLY <- TRUE
source("R/clean_motus.R")   # for OUT_DIR

# ---- Configuration ---------------------------------------------------------

DISPLAY_TZ  <- "America/New_York"   # the farm's zone; label on every axis
DAY_START_H <- 12                   # hour axis runs noon → noon so nights are contiguous
MIN_TAGS_SPECIES <- 1               # species with fewer tags are pooled as "Other"
STATION     <- NULL                 # e.g. "Niapiskau" to restrict to one station; NULL = all
SEASON_GAP_DAYS <- 45               # a gap this long with no detections starts a new season panel
MIN_SEASON_DAYS <- 3                # seasons shorter than this are left out (noted in caption)
FIG_DIR     <- file.path(OUT_DIR, "figures")

# ---- Data ------------------------------------------------------------------

det <- readRDS(file.path(OUT_DIR, "detections.rds"))
if (!is.null(STATION)) det <- det %>% filter(station == STATION)

local <- det %>%
  mutate(ts_local = with_tz(ts, DISPLAY_TZ),
         hour     = hour(ts_local),
         # "display date" rolls over at DAY_START_H so one night stays on one row
         date     = as.Date(ts_local - hours(DAY_START_H), tz = DISPLAY_TZ),
         hour_ord = (hour - DAY_START_H) %% 24,
         species  = coalesce(species, "Unknown"))

sp_counts <- local %>% group_by(species) %>% summarise(n_tags = n_distinct(motusTagID), .groups = "drop")
local <- local %>%
  left_join(sp_counts, by = "species") %>%
  mutate(species = if_else(n_tags >= MIN_TAGS_SPECIES, species, "Other"))

# Seasons: runs of detection dates separated by SEASON_GAP_DAYS or more, so
# the x axis is not stretched across empty winters. Labelled "Aug–Oct 2015".
seasons <- local %>% distinct(date) %>% arrange(date) %>%
  mutate(season_id = cumsum(coalesce(as.numeric(date - lag(date)) >= SEASON_GAP_DAYS, TRUE))) %>%
  group_by(season_id) %>%
  summarise(from = min(date), to = max(date), n_days = n_distinct(date), .groups = "drop") %>%
  mutate(season = if_else(year(from) == year(to),
                          sprintf("%s–%s %d", format(from, "%b"), format(to, "%b"), year(from)),
                          sprintf("%s %d – %s %d", format(from, "%b"), year(from), format(to, "%b"), year(to))),
         keep = n_days >= MIN_SEASON_DAYS)
dropped <- seasons %>% filter(!keep)
local <- local %>%
  mutate(season_id = findInterval(date, seasons$from)) %>%
  left_join(seasons %>% select(season_id, season, keep), by = "season_id") %>%
  filter(keep) %>% mutate(season = factor(season, levels = seasons$season))

cells <- local %>%
  group_by(species, season, date, hour_ord) %>%
  summarise(n_tags = n_distinct(motusTagID), n_hits = n(), .groups = "drop")

daily <- local %>% group_by(species, season, date) %>%
  summarise(n_tags = n_distinct(motusTagID), n_hits = n(), .groups = "drop")

dir.create(FIG_DIR, showWarnings = FALSE, recursive = TRUE)
write.csv(cells, file.path(FIG_DIR, "activity_calendar_cells.csv"), row.names = FALSE)

hour_labels <- function(x) sprintf("%02d:00", (x + DAY_START_H) %% 24)
tz_label <- sprintf("Local time (%s). Rows run noon → noon so each night is one block.",
                    DISPLAY_TZ)
if (nrow(dropped)) tz_label <- paste0(tz_label, sprintf(
  "\nNot shown: %d detection day(s) in isolated short periods (%s).", sum(dropped$n_days),
  paste(format(dropped$from, "%Y-%m-%d"), collapse = ", ")))
scope <- if (is.null(STATION)) "all stations" else STATION

# ---- Heatmap: date × hour, per species -------------------------------------

p <- ggplot(cells, aes(date, hour_ord, fill = n_tags)) +
  geom_tile() +
  scale_y_continuous(breaks = seq(0, 23, 3), labels = hour_labels, expand = c(0, 0),
                     name = sprintf("Hour (%s)", DISPLAY_TZ)) +
  scale_x_date(date_breaks = "2 weeks", date_labels = "%b %d", expand = c(0, 0), name = NULL) +
  scale_fill_gradient(name = "Tags\ndetected", low = "#9ecae1", high = "#08306b",
                      breaks = function(l) unique(round(pretty(l)))) +
  facet_grid(species ~ season, scales = "free_x", space = "free_x", labeller = label_wrap_gen(18)) +
  labs(title = sprintf("When are tagged birds detected? (%s)", scope),
       subtitle = "Distinct tags detected in each hour, by species",
       caption = tz_label) +
  theme_minimal(base_size = 10) +
  theme(panel.grid = element_blank(), strip.text.y = element_text(angle = 0, size = 8),
        axis.text.x = element_text(angle = 45, hjust = 1, size = 7),
        plot.caption = element_text(hjust = 0, size = 8), panel.spacing = unit(0.6, "lines"))
n_sp <- n_distinct(cells$species)
heat_file <- file.path(FIG_DIR, "activity_calendar.png")
ggsave(heat_file, p, width = 11, height = 1.3 * n_sp + 2.5, dpi = 150, bg = "white")

# ---- Daily totals: tags per day, stacked by species ------------------------

pd <- ggplot(daily, aes(date, n_tags, fill = species)) +
  geom_col(width = 1) +
  scale_x_date(date_breaks = "2 weeks", date_labels = "%b %d", name = NULL) +
  scale_fill_brewer(palette = "Set2", name = NULL) +
  facet_grid(. ~ season, scales = "free_x", space = "free_x") +
  labs(title = sprintf("Tags detected per day (%s)", scope), y = "Distinct tags",
       caption = sprintf("Day boundary at %02d:00 %s.%s", DAY_START_H, DISPLAY_TZ,
                         if (nrow(dropped)) sub("^.*\n", "\n", tz_label) else "")) +
  theme_minimal(base_size = 10) +
  theme(legend.position = "bottom", axis.text.x = element_text(angle = 45, hjust = 1, size = 7),
        plot.caption = element_text(hjust = 0, size = 8))
daily_file <- file.path(FIG_DIR, "activity_daily.png")
ggsave(daily_file, pd, width = 11, height = 4.5, dpi = 150, bg = "white")

# ---- Summary ---------------------------------------------------------------

night <- local %>% mutate(is_night = hour >= 20 | hour < 6) %>%
  group_by(species) %>% summarise(n_tags = n_distinct(motusTagID), hits = n(),
                                  pct_night_hits = round(100 * mean(is_night)), .groups = "drop") %>%
  arrange(desc(n_tags))
cat("Detections by species (night = 20:00-06:00", DISPLAY_TZ, "):\n")
print(as.data.frame(night), row.names = FALSE)
cat("Wrote:", heat_file, daily_file, "\n")
