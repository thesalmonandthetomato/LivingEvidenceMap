#!/usr/bin/env Rscript

# Figure 1: Number of records by publication year, stacked by species.
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

required <- c("year", "final_species")
missing <- setdiff(required, names(master))
if (length(missing) > 0) {
  stop("Required columns missing from master: ", paste(missing, collapse = ", "))
}

plot_data <- master %>%
  transmute(
    publication_year = suppressWarnings(as.integer(year)),
    species = trimws(as.character(final_species))
  ) %>%
  filter(!is.na(publication_year)) %>%
  separate_rows(species, sep = ";") %>%
  mutate(
    species = trimws(species),
    species = if_else(
      is.na(species) | species == "",
      "Unspecified species",
      species
    )
  ) %>%
  distinct(publication_year, species, .keep_all = TRUE) %>%
  count(publication_year, species, name = "records")

species_levels <- sort(unique(plot_data$species))
if (length(species_levels) != 9L) {
  stop(
    "Expected exactly 9 species levels after splitting final_species on ';'; found ",
    length(species_levels), ": ", paste(species_levels, collapse = ", ")
  )
}

# Interpolate the supplied six-colour palette to the nine species levels while
# retaining the specified palette as the endpoints/source colours.
fill_values <- grDevices::colorRampPalette(as.character(project_palette))(9L)
fill_values <- setNames(fill_values, species_levels)

plot_data <- plot_data %>%
  mutate(species = factor(species, levels = species_levels))

p <- ggplot(plot_data, aes(x = publication_year, y = records, fill = species)) +
  geom_col(width = 0.85, colour = "white", linewidth = 0.15) +
  scale_fill_manual(values = fill_values, drop = FALSE) +
  scale_x_continuous(
    breaks = scales::breaks_pretty(n = 12),
    expand = expansion(mult = c(0.005, 0.02))
  ) +
  scale_y_continuous(
    labels = scales::label_comma(),
    expand = expansion(mult = c(0, 0.04))
  ) +
  labs(
    x = "Publication year",
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
  filename = file.path(out_dir, "figure_01_records_by_publication_year.pdf"),
  plot = p,
  width = 190,
  height = 120,
  units = "mm",
  device = cairo_pdf
)

ggsave(
  filename = file.path(out_dir, "figure_01_records_by_publication_year.png"),
  plot = p,
  width = 190,
  height = 120,
  units = "mm",
  dpi = 600
)

message("Figure 1 written to: ", out_dir)
