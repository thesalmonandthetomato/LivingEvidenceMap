#!/usr/bin/env Rscript

# Figure 3: Global choropleth of records by primary study country.
# Uses only the canonical final_primary_country_iso3c field from the
# corrected master. The colour palette matches the existing visualisations.

required <- c("dplyr", "ggplot2", "readr", "sf", "rnaturalearth", "rnaturalearthdata", "scales")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) stop("Install required packages: ", paste(missing, collapse = ", "))

library(dplyr)
library(ggplot2)
library(readr)
library(sf)
library(rnaturalearth)
library(scales)
library(here)

master_path <- here::here("data", "master", "current", "living_evidence_map_master CORRECTED.csv")
out_dir <- here::here("visualisations")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# Existing LivingEvidenceMap palette.
palette <- c("#2c454a", "#577c84", "#a8bdbe", "#e2b8a2", "#ff9d78", "#e55634")

master <- readr::read_csv(master_path, show_col_types = FALSE, progress = FALSE)
if (!"final_primary_country_iso3c" %in% names(master)) {
  stop("Required column missing from master: final_primary_country_iso3c")
}

country_counts <- master %>%
  transmute(iso3c = toupper(trimws(as.character(final_primary_country_iso3c)))) %>%
  filter(!is.na(iso3c), iso3c != "") %>%
  count(iso3c, name = "records")

world <- rnaturalearth::ne_countries(scale = "medium", returnclass = "sf") %>%
  transmute(iso3c = toupper(iso_a3), geometry)

plot_data <- world %>%
  left_join(country_counts, by = "iso3c") %>%
  mutate(records = tidyr::replace_na(records, 0L))

# Quantile breaks are calculated only from countries with records, preventing
# the many zero-count countries from compressing the visual scale.
positive <- plot_data$records[plot_data$records > 0]
if (length(unique(positive)) >= 5) {
  breaks <- unique(as.numeric(stats::quantile(positive, probs = c(0, .2, .4, .6, .8, 1), type = 7)))
  if (length(breaks) < 2) breaks <- c(min(positive), max(positive))
} else {
  breaks <- pretty(positive, n = min(5, length(unique(positive))))
}

# A continuous scale gives a cleaner global map while retaining the project
# palette; zero-count countries remain a pale neutral background.
map_palette <- grDevices::colorRampPalette(palette)(256)

p <- ggplot(plot_data) +
  geom_sf(aes(fill = records), colour = "white", linewidth = 0.12) +
  scale_fill_gradientn(
    colours = map_palette,
    values = scales::rescale(c(0, max(positive, na.rm = TRUE))),
    limits = c(0, max(positive, na.rm = TRUE)),
    oob = scales::squish,
    breaks = scales::pretty_breaks(n = 6),
    labels = scales::label_comma(),
    name = "Records"
  ) +
  coord_sf(expand = FALSE, crs = sf::st_crs(4326)) +
  labs(
    title = "LivingEvidenceMap: records by primary study country",
    subtitle = "Number of records in the corrected master database",
    caption = "Countries with no records are shown as the map background."
  ) +
  theme_void(base_size = 11) +
  theme(
    plot.title = element_text(face = "bold", size = 16, colour = palette[1]),
    plot.subtitle = element_text(size = 10, colour = palette[2], margin = margin(b = 8)),
    plot.caption = element_text(size = 8, colour = palette[2], hjust = 0),
    legend.position = "bottom",
    legend.title = element_text(face = "bold", colour = palette[1]),
    legend.text = element_text(colour = palette[1]),
    legend.key.width = grid::unit(35, "mm"),
    plot.margin = margin(12, 12, 10, 12)
  )

ggsave(file.path(out_dir, "figure_03_choropleth_records_by_country.pdf"), p,
       width = 210, height = 135, units = "mm", device = cairo_pdf)
ggsave(file.path(out_dir, "figure_03_choropleth_records_by_country.png"), p,
       width = 210, height = 135, units = "mm", dpi = 600)

message("Choropleth written to: ", out_dir)
