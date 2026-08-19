#!/usr/bin/env Rscript

# Figure 5: Number of records by publication year, stacked by high-level topic.
# High-level topic is the first level of the canonical topic_hierarchy_paths
# taxonomy. Records are expanded to one record-high-level-topic observation
# before counting; multiple assignments to the same high-level topic within a
# record are counted only once.
# Source: corrected master evidence-map database.

required <- c("dplyr", "ggplot2", "readr", "tidyr", "stringr", "scales", "here")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) stop("Install required packages: ", paste(missing, collapse = ", "))

library(dplyr)
library(ggplot2)
library(readr)
library(tidyr)
library(stringr)
library(scales)
library(here)

master_path <- here::here("data", "master", "current", "living_evidence_map_master CORRECTED.csv")
out_dir <- here::here("visualisations")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# Seven distinct, medium-to-dark blue-grey shades for improved readability.
topic_order <- c(
  "Production",
  "Environment",
  "Methods",
  "Industry and governance",
  "Product",
  "People and society",
  "Inputs and resources"
)

topic_fill_values <- c(
  "Production" = "#233F47",
  "Environment" = "#2F5963",
  "Methods" = "#3E6B75",
  "Industry and governance" = "#4F7C86",
  "Product" = "#638D96",
  "People and society" = "#769DA5",
  "Inputs and resources" = "#89ADB3"
)

master <- readr::read_csv(master_path, show_col_types = FALSE, progress = FALSE)
required_master <- c("year", "topic_hierarchy_paths")
missing_master <- setdiff(required_master, names(master))
if (length(missing_master) > 0) {
  stop("Required columns missing from master: ", paste(missing_master, collapse = ", "))
}

# Extract the Level 1 (high-level) topic from each canonical topic path.
# A record can have multiple topic paths, but is counted at most once within
# each high-level topic.
plot_data <- master %>%
  transmute(
    record_id = row_number(),
    publication_year = suppressWarnings(as.integer(year)),
    raw_paths = as.character(topic_hierarchy_paths)
  ) %>%
  filter(!is.na(publication_year), !is.na(raw_paths), str_trim(raw_paths) != "") %>%
  mutate(path = str_split(raw_paths, "\\s*;\\s*")) %>%
  unnest(path) %>%
  mutate(path = str_squish(path)) %>%
  filter(path != "") %>%
  mutate(
    high_level_topic = str_squish(str_split_fixed(path, "\\s*>\\s*", 2)[, 1])
  ) %>%
  filter(high_level_topic != "") %>%
  distinct(record_id, publication_year, high_level_topic)

unexpected_topics <- setdiff(unique(plot_data$high_level_topic), topic_order)
if (length(unexpected_topics) > 0L) {
  stop(
    "Unexpected high-level topic categories: ",
    paste(sort(unexpected_topics), collapse = ", ")
  )
}

plot_data <- plot_data %>%
  count(publication_year, high_level_topic, name = "records") %>%
  mutate(high_level_topic = factor(high_level_topic, levels = topic_order))

# Publication-year range is determined directly from the data.
year_breaks <- scales::breaks_pretty(n = 12)(range(plot_data$publication_year, na.rm = TRUE))

p <- ggplot(
  plot_data,
  aes(x = publication_year, y = records, fill = high_level_topic)
) +
  geom_col(width = 0.85, colour = "white", linewidth = 0.15) +
  scale_fill_manual(
    values = topic_fill_values,
    breaks = topic_order,
    drop = FALSE,
    name = "High-level topic"
  ) +
  scale_x_continuous(
    breaks = year_breaks,
    expand = expansion(mult = c(0.005, 0.02))
  ) +
  scale_y_continuous(
    labels = scales::label_comma(),
    expand = expansion(mult = c(0, 0.04))
  ) +
  labs(
    title = "Number of records by publication year, stacked by high-level topic",
    x = "Publication year",
    y = "Number of records"
  ) +
  theme_classic(base_size = 11) +
  theme(
    legend.position = "right",
    legend.title = element_text(face = "bold", colour = "#29434A"),
    legend.text = element_text(colour = "#29434A"),
    axis.title = element_text(face = "bold", colour = "#45616A"),
    axis.text = element_text(colour = "#29434A"),
    plot.title = element_text(face = "bold", size = 16, colour = "#29434A"),
    panel.grid = element_blank(),
    plot.background = element_rect(fill = "white", colour = NA),
    panel.background = element_rect(fill = "white", colour = NA)
  )

ggsave(
  file.path(out_dir, "figure_05_records_by_publication_year_high_level_topic.pdf"),
  p,
  width = 190,
  height = 120,
  units = "mm",
  device = cairo_pdf
)

ggsave(
  file.path(out_dir, "figure_05_records_by_publication_year_high_level_topic.png"),
  p,
  width = 190,
  height = 120,
  units = "mm",
  dpi = 600
)

# Save the plotting data so the figure can be checked/reproduced independently.
write_csv(
  plot_data %>% mutate(high_level_topic = as.character(high_level_topic)),
  file.path(out_dir, "figure_05_records_by_publication_year_high_level_topic_data.csv")
)

message("Figure 5 written to: ", out_dir)
