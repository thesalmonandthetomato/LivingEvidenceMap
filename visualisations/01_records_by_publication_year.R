#!/usr/bin/env Rscript

# Figure 1: Number of records by publication year, stacked by species.
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
  mutate(
    species = if_else(
      is.na(species) | species == "",
      "Unspecified species",
      species
    )
  ) %>%
  filter(!is.na(publication_year)) %>%
  count(publication_year, species, name = "records")

# Order species by their overall frequency so that the legend and stacks are stable.
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

year_limits <- range(plot_data$publication_year, na.rm = TRUE)

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

# Manuscript-ready vector output plus a high-resolution raster copy.
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
