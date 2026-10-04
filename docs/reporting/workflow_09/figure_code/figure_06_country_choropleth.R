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

# Natural Earth does not use the user-assigned ISO-like code XKX for Kosovo.
# Add an explicit geometry alias only when the Natural Earth data itself
# exposes a Kosovo ADM0 code. No other unmatched project codes are guessed.
if (!"XKX" %in% world$iso3c && "adm0_a3" %in% names(world_raw)) {
  kosovo <- world_raw %>%
    filter(toupper(trimws(adm0_a3)) == "KOS") %>%
    transmute(iso3c = "XKX", name_long, geometry)
  if (nrow(kosovo) == 1L) world <- bind_rows(world, kosovo)
}

unmatched <- anti_join(country_counts, st_drop_geometry(world), by = "iso3c") %>%
  mutate(reason = "No matching Natural Earth geometry; omitted from rendered choropleth only")
write_csv(unmatched, file.path(out_dir, "figure_03_unmatched_geography_codes.csv"))

mapped_counts <- anti_join(country_counts, unmatched %>% select(iso3c), by = "iso3c")
stopifnot(sum(mapped_counts$records) + sum(unmatched$records) == sum(country_counts$records))
if (nrow(unmatched) > 0L) {
  message(
    "Choropleth audit: omitting unresolved map codes without altering canonical data: ",
    paste(sprintf("%s (n=%s)", unmatched$iso3c, unmatched$records), collapse = ", ")
  )
}

plot_data <- world %>% select(iso3c, geometry) %>% left_join(mapped_counts, by = "iso3c") %>% mutate(records = replace_na(records, 0L))
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
  theme_void(base_size = 11) +
  theme(
    plot.background = element_rect(fill = "white", colour = NA),
    panel.background = element_rect(fill = "white", colour = NA),
    legend.background = element_rect(fill = "white", colour = NA),
    legend.key = element_rect(fill = "white", colour = NA),
    legend.position = "bottom",
    legend.title = element_text(face = "bold", colour = palette[1]),
    legend.text = element_text(colour = palette[1]),
    plot.margin = margin(8, 8, 8, 8)
  )

ggsave(file.path(out_dir, "figure_03_choropleth_records_by_country.pdf"), p, width = 210, height = 135, units = "mm", device = cairo_pdf)
ggsave(file.path(out_dir, "figure_03_choropleth_records_by_country.png"), p, width = 210, height = 135, units = "mm", dpi = 600)
write_csv(country_counts, file.path(out_dir, "figure_03_country_counts.csv"))
write_csv(data.frame(fisher_jenks_breaks = breaks), file.path(out_dir, "figure_03_fisher_jenks_breaks.csv"))
message("Choropleth written to: ", out_dir)
