#!/usr/bin/env Rscript

# Figure 2: Number of records by the 20 most frequent study countries,
# stacked by species.
# Source: validated master evidence-map database.

if (!requireNamespace("ggplot2", quietly = TRUE)) {
  stop("Package 'ggplot2' is required. Install it before running this script.")
}
if (!requireNamespace("taylor", quietly = TRUE)) {
  stop("Package 'taylor' is required for color_palette(). Install it before running this script.")
}

library(dplyr)
library(ggplot2)
library(readr)
library(here)

master_path <- here::here("data", "master", "current", "living_evidence_map_master.csv")
gazetteer_path <- here::here("config", "global_country_gazetteer_v3.csv")
out_dir <- here::here("visualisations")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# User-specified project palette.
project_palette <- taylor::color_palette(c(
  "#2c454a", "#577c84", "#a8bdbe", "#e2b8a2", "#ff9d78", "#e55634"
))

master <- readr::read_csv(
  master_path,
  show_col_types = FALSE,
  progress = FALSE
)

gazetteer <- readr::read_csv(
  gazetteer_path,
  show_col_types = FALSE,
  progress = FALSE
)

required_master <- c("final_primary_country_iso3c", "final_species")
missing_master <- setdiff(required_master, names(master))
if (length(missing_master) > 0) {
  stop("Required columns missing from master: ", paste(missing_master, collapse = ", "))
}

required_gazetteer <- c("iso3c", "country_name")
missing_gazetteer <- setdiff(required_gazetteer, names(gazetteer))
if (length(missing_gazetteer) > 0) {
  stop("Required columns missing from gazetteer: ", paste(missing_gazetteer, collapse = ", "))
}

# Build a single ISO3-to-country-name lookup. The gazetteer contains multiple
# geographic aliases, so retain one country-level label per ISO3 code.
country_lookup <- gazetteer %>%
  transmute(
    iso3c = toupper(trimws(as.character(iso3c))),
    country_name = trimws(as.character(country_name)),
    match_type = tolower(trimws(as.character(match_type))),
    priority = suppressWarnings(as.numeric(priority))
  ) %>%
  filter(
    !is.na(iso3c), iso3c != "",
    !is.na(country_name), country_name != "",
    match_type %in% c("country", "country name")
  ) %>%
  arrange(iso3c, desc(priority), country_name) %>%
  distinct(iso3c, .keep_all = TRUE) %>%
  select(iso3c, country_name)

plot_data <- master %>%
  transmute(
    iso3c = toupper(trimws(as.character(final_primary_country_iso3c))),
    species = trimws(as.character(final_species))
  ) %>%
  mutate(
    species = if_else(
      is.na(species) | species == "",
      "Unspecified species",
      species
    )
  ) %>%
  filter(!is.na(iso3c), iso3c != "") %>%
  left_join(country_lookup, by = "iso3c") %>%
  mutate(country_name = if_else(
    is.na(country_name) | country_name == "",
    iso3c,
    country_name
  ))

# Select the top 20 countries using total record counts before species stratification.
top_countries <- plot_data %>%
  count(iso3c, country_name, name = "records", sort = TRUE) %>%
  slice_head(n = 20)

plot_data <- plot_data %>%
  semi_join(top_countries, by = c("iso3c", "country_name")) %>%
  count(country_name, species, name = "records")

# Order countries by total number of records, from highest to lowest.
country_levels <- top_countries %>%
  arrange(records, country_name) %>%
  pull(country_name)

plot_data <- plot_data %>%
  mutate(country_name = factor(country_name, levels = country_levels))

# Order species by overall frequency so the stack and legend remain stable.
species_levels <- plot_data %>%
  group_by(species) %>%
  summarise(records = sum(records), .groups = "drop") %>%
  arrange(desc(records), species) %>%
  pull(species)

plot_data <- plot_data %>%
  mutate(species = factor(species, levels = species_levels))

# Extend the supplied palette only if the master contains more than six species.
fill_values <- as.character(taylor::color_palette(
  project_palette,
  n = max(6L, length(species_levels))
))
fill_values <- setNames(fill_values[seq_along(species_levels)], species_levels)

p <- ggplot(plot_data, aes(x = country_name, y = records, fill = species)) +
  geom_col(width = 0.78, colour = "white", linewidth = 0.15) +
  coord_flip() +
  scale_fill_manual(values = fill_values, drop = FALSE) +
  scale_y_continuous(
    labels = scales::label_comma(),
    expand = expansion(mult = c(0, 0.04))
  ) +
  labs(
    x = NULL,
    y = "Number of records",
    fill = "Species"
  ) +
  theme_classic(base_size = 11) +
  theme(
    legend.position = "right",
    legend.title = element_text(face = "bold"),
    axis.title = element_text(face = "bold"),
    axis.text = element_text(colour = "black"),
    panel.grid = element_blank()
  )

ggsave(
  filename = file.path(out_dir, "figure_02_records_by_country.pdf"),
  plot = p,
  width = 190,
  height = 135,
  units = "mm",
  device = cairo_pdf
)

ggsave(
  filename = file.path(out_dir, "figure_02_records_by_country.png"),
  plot = p,
  width = 190,
  height = 135,
  units = "mm",
  dpi = 600
)

message("Figure 2 written to: ", out_dir)
