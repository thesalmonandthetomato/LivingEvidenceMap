#!/usr/bin/env Rscript

# Figure 3: Global choropleth of records by primary study country.
# Canonical geography field: final_primary_country_iso3c.

required <- c("dplyr", "ggplot2", "readr", "sf", "tidyr")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) stop("Install required packages: ", paste(missing, collapse = ", "))

library(dplyr)
library(ggplot2)
library(readr)
library(sf)
library(tidyr)
library(here)

master_path <- here::here("data", "master", "current", "living_evidence_map_master CORRECTED.csv")
out_dir <- here::here("visualisations")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
palette <- c("#2c454a", "#577c84", "#a8bdbe", "#e2b8a2", "#ff9d78", "#e55634")

master <- readr::read_csv(master_path, show_col_types = FALSE, progress = FALSE)
if (!"final_primary_country_iso3c" %in% names(master)) stop("Required column missing from master: final_primary_country_iso3c")

country_counts <- master %>%
  transmute(raw_country = as.character(final_primary_country_iso3c)) %>%
  filter(!is.na(raw_country), trimws(raw_country) != "") %>%
  mutate(iso3c = strsplit(raw_country, "\\s*;\\s*")) %>%
  unnest(iso3c) %>%
  mutate(iso3c = toupper(trimws(iso3c))) %>%
  filter(iso3c != "", iso3c != "NONE") %>%
  mutate(map_iso3c = case_when(
    iso3c == "SJM" ~ "NOR",
    iso3c %in% c("JEY", "IMN") ~ "GBR",
    TRUE ~ iso3c
  )) %>%
  group_by(map_iso3c) %>%
  summarise(records = n(), .groups = "drop") %>%
  rename(iso3c = map_iso3c)

# Retain name_long temporarily so Kosovo can be identified if Natural Earth
# does not provide XKX in its ISO field.
world_raw <- rnaturalearth::ne_countries(scale = "medium", returnclass = "sf")
world <- world_raw %>%
  transmute(iso3c = toupper(trimws(iso_a3_eh)), name_long, geometry)

if (!"XKX" %in% world$iso3c) {
  kosovo <- world %>% filter(tolower(name_long) == "kosovo") %>% mutate(iso3c = "XKX")
  if (nrow(kosovo) > 0) world <- bind_rows(world, kosovo)
}

unmatched <- anti_join(country_counts, st_drop_geometry(world), by = "iso3c")
if (nrow(unmatched) > 0) {
  stop("Unmatched project ISO3 codes after normalisation: ", paste(unmatched$iso3c, collapse = ", "))
}

plot_data <- world %>%
  select(iso3c, geometry) %>%
  left_join(country_counts, by = "iso3c") %>%
  mutate(records = replace_na(records, 0L),
         records_bin = cut(records, breaks = c(-Inf, 0, 5, 25, 100, 500, Inf),
                           labels = c("0", "1–5", "6–25", "26–100", "101–500", ">500"), right = TRUE))

bin_cols <- c("0" = "#eeeeee", "1–5" = palette[3], "6–25" = palette[2],
              "26–100" = palette[1], "101–500" = palette[5], ">500" = palette[6])

p <- ggplot(plot_data) +
  geom_sf(aes(fill = records_bin), colour = "white", linewidth = 0.12) +
  scale_fill_manual(values = bin_cols, drop = FALSE, name = "Records",
                    guide = guide_legend(title.position = "top", nrow = 1, byrow = TRUE,
                                         keywidth = grid::unit(12, "mm"), keyheight = grid::unit(5, "mm"))) +
  coord_sf(expand = FALSE, crs = sf::st_crs(4326)) +
  labs(title = "LivingEvidenceMap: records by primary study country",
       subtitle = "Number of records in the corrected master database",
       caption = "Multi-country records count once for each represented country; Svalbard/Jan Mayen, Jersey and Isle of Man are assigned to their sovereign state.") +
  theme_void(base_size = 11) +
  theme(plot.title = element_text(face = "bold", size = 16, colour = palette[1]),
        plot.subtitle = element_text(size = 10, colour = palette[2], margin = margin(b = 8)),
        plot.caption = element_text(size = 8, colour = palette[2], hjust = 0),
        legend.position = "bottom", legend.title = element_text(face = "bold", colour = palette[1]),
        legend.text = element_text(colour = palette[1]), plot.margin = margin(12, 12, 10, 12))

ggsave(file.path(out_dir, "figure_03_choropleth_records_by_country.pdf"), p, width = 210, height = 135, units = "mm", device = cairo_pdf)
ggsave(file.path(out_dir, "figure_03_choropleth_records_by_country.png"), p, width = 210, height = 135, units = "mm", dpi = 600)

write_csv(country_counts, file.path(out_dir, "figure_03_country_counts.csv"))
if ("NOR" %in% country_counts$iso3c) message("NOR records: ", country_counts$records[country_counts$iso3c == "NOR"])
message("Choropleth written to: ", out_dir)
