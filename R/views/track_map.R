# track_map.R — One tag's track: its stops at stations in time order.
# (Backlog item: track map.)
#
# Reads ONLY output/visits.rds. Consecutive visits at the same station are
# merged into one "stop" (first arrival to last departure), because visits are
# split at every VISIT_GAP_HOURS gap and a bird that stays for days produces
# dozens of them. Points are coloured by date and sized by stop duration;
# lines join stops in time order. Writes a static PNG (ggplot2) and an
# interactive HTML map (leaflet) for one tag, plus a small-multiples PNG of
# every tag with more than one station.
#
# Run from the repo root:  Rscript R/views/track_map.R
#   Set TAG_ID to choose a tag; NULL picks the tag seen at the most stations.

suppressPackageStartupMessages({ library(dplyr); library(ggplot2) })
SOURCE_ONLY <- TRUE
source("R/clean_motus.R")   # for OUT_DIR, haversine_km()

# ---- Configuration ---------------------------------------------------------

TAG_ID   <- NULL                      # e.g. 16039; NULL = auto
FIG_DIR  <- file.path(OUT_DIR, "figures")
MIN_STATIONS_OVERVIEW <- 2            # tags with fewer stations are skipped in the overview

# ---- Data ------------------------------------------------------------------

visits <- readRDS(file.path(OUT_DIR, "visits.rds"))

# Merge consecutive visits at the same station into stops.
stops <- visits %>%
  arrange(motusTagID, t_start) %>%
  group_by(motusTagID) %>%
  mutate(stopID = cumsum(is.na(lag(recvDeployID)) | recvDeployID != lag(recvDeployID))) %>%
  group_by(motusTagID, stopID) %>%
  summarise(species = first(species), station = first(station),
            lat = first(lat), lon = first(lon),
            arrive = min(t_start), depart = max(t_end),
            n_visits = n(), n_hits = sum(n_hits), .groups = "drop") %>%
  mutate(stop_h = as.numeric(difftime(depart, arrive, units = "hours")),
         date   = as.Date(arrive))

tag_summary <- stops %>% group_by(motusTagID, species) %>%
  summarise(n_stops = n(), n_stations = n_distinct(station),
            first = min(arrive), last = max(depart),
            track_km = sum(haversine_km(lat, lon, lead(lat), lead(lon)), na.rm = TRUE),
            .groups = "drop") %>%
  arrange(desc(n_stations), desc(track_km))

if (is.null(TAG_ID)) TAG_ID <- tag_summary$motusTagID[1]
tag <- stops %>% filter(motusTagID == TAG_ID)
if (!nrow(tag)) stop("Tag ", TAG_ID, " not in visits.")
ts  <- tag_summary %>% filter(motusTagID == TAG_ID)

dir.create(FIG_DIR, showWarnings = FALSE, recursive = TRUE)
write.csv(stops, file.path(FIG_DIR, "track_stops.csv"), row.names = FALSE)

# ---- Static map for one tag -----------------------------------------------

title <- sprintf("Tag %d (%s): %d stops at %d stations\n%s to %s, ~%.0f km along the track",
                 TAG_ID, ts$species, ts$n_stops, ts$n_stations,
                 format(ts$first, "%Y-%m-%d"), format(ts$last, "%Y-%m-%d"), ts$track_km)
caption <- paste("Lines join stops in time order (straight lines, not flight paths).",
                 "Point size = time between first and last detection at that stop.",
                 "No basemap: positions are receiver locations.", sep = "\n")

# Label each station once, at its first stop, to keep the map readable.
labels <- tag %>% group_by(station) %>% slice_min(arrive, n = 1) %>% ungroup()

p <- ggplot(tag, aes(lon, lat)) +
  geom_path(colour = "grey50", linewidth = 0.5,
            arrow = arrow(length = unit(0.18, "cm"), type = "closed", ends = "last")) +
  geom_point(aes(colour = date, size = stop_h), alpha = 0.85) +
  geom_text(data = labels, aes(label = station), size = 2.6, vjust = -1.1, check_overlap = TRUE) +
  scale_colour_viridis_c(trans = "date", name = "Arrival date") +
  scale_size_continuous(range = c(1.5, 9), name = "Stop (h)") +
  coord_quickmap() +
  labs(title = title, x = NULL, y = NULL, caption = caption) +
  theme_minimal(base_size = 11) + theme(plot.caption = element_text(hjust = 0, size = 8))
single_file <- file.path(FIG_DIR, sprintf("track_tag%d.png", TAG_ID))
ggsave(single_file, p, width = 8, height = 7, dpi = 150, bg = "white")

# ---- Interactive map for one tag ------------------------------------------

html_file <- file.path(FIG_DIR, sprintf("track_tag%d.html", TAG_ID))
if (requireNamespace("leaflet", quietly = TRUE) && requireNamespace("htmlwidgets", quietly = TRUE)) {
  pal <- leaflet::colorNumeric("viridis", as.numeric(range(tag$date)))
  m <- leaflet::leaflet(tag) %>%
    leaflet::addProviderTiles("CartoDB.Positron") %>%
    leaflet::addPolylines(lng = ~lon, lat = ~lat, color = "grey40", weight = 2, opacity = 0.7) %>%
    leaflet::addCircleMarkers(
      lng = ~lon, lat = ~lat, radius = ~pmax(4, pmin(20, 4 + 1.5 * sqrt(stop_h))),
      color = ~pal(as.numeric(date)), fillOpacity = 0.8, stroke = FALSE,
      label = ~sprintf("%d. %s", stopID, station),
      popup = ~sprintf("<b>%d. %s</b><br/>%s to %s UTC<br/>%.1f h, %d hits, %d visit(s)",
                       stopID, station, format(arrive, "%Y-%m-%d %H:%M"),
                       format(depart, "%Y-%m-%d %H:%M"), stop_h, n_hits, n_visits)) %>%
    leaflet::addLegend("bottomright", pal = pal, values = ~as.numeric(date),
                       title = "Arrival date",
                       labFormat = leaflet::labelFormat(transform = function(x) as.Date(x, origin = "1970-01-01"))) %>%
    leaflet::addControl(html = paste0("<small>", gsub("\n", " ", caption), "</small>"), position = "bottomleft")
  htmlwidgets::saveWidget(m, normalizePath(html_file, mustWork = FALSE),
                          selfcontained = nzchar(Sys.which("pandoc")), title = gsub("\n", " ", title))
}

# ---- Overview: every multi-station tag ------------------------------------

multi <- stops %>% semi_join(tag_summary %>% filter(n_stations >= MIN_STATIONS_OVERVIEW),
                             by = "motusTagID") %>%
  mutate(panel = sprintf("%d %s", motusTagID, species))
po <- ggplot(multi, aes(lon, lat)) +
  geom_path(colour = "grey50", linewidth = 0.4) +
  geom_point(aes(colour = date, size = stop_h), alpha = 0.85) +
  scale_colour_viridis_c(trans = "date", name = "Arrival date") +
  scale_size_continuous(range = c(1, 6), name = "Stop (h)") +
  coord_quickmap() + facet_wrap(~ panel) +
  labs(title = sprintf("Tracks of all %d tags detected at %d+ stations", n_distinct(multi$motusTagID),
                       MIN_STATIONS_OVERVIEW), x = NULL, y = NULL) +
  theme_minimal(base_size = 10) + theme(axis.text = element_text(size = 6))
overview_file <- file.path(FIG_DIR, "track_overview.png")
ggsave(overview_file, po, width = 10, height = 8, dpi = 150, bg = "white")

cat("Tag summary (most stations first):\n")
print(as.data.frame(tag_summary %>% mutate(track_km = round(track_km))), row.names = FALSE)
cat("\nStops for tag", TAG_ID, ":\n")
print(as.data.frame(tag %>% transmute(stopID, station, arrive, stop_h = round(stop_h, 1), n_hits)), row.names = FALSE)
cat("Wrote:", single_file, if (file.exists(html_file)) html_file else "", overview_file, "\n")
