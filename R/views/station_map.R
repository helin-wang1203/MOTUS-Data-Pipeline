# station_map.R — Regional Motus station map (backlog item: regional station map)
#
# Reads ONLY output/stations.rds (handoff table). Draws every receiver
# deployment within REGION_KM of the farm, marks which are currently active,
# draws an estimated detection-radius circle around each active one, and marks
# the farm site. Writes a static PNG (ggplot2) and an interactive HTML map
# (leaflet, if installed) to output/figures/.
#
# Run from the repo root:  Rscript R/views/station_map.R

suppressPackageStartupMessages({
  library(dplyr); library(ggplot2); library(sf)
})
SOURCE_ONLY <- TRUE
source("R/clean_motus.R")   # for haversine_km() and OUT_DIR

# ---- Configuration ---------------------------------------------------------

FARM_LAT   <- 43.7216      # Dartmouth Organic Farm, Lyme Rd, Hanover NH (approx.;
FARM_LON   <- -72.2468     # replace with the surveyed antenna position)
REGION_KM  <- 150          # show deployments within this distance of the farm
RADIUS_KM  <- 15           # ESTIMATED detection radius for a Yagi on open terrain.
                           # Real range depends on tag, antenna height, terrain.
AS_OF      <- as.POSIXct(Sys.time(), tz = "UTC")   # "active" means active at this time
FIG_DIR    <- file.path(OUT_DIR, "figures")
UTM_CRS    <- 32618        # UTM zone 18N: metres, good for buffers around Hanover

# ---- Data ------------------------------------------------------------------

stations <- readRDS(file.path(OUT_DIR, "stations.rds"))

regional <- stations %>%
  filter(!is.na(lat), !is.na(lon)) %>%
  mutate(dist_km = haversine_km(lat, lon, FARM_LAT, FARM_LON)) %>%
  filter(dist_km <= REGION_KM) %>%
  # One row per site: a station is re-deployed many times under the same name
  # and position; keep the latest deployment and whether any is still active.
  mutate(site = paste(station, round(lat, 3), round(lon, 3))) %>%
  group_by(site) %>%
  summarise(station = first(station), lat = first(lat), lon = first(lon),
            dist_km = first(dist_km),
            n_deployments = n(),
            first_active  = min(active_from, na.rm = TRUE),
            last_active   = suppressWarnings(max(active_to, na.rm = TRUE)),
            active = any(is.na(active_to) | active_to >= AS_OF),
            .groups = "drop") %>%
  mutate(last_active = if_else(active, as.POSIXct(NA), last_active),
         status = if_else(active, "Active", "Inactive")) %>%
  arrange(desc(active), dist_km)

farm <- tibble(station = "Dartmouth Organic Farm (planned)", lat = FARM_LAT, lon = FARM_LON)

# Detection-radius circles around active stations, built in metres then
# returned to lat/lon so they are true circles on the map.
circles <- regional %>% filter(active) %>%
  st_as_sf(coords = c("lon", "lat"), crs = 4326) %>%
  st_transform(UTM_CRS) %>% st_buffer(RADIUS_KM * 1000) %>% st_transform(4326)
farm_circle <- farm %>% st_as_sf(coords = c("lon", "lat"), crs = 4326) %>%
  st_transform(UTM_CRS) %>% st_buffer(RADIUS_KM * 1000) %>% st_transform(4326)

dir.create(FIG_DIR, showWarnings = FALSE, recursive = TRUE)
write.csv(regional %>% select(-site), file.path(FIG_DIR, "station_map_data.csv"),
          row.names = FALSE)

# ---- Static map (ggplot2) --------------------------------------------------

caption <- sprintf(paste(
  "Circles: %d km detection radius, an ESTIMATE (real range depends on tag, antenna",
  "height and terrain). Active = deployment open on %s. Source: Motus receiver metadata."),
  RADIUS_KM, format(AS_OF, "%Y-%m-%d"))
caption_wrapped <- paste(strwrap(caption, width = 110), collapse = "\n")

p <- ggplot() +
  geom_sf(data = circles, fill = "#2b8cbe", colour = "#2b8cbe", alpha = 0.12, linewidth = 0.3) +
  geom_sf(data = farm_circle, fill = NA, colour = "#d7301f", linetype = "dashed", linewidth = 0.5) +
  geom_point(data = regional, aes(lon, lat, shape = status, colour = status), size = 2.2) +
  geom_point(data = farm, aes(lon, lat), shape = 8, colour = "#d7301f", size = 4, stroke = 1.2) +
  geom_text(data = regional %>% filter(active), aes(lon, lat, label = station),
            size = 2.6, vjust = -0.9, check_overlap = TRUE) +
  annotate("text", x = FARM_LON, y = FARM_LAT, label = "Dartmouth Organic Farm",
           colour = "#d7301f", size = 3, vjust = 2, fontface = "bold") +
  scale_shape_manual(values = c(Active = 16, Inactive = 1), name = NULL) +
  scale_colour_manual(values = c(Active = "#08519c", Inactive = "grey55"), name = NULL) +
  coord_sf(crs = 4326, default_crs = 4326,
           xlim = FARM_LON + c(-1, 1) * REGION_KM / 80, ylim = FARM_LAT + c(-1, 1) * REGION_KM / 111) +
  labs(title = sprintf("Motus receivers within %d km of the Dartmouth Organic Farm", REGION_KM),
       subtitle = sprintf("%d active, %d inactive sites (%d deployments)",
                          sum(regional$active), sum(!regional$active), sum(regional$n_deployments)),
       x = NULL, y = NULL, caption = caption_wrapped) +
  theme_minimal(base_size = 11) +
  theme(legend.position = "top", plot.caption = element_text(hjust = 0, size = 8),
        panel.grid = element_line(colour = "grey92"))

png_file <- file.path(FIG_DIR, "station_map.png")
ggsave(png_file, p, width = 8, height = 8.5, dpi = 150, bg = "white")

# ---- Interactive map (leaflet) --------------------------------------------

html_file <- file.path(FIG_DIR, "station_map.html")
if (requireNamespace("leaflet", quietly = TRUE) && requireNamespace("htmlwidgets", quietly = TRUE)) {
  act <- regional %>% filter(active); inact <- regional %>% filter(!active)
  popup <- function(d) sprintf(
    "<b>%s</b><br/>%s<br/>%.0f km from farm<br/>%d deployment(s) since %s%s",
    d$station, d$status, d$dist_km, d$n_deployments, format(d$first_active, "%Y-%m-%d"),
    ifelse(d$active, "", paste0("<br/>last active ", format(d$last_active, "%Y-%m-%d"))))
  m <- leaflet::leaflet() %>%
    leaflet::addProviderTiles("CartoDB.Positron") %>%
    leaflet::addCircles(data = act, lng = ~lon, lat = ~lat, radius = RADIUS_KM * 1000,
                        color = "#2b8cbe", weight = 1, fillOpacity = 0.10,
                        group = sprintf("Detection radius (%d km, estimate)", RADIUS_KM)) %>%
    leaflet::addCircles(lng = FARM_LON, lat = FARM_LAT, radius = RADIUS_KM * 1000,
                        color = "#d7301f", weight = 1.5, dashArray = "6", fill = FALSE,
                        group = sprintf("Detection radius (%d km, estimate)", RADIUS_KM)) %>%
    leaflet::addCircleMarkers(data = inact, lng = ~lon, lat = ~lat, radius = 4,
                              color = "grey", fillOpacity = 0.6, popup = popup(inact),
                              group = "Inactive stations") %>%
    leaflet::addCircleMarkers(data = act, lng = ~lon, lat = ~lat, radius = 6,
                              color = "#08519c", fillOpacity = 0.9, popup = popup(act),
                              label = ~station, group = "Active stations") %>%
    leaflet::addMarkers(lng = FARM_LON, lat = FARM_LAT, label = farm$station,
                        popup = "<b>Dartmouth Organic Farm</b><br/>planned station (position approximate)") %>%
    leaflet::addLayersControl(
      overlayGroups = c("Active stations", "Inactive stations",
                        sprintf("Detection radius (%d km, estimate)", RADIUS_KM)),
      options = leaflet::layersControlOptions(collapsed = FALSE)) %>%
    leaflet::addControl(html = paste0("<small>", caption, "</small>"), position = "bottomleft")
  htmlwidgets::saveWidget(m, normalizePath(html_file, mustWork = FALSE),
                          selfcontained = nzchar(Sys.which("pandoc")), title = "Motus stations near Hanover")
} else {
  message("leaflet/htmlwidgets not installed; skipping interactive map.")
}

# ---- Summary ---------------------------------------------------------------

cat(sprintf("Stations within %d km of the farm: %d sites (%d active)\n",
            REGION_KM, nrow(regional), sum(regional$active)))
print(regional %>% filter(active) %>% select(station, dist_km, first_active) %>%
        mutate(dist_km = round(dist_km)) %>% as.data.frame(), row.names = FALSE)
cat("Wrote:", png_file, if (file.exists(html_file)) html_file else "", "\n")
