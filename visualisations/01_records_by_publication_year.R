#!/usr/bin/env Rscript

# Figure 1: Number of included canonical records by publication year, stacked by species.
# Source: Workflow 08 included-only canonical JSONL.

required <- c("dplyr", "ggplot2", "tidyr", "scales", "here", "jsonlite")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) stop("Install required packages: ", paste(missing, collapse = ", "))

library(dplyr); library(ggplot2); library(tidyr); library(scales); library(here)
source(here::here("visualisations", "canonical_figure_data.R"))

out_dir <- here::here("visualisations")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

canonical_species <- c("Atlantic salmon", "Chinook salmon", "Chum salmon", "Coho salmon", "Masu salmon", "Pink salmon", "Sockeye salmon", "Rainbow trout", "Unspecified species")
normalise_species <- function(x) {
  x <- trimws(x); x_lower <- tolower(x)
  dplyr::case_when(
    x_lower == "atlantic salmon" ~ "Atlantic salmon",
    x_lower == "chinook salmon" ~ "Chinook salmon",
    x_lower == "chum salmon" ~ "Chum salmon",
    x_lower == "coho salmon" ~ "Coho salmon",
    x_lower == "masu salmon" ~ "Masu salmon",
    x_lower == "pink salmon" ~ "Pink salmon",
    x_lower == "sockeye salmon" ~ "Sockeye salmon",
    x_lower %in% c("rainbow salmon", "rainbow trout", "steelhead", "steelhead trout") ~ "Rainbow trout",
    x_lower %in% c("unspecified species", "unspecified farmed salmon", "unspecified salmon", "farmed salmon", "") ~ "Unspecified species",
    TRUE ~ x
  )
}

master <- load_figure_master()
plot_data <- master %>%
  transmute(record_id, publication_year = year, species = final_species) %>%
  filter(!is.na(publication_year), publication_year <= 2025L) %>%
  separate_rows(species, sep = ";") %>%
  mutate(species = normalise_species(species), species = if_else(is.na(species) | species == "", "Unspecified species", species)) %>%
  distinct(record_id, species, .keep_all = TRUE)

unexpected_species <- setdiff(unique(plot_data$species), canonical_species)
if (length(unexpected_species) > 0L) stop("Unexpected species categories after normalisation: ", paste(sort(unexpected_species), collapse = ", "))

plot_data <- plot_data %>% count(publication_year, species, name = "records") %>% mutate(species = factor(species, levels = canonical_species))
pacific_values <- grDevices::colorRampPalette(c("#2c454a", "#577c84", "#a8bdbe"))(7L)
fill_values <- c("Atlantic salmon" = "#e55634", setNames(pacific_values, canonical_species[2:8]), "Unspecified species" = "#e2b8a2")

p <- ggplot(plot_data, aes(x = publication_year, y = records, fill = species)) +
  geom_col(width = 0.85, colour = "white", linewidth = 0.15) +
  scale_fill_manual(values = fill_values, drop = FALSE) +
  scale_x_continuous(breaks = scales::breaks_pretty(n = 12), expand = expansion(mult = c(0.005, 0.02))) +
  scale_y_continuous(labels = scales::label_comma(), expand = expansion(mult = c(0, 0.04))) +
  labs(x = "Publication year", y = "Number of included records", fill = "Species") +
  theme_classic(base_size = 11) +
  theme(legend.position = "right", legend.title = element_text(face = "bold"), axis.title = element_text(face = "bold"), axis.text = element_text(colour = "black"), panel.grid = element_blank())

ggsave(file.path(out_dir, "figure_01_records_by_publication_year.pdf"), p, width = 190, height = 120, units = "mm", device = cairo_pdf)
ggsave(file.path(out_dir, "figure_01_records_by_publication_year.png"), p, width = 190, height = 120, units = "mm", dpi = 600)
readr::write_csv(plot_data %>% mutate(species = as.character(species)), file.path(out_dir, "figure_01_records_by_publication_year_data.csv"))
message("Figure 1 written to: ", out_dir)
