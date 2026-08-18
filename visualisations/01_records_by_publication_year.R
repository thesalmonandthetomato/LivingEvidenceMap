#!/usr/bin/env Rscript

# Figure 1: Number of records by publication year, stacked by species.
# Species is a semicolon-separated multi-value field; records are expanded
# to one record-species observation before counting. Species labels are then
# normalised to the nine canonical farmed-salmon categories.
# Source: validated master evidence-map database.

if (!requireNamespace("ggplot2", quietly = TRUE)) stop("Package 'ggplot2' is required.")
if (!requireNamespace("taylor", quietly = TRUE)) stop("Package 'taylor' is required for color_palette().")

library(dplyr); library(ggplot2); library(readr); library(tidyr); library(here)

master_path <- here::here("data", "master", "current", "living_evidence_map_master.csv")
out_dir <- here::here("visualisations")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

project_palette <- taylor::color_palette(c("#2c454a", "#577c84", "#a8bdbe", "#e2b8a2", "#ff9d78", "#e55634"))

canonical_species <- c("Atlantic salmon", "Chinook salmon", "Chum salmon", "Coho salmon", "Masu salmon", "Pink salmon", "Rainbow trout", "Sockeye salmon", "Unspecified species")

normalise_species <- function(x) {
  x <- trimws(x); x_lower <- tolower(x)
  dplyr::case_when(
    x_lower == "atlantic salmon" ~ "Atlantic salmon",
    x_lower == "chinook salmon" ~ "Chinook salmon",
    x_lower == "chum salmon" ~ "Chum salmon",
    x_lower == "coho salmon" ~ "Coho salmon",
    x_lower == "masu salmon" ~ "Masu salmon",
    x_lower == "pink salmon" ~ "Pink salmon",
    x_lower %in% c("rainbow salmon", "rainbow trout", "steelhead", "steelhead trout") ~ "Rainbow trout",
    x_lower == "sockeye salmon" ~ "Sockeye salmon",
    x_lower %in% c("unspecified species", "unspecified farmed salmon", "unspecified salmon", "farmed salmon") ~ "Unspecified species",
    TRUE ~ x
  )
}

master <- readr::read_csv(master_path, show_col_types = FALSE, progress = FALSE)
required <- c("year", "final_species")
missing <- setdiff(required, names(master))
if (length(missing) > 0) stop("Required columns missing from master: ", paste(missing, collapse = ", "))

plot_data <- master %>%
  transmute(record_id = row_number(), publication_year = suppressWarnings(as.integer(year)), species = trimws(as.character(final_species))) %>%
  filter(!is.na(publication_year)) %>%
  separate_rows(species, sep = ";") %>%
  mutate(species = normalise_species(species), species = if_else(is.na(species) | species == "", "Unspecified species", species)) %>%
  distinct(record_id, species, .keep_all = TRUE)

unexpected_species <- setdiff(unique(plot_data$species), canonical_species)
if (length(unexpected_species) > 0L) stop("Unexpected species categories after normalisation: ", paste(sort(unexpected_species), collapse = ", "))

plot_data <- plot_data %>% count(publication_year, species, name = "records") %>% mutate(species = factor(species, levels = canonical_species))

pacific_values <- grDevices::colorRampPalette(as.character(project_palette[1:3]))(7L)
fill_values <- c("Atlantic salmon" = "#e55634", setNames(pacific_values, canonical_species[2:8]), "Unspecified species" = "#e2b8a2")

p <- ggplot(plot_data, aes(x = publication_year, y = records, fill = species)) +
  geom_col(width = 0.85, colour = "white", linewidth = 0.15) +
  scale_fill_manual(values = fill_values, drop = FALSE) +
  scale_x_continuous(breaks = scales::breaks_pretty(n = 12), expand = expansion(mult = c(0.005, 0.02))) +
  scale_y_continuous(labels = scales::label_comma(), expand = expansion(mult = c(0, 0.04))) +
  labs(x = "Publication year", y = "Number of records", fill = "Species") +
  theme_classic(base_size = 11) +
  theme(legend.position = "right", legend.title = element_text(face = "bold"), axis.title = element_text(face = "bold"), axis.text = element_text(colour = "black"), panel.grid = element_blank())

ggsave(file.path(out_dir, "figure_01_records_by_publication_year.pdf"), p, width = 190, height = 120, units = "mm", device = cairo_pdf)
ggsave(file.path(out_dir, "figure_01_records_by_publication_year.png"), p, width = 190, height = 120, units = "mm", dpi = 600)
message("Figure 1 written to: ", out_dir)
