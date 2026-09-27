#!/usr/bin/env Rscript

# Figure 3: Global choropleth of included canonical records by study country.
# Source: Workflow 08 included-only canonical JSONL.

required <- c("dplyr", "ggplot2", "readr", "sf", "tidyr", "classInt", "rnaturalearth", "here", "jsonlite")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) stop("Install required packages: ", paste(missing, collapse = ", "))

library(dplyr); library(ggplot2); library(readr); library(sf); library(tidyr); library(here)
source(here::here("visualisations", "canonical_figure_data.R"))

out_dir <- here::here("visualisations")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
palette <- c("#2c454a", "#577c84", "#a8bdbe", "#e2b8a2", "#ff9d78", "#e55634")

master <- load_figure_master()
country_counts <- master %>%
  transmute(record_id, raw_country = as.character(final_primary_country_iso3c)) %>%
  filter(!is.na(raw_country), trimws(raw_country) != "") %>%
  separate_rows(raw_country, sep = ";") %>%
  mutate(iso3c = toupper(trimws(raw_country))) %>%
  filter(iso3c != "", iso3c != "NONE") %>%
  distinct(record_id, iso3c) %>%
  mutate(map_iso3c = case_when(iso3c == "SJM" ~ "NOR", iso3c %in% c("JEY", "IMN") ~ "GBR", TRUE ~ iso3c)) %>%
  count(map_iso3c, name = "records") %>% rename(iso3c = map_iso3c)

world_raw <- rnaturalearth::ne_countries(scale = "medium", returnclass = "sf")
world <- world_raw %>% transmute(iso3c = toupper(trimws(iso_a3_eh)), name_long, geometry)
unmatched <- anti_join(country_counts, st_drop_geometry(world), by = "iso3c")
if (nrow(unmatched) > 0) stop("Unmatched project ISO3 codes after normalisation: ", paste(unmatched$iso3c, collapse = ", "))

plot_data <- world %>% select(iso3c, geometry) %>% left_join(country_counts, by = "iso3c") %>% mutate(records = replace_na(records, 0L))
positive <- plot_data$records[plot_data$records > 0]
n_breaks <- min(7L, length(unique(positive)))
fisher <- classInt::classIntervals(positive, n = n_breaks, style = "fisher")
breaks <- fisher$brks
positive_labels <- vapply(seq_len(length(breaks) - 1), function(i) {
  lo <- if (i == 1) ceiling(breaks[i]) else floor(breaks[i]) + 1
  hi <- floor(breaks[i + 1])
  paste0(lo, "–", hi)
}, character(1))
plot_data$records_class <- cut(plot_data$records, breaks = c(-Inf, 0, breaks[-1]), labels = c("0", positive_labels), include.lowest = TRUE, right = TRUE)
class_cols <- c("0" = "#eeeeee", setNames(grDevices::colorRampPalette(palette[3:6])(length(positive_labels)), positive_labels))

p <- ggplot(plot_data) +
  geom_sf(aes(fill = records_class), colour = "white", linewidth = 0.12) +
  scale_fill_manual(values = class_cols, drop = FALSE, name = "Included records", guide = guide_legend(title.position = "top", nrow = 2, byrow = TRUE, keywidth = grid::unit(12, "mm"), keyheight = grid::unit(5, "mm"))) +
  coord_sf(expand = FALSE, crs = sf::st_crs(4326)) +
  labs(title = "Living Evidence Map: included records by study country", subtitle = "Workflow 08 included-only canonical JSONL", caption = "Multi-country records count once for each represented country; territory codes are assigned to their sovereign state. Positive-count classes use Fisher–Jenks natural breaks.") +
  theme_void(base_size = 11) +
  theme(plot.title = element_text(face = "bold", size = 16, colour = palette[1]), plot.subtitle = element_text(size = 10, colour = palette[2], margin = margin(b = 8)), plot.caption = element_text(size = 8, colour = palette[2], hjust = 0), legend.position = "bottom", legend.title = element_text(face = "bold", colour = palette[1]), legend.text = element_text(colour = palette[1]), plot.margin = margin(12, 12, 10, 12))

ggsave(file.path(out_dir, "figure_03_choropleth_records_by_country.pdf"), p, width = 210, height = 135, units = "mm", device = cairo_pdf)
ggsave(file.path(out_dir, "figure_03_choropleth_records_by_country.png"), p, width = 210, height = 135, units = "mm", dpi = 600)
write_csv(country_counts, file.path(out_dir, "figure_03_country_counts.csv"))
write_csv(data.frame(fisher_jenks_breaks = breaks), file.path(out_dir, "figure_03_fisher_jenks_breaks.csv"))
message("Choropleth written to: ", out_dir)
