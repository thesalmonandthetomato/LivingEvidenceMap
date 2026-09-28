#!/usr/bin/env Rscript

# Figure 5: Number of included canonical records by publication year, stacked by high-level topic.
# Source: Workflow 08 included-only canonical JSONL.

required <- c("dplyr", "ggplot2", "readr", "tidyr", "stringr", "scales", "here", "jsonlite")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) stop("Install required packages: ", paste(missing, collapse = ", "))

library(dplyr); library(ggplot2); library(readr); library(tidyr); library(stringr); library(scales); library(here)
source(here::here("visualisations", "canonical_figure_data.R"))

out_dir <- here::here("visualisations")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
base_palette <- c("#2c454a", "#577c84", "#a8bdbe", "#e2b8a2", "#ff9d78", "#e55634")
topic_order <- c("Production", "Environment", "Methods", "Industry and governance", "Product", "People and society", "Inputs and resources")
topic_fill_values <- c(
  "Production" = "#2c454a",
  "Environment" = "#577c84",
  "Methods" = "#a8bdbe",
  "Industry and governance" = "#bfb5aa",
  "Product" = "#e2b8a2",
  "People and society" = "#ff9d78",
  "Inputs and resources" = "#e55634"
)

# APPROVED / LOCKED manuscript design for Workflow 09 on 2026-09-28:
# wide aspect ratio, no internal title, and horizontal reference grid only.

master <- load_figure_master()
plot_data <- master %>%
  transmute(record_id, publication_year = year, raw_paths = as.character(topic_hierarchy_paths)) %>%
  filter(!is.na(publication_year), !is.na(raw_paths), str_trim(raw_paths) != "") %>%
  mutate(path = str_split(raw_paths, "\\s*;\\s*")) %>% unnest(path) %>%
  mutate(path = str_squish(path), high_level_topic = str_squish(str_split_fixed(path, "\\s*>\\s*", 2)[, 1])) %>%
  filter(path != "", high_level_topic != "") %>% distinct(record_id, publication_year, high_level_topic)

unexpected_topics <- setdiff(unique(plot_data$high_level_topic), topic_order)
if (length(unexpected_topics) > 0L) stop("Unexpected high-level topic categories: ", paste(sort(unexpected_topics), collapse = ", "))

plot_data <- plot_data %>% count(publication_year, high_level_topic, name = "records") %>% mutate(high_level_topic = factor(high_level_topic, levels = topic_order))
year_range <- range(plot_data$publication_year, na.rm = TRUE)
year_breaks <- seq(
  floor(year_range[1] / 10) * 10,
  ceiling(year_range[2] / 10) * 10,
  by = 10
)

p <- ggplot(plot_data, aes(x = publication_year, y = records, fill = high_level_topic)) +
  geom_col(width = 0.85, colour = "white", linewidth = 0.15) +
  scale_fill_manual(values = topic_fill_values, breaks = topic_order, drop = FALSE, name = "High-level topic") +
  scale_x_continuous(breaks = year_breaks, expand = expansion(mult = c(0, 0.01))) +
  scale_y_continuous(labels = scales::label_comma(), expand = expansion(mult = c(0, 0.04))) +
  labs(x = "Publication year", y = "Number of included records") +
  theme_minimal(base_size = 11) +
  theme(
    legend.position = "right",
    legend.title = element_text(face = "bold", colour = "#29434A"),
    legend.text = element_text(colour = "#29434A"),
    axis.title = element_text(face = "bold", colour = "#29434A"),
    axis.text = element_text(colour = "#29434A"),
    panel.grid.major.x = element_blank(),
    panel.grid.minor = element_blank(),
    panel.grid.major.y = element_line(colour = "#e5e8e9", linewidth = 0.35),
    plot.background = element_rect(fill = "white", colour = NA),
    panel.background = element_rect(fill = "white", colour = NA)
  )

ggsave(file.path(out_dir, "figure_05_records_by_publication_year_high_level_topic.pdf"), p, width = 260, height = 135, units = "mm", device = cairo_pdf)
ggsave(file.path(out_dir, "figure_05_records_by_publication_year_high_level_topic.png"), p, width = 260, height = 135, units = "mm", dpi = 600)
write_csv(plot_data %>% mutate(high_level_topic = as.character(high_level_topic)), file.path(out_dir, "figure_05_records_by_publication_year_high_level_topic_data.csv"))
message("Figure 5 written to: ", out_dir)
