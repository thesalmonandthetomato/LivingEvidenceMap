#!/usr/bin/env Rscript

# Figure 2: Number of records by the 20 most frequent study countries,
# stacked by species.
# Species is a semicolon-separated multi-value field; records are expanded
# to one record-species observation before counting.
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
library(tidyr)
library(here)

master_path <- here::here("data", "master", "current", "living_evidence_map_master.csv")
gazetteer_path <- here::here("config", "global_country_gazetteer_v3.csv")
out_dir <- here::here("visualisations")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

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
  filter(!is.na(iso3c), iso3c != "") %>%
  separate_rows(species, sep = ";") %>%
  mutate(
    species = trimws(species),
    species = if_else(
      is.na(species) | species == "",
      "Unspecified species",
      species
    )
  ) %>%
  distinct(iso3c, species, .keep_all = TRUE) %>%
  left_join(country_lookup, by = "iso3c") %>%
  mutate(country_name = if_else(
    is.na(country_name) | country_name == "",
    iso3c,
    country_name
  ))

species_levels <- sort(unique(plot_data$species))
if (length(species_levels) != 9L) {
  stop(
    "Expected exactly 9 species levels after splitting final_species on ';'; found ",
    length(species_levels), ": ", paste(species_levels, collapse = ", ")
  )
}

# Select the top 20 countries using record-level counts before species
# stratification. A record assigned to multiple species contributes to each
# corresponding species stratum, but is counted only once within a species.
top_countries <- plot_data %>%
  distinct(iso3c, country_name) %>%
  count(iso3c, country_name, name = "records", sort = TRUE) %>%
  slice_head(n = 20)

plot_data <- plot_data %>%
  semi_join(top_countries, by = c("iso3c", "country_name")) %>%
  count(country_name, species, name = "records")

country_levels <- top_countries %>%
  arrange(records, country_name) %>%
  pull(country_name)

plot_data <- plot_data %>%
  mutate(
    country_name = factor(country_name, levels = country_levels),
    species = factor(species, levels = species_levels)
  )

fill_values <- grDevices::colorRampPalette(as.character(project_palette))(9L)
fill_values <- setNames(fill_values, species_levels)

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
