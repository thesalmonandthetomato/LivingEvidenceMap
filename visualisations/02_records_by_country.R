#!/usr/bin/env Rscript

# Figure 2: Number of included canonical records by study country, stacked by species.
# Source: Workflow 08 included-only canonical JSONL.

required <- c("dplyr", "ggplot2", "readr", "tidyr", "scales", "here", "jsonlite")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) stop("Install required packages: ", paste(missing, collapse = ", "))

library(dplyr); library(ggplot2); library(readr); library(tidyr); library(scales); library(here)
source(here::here("visualisations", "canonical_figure_data.R"))

out_dir <- here::here("visualisations")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
gazetteer_path <- here::here("config", "global_country_gazetteer_v3.csv")

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
gazetteer <- readr::read_csv(gazetteer_path, show_col_types = FALSE, progress = FALSE)
country_lookup <- gazetteer %>%
  transmute(iso3c = toupper(trimws(as.character(iso3c))), country_name = trimws(as.character(country_name)), match_type = tolower(trimws(as.character(match_type))), priority = suppressWarnings(as.numeric(priority))) %>%
  filter(!is.na(iso3c), iso3c != "", !is.na(country_name), country_name != "", match_type %in% c("country", "country name")) %>%
  arrange(iso3c, desc(priority), country_name) %>% distinct(iso3c, .keep_all = TRUE) %>% select(iso3c, country_name)

plot_data <- master %>%
  transmute(record_id, iso3c = toupper(trimws(as.character(final_primary_country_iso3c))), species = final_species) %>%
  filter(!is.na(iso3c), iso3c != "") %>%
  separate_rows(iso3c, sep = ";") %>%
  separate_rows(species, sep = ";") %>%
  mutate(iso3c = toupper(trimws(iso3c)), species = normalise_species(species), species = if_else(is.na(species) | species == "", "Unspecified species", species)) %>%
  filter(iso3c != "", iso3c != "NONE") %>%
  distinct(record_id, iso3c, species) %>%
  left_join(country_lookup, by = "iso3c") %>%
  mutate(country_name = if_else(is.na(country_name) | country_name == "", iso3c, country_name))

unexpected_species <- setdiff(unique(plot_data$species), canonical_species)
if (length(unexpected_species) > 0L) stop("Unexpected species categories after normalisation: ", paste(sort(unexpected_species), collapse = ", "))

top_countries <- plot_data %>% distinct(record_id, iso3c, country_name) %>% count(iso3c, country_name, name = "records", sort = TRUE) %>% slice_head(n = 20)
plot_data <- plot_data %>% semi_join(top_countries, by = c("iso3c", "country_name")) %>% count(country_name, species, name = "records")
country_levels <- top_countries %>% arrange(records, country_name) %>% pull(country_name)
plot_data <- plot_data %>% mutate(country_name = factor(country_name, levels = country_levels), species = factor(species, levels = canonical_species))

pacific_values <- grDevices::colorRampPalette(c("#2c454a", "#577c84", "#a8bdbe"))(7L)
fill_values <- c("Atlantic salmon" = "#e55634", setNames(pacific_values, canonical_species[2:8]), "Unspecified species" = "#e2b8a2")

p <- ggplot(plot_data, aes(x = country_name, y = records, fill = species)) +
  geom_col(width = 0.78, colour = "white", linewidth = 0.15) + coord_flip() +
  scale_fill_manual(values = fill_values, drop = FALSE) +
  scale_y_continuous(labels = scales::label_comma(), expand = expansion(mult = c(0, 0.04))) +
  labs(x = NULL, y = "Number of included records", fill = "Species") +
  theme_classic(base_size = 11) +
  theme(legend.position = "right", legend.title = element_text(face = "bold"), axis.title = element_text(face = "bold"), axis.text = element_text(colour = "black"), panel.grid = element_blank())

ggsave(file.path(out_dir, "figure_02_records_by_country.pdf"), p, width = 190, height = 135, units = "mm", device = cairo_pdf)
ggsave(file.path(out_dir, "figure_02_records_by_country.png"), p, width = 190, height = 135, units = "mm", dpi = 600)
readr::write_csv(plot_data %>% mutate(country_name = as.character(country_name), species = as.character(species)), file.path(out_dir, "figure_02_records_by_country_data.csv"))
message("Figure 2 written to: ", out_dir)
