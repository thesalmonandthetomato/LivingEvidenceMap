#!/usr/bin/env Rscript

# Annotated version of Figure 6: rapidly emerging topics relative to
# background evidence-base growth. Adds n = X labels at the final observed
# point of each topic and reserves explicit x-axis space inside every facet.

required <- c("dplyr", "ggplot2", "readr", "tidyr", "stringr", "scales")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) stop("Install required packages: ", paste(missing, collapse = ", "))

library(dplyr)
library(ggplot2)
library(readr)
library(tidyr)
library(stringr)
library(scales)

master_path <- file.path("data", "master", "current", "living_evidence_map_master CORRECTED.csv")
out_dir <- "visualisations"
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
if (!file.exists(master_path)) stop("Master database not found at: ", master_path)

master <- read_csv(master_path, show_col_types = FALSE, progress = FALSE)
required_master <- c("record_id", "topic_hierarchy_paths", "year")
missing_master <- setdiff(required_master, names(master))
if (length(missing_master) > 0) stop("Required columns missing from master: ", paste(missing_master, collapse = ", "))
master <- master %>%
  transmute(record_id = as.character(record_id), publication_year = suppressWarnings(as.integer(year)), topic_hierarchy_paths = as.character(topic_hierarchy_paths)) %>%
  filter(!is.na(publication_year))

rapid_topics <- tibble::tribble(
  ~topic, ~canonical_path,
  "Monitoring and sampling methods", "Methods > Methodological research > Monitoring and sampling methods",
  "Automation and precision aquaculture", "Production > Production systems and technology > Automation and precision aquaculture",
  "Smoltification and smolt quality", "Production > Early life and transfer > Smoltification and smolt quality",
  "Novel feed resources", "Inputs and resources > Feed-resource supply > Novel feed resources",
  "Welfare assessment and risks", "Production > Fish welfare > Welfare assessment",
  "Welfare assessment and risks", "Production > Fish welfare > Welfare risks and consequences",
  "Climate change", "Environment > Environmental stressors > Climate change",
  "Climate change", "Environment > Climate change > Adaptation and mitigation",
  "Sensors, imaging and measurement", "Methods > Methodological research > Sensors, imaging and measurement methods",
  "Statistical and modelling methods", "Methods > Methodological research > Statistical and modelling methods",
  "Antimicrobial resistance and One Health", "People and society > Public health > Antimicrobial resistance and One Health",
  "Energy, greenhouse gases and life-cycle footprint", "Environment > Resource use and footprint > Energy, greenhouse gases and life-cycle footprint",
  "By-products and waste as inputs", "Inputs and resources > Circularity > By-products and waste as inputs",
  "Plastics and solid waste", "Environment > Waste and emissions > Plastics and solid waste"
) %>% distinct()

topic_order <- c(
  "Monitoring and sampling methods", "Automation and precision aquaculture", "Smoltification and smolt quality",
  "Novel feed resources", "Welfare assessment and risks", "Climate change",
  "Sensors, imaging and measurement", "Statistical and modelling methods", "Antimicrobial resistance and One Health",
  "Energy, greenhouse gases and life-cycle footprint", "By-products and waste as inputs", "Plastics and solid waste"
)

topic_labels <- c(
  "Monitoring and sampling methods" = "Monitoring and\nsampling methods",
  "Automation and precision aquaculture" = "Automation and\nprecision aquaculture",
  "Smoltification and smolt quality" = "Smoltification and\nsmolt quality",
  "Novel feed resources" = "Novel feed\nresources",
  "Welfare assessment and risks" = "Welfare assessment\nand risks",
  "Climate change" = "Climate change",
  "Sensors, imaging and measurement" = "Sensors, imaging\nand measurement",
  "Statistical and modelling methods" = "Statistical and\nmodelling methods",
  "Antimicrobial resistance and One Health" = "Antimicrobial resistance\nand One Health",
  "Energy, greenhouse gases and life-cycle footprint" = "Energy, greenhouse gases\nand life-cycle footprint",
  "By-products and waste as inputs" = "By-products and waste\nas inputs",
  "Plastics and solid waste" = "Plastics and solid waste"
)

expanded <- master %>%
  mutate(path = str_split(topic_hierarchy_paths, "\\s*;\\s*")) %>%
  unnest(path) %>%
  mutate(path = str_squish(path)) %>%
  filter(path != "") %>%
  distinct(record_id, publication_year, path)

topic_matches <- expanded %>%
  inner_join(rapid_topics, by = c("path" = "canonical_path")) %>%
  distinct(record_id, publication_year, topic, path)

match_counts <- topic_matches %>% distinct(topic, record_id) %>% count(topic, name = "matched_records")
missing_topics <- setdiff(topic_order, match_counts$topic)
if (length(missing_topics) > 0) stop("No database records matched: ", paste(missing_topics, collapse = ", "))

background <- master %>%
  distinct(record_id, publication_year) %>%
  count(publication_year, name = "background_records")

all_years <- seq(min(background$publication_year), max(background$publication_year), by = 1)
background <- tibble(publication_year = all_years) %>%
  left_join(background, by = "publication_year") %>%
  mutate(background_records = replace_na(background_records, 0L))

topic_counts <- topic_matches %>%
  distinct(topic, record_id, publication_year) %>%
  count(topic, publication_year, name = "topic_records")

plot_data <- tidyr::expand_grid(topic = topic_order, publication_year = all_years) %>%
  left_join(topic_counts, by = c("topic", "publication_year")) %>%
  mutate(topic_records = replace_na(topic_records, 0L)) %>%
  left_join(background, by = "publication_year")

background_baseline <- background %>%
  filter(publication_year >= 2010, publication_year <= 2014) %>%
  summarise(x = mean(background_records)) %>% pull(x)
background_recent <- background %>%
  filter(publication_year >= 2021, publication_year <= 2025) %>%
  summarise(x = mean(background_records)) %>% pull(x)
if (is.na(background_baseline) || background_baseline <= 0) stop("Could not calculate the 2010-2014 background baseline.")
background_growth_ratio <- background_recent / background_baseline

background_fit_data <- background %>%
  filter(publication_year >= 2010, background_records > 0) %>%
  mutate(log_records = log(background_records))
background_fit <- lm(log_records ~ publication_year, data = background_fit_data)
background_fit_raw <- tibble(
  publication_year = all_years,
  background_trend_raw = exp(as.numeric(predict(background_fit, newdata = data.frame(publication_year = all_years))))
)
background_fit_baseline <- mean(background_fit_raw$background_trend_raw[background_fit_raw$publication_year >= 2010 & background_fit_raw$publication_year <= 2014])

plot_data <- plot_data %>%
  left_join(background_fit_raw, by = "publication_year") %>%
  mutate(background_growth_index = 100 * background_trend_raw / background_fit_baseline)

topic_baselines <- plot_data %>%
  group_by(topic) %>%
  summarise(
    baseline_2010_2014 = mean(topic_records[publication_year >= 2010 & publication_year <= 2014]),
    first_observed_year = min(publication_year[topic_records > 0]),
    first_observed_count = topic_records[publication_year == first_observed_year][1],
    .groups = "drop"
  )

plot_data <- plot_data %>%
  left_join(topic_baselines, by = "topic") %>%
  mutate(
    topic_growth_index = case_when(
      topic == "Plastics and solid waste" ~ if_else(publication_year >= first_observed_year & topic_records > 0, 100 * topic_records / first_observed_count, NA_real_),
      baseline_2010_2014 > 0 ~ 100 * topic_records / baseline_2010_2014,
      TRUE ~ NA_real_
    )
  )

plot_data <- plot_data %>%
  mutate(topic_plot = factor(topic, levels = topic_order, labels = unname(topic_labels[topic_order])))

# One annotation per facet: use the final observed year for that topic and
# the exact number of tagged records in that year. The annotation is placed
# at a fixed fraction of the reserved right-hand margin, not beyond the panel.
final_points <- plot_data %>%
  filter(topic_records > 0) %>%
  group_by(topic) %>%
  filter(publication_year == max(publication_year)) %>%
  ungroup() %>%
  transmute(
    topic_plot = factor(topic, levels = topic_order, labels = unname(topic_labels[topic_order])),
    publication_year,
    topic_growth_index,
    topic_records,
    annotation_label = paste0("n = ", comma(topic_records)),
    annotation_x = publication_year + 0.55
  )

# Reserve a full 2-year right-hand margin in every facet. This is deliberately
# larger than the annotation offset so the text remains inside the panel.
x_min_plot <- 2010
x_max_plot <- max(all_years) + 2

p <- ggplot(plot_data, aes(x = publication_year)) +
  geom_hline(yintercept = 100, colour = "#D9DEDF", linewidth = 0.35) +
  geom_line(aes(y = background_growth_index), colour = "#8E989B", linewidth = 0.85, linetype = "dashed") +
  geom_line(aes(y = topic_growth_index), colour = "#E55634", linewidth = 0.95, na.rm = TRUE) +
  geom_point(aes(y = topic_growth_index), colour = "#E55634", size = 0.85, na.rm = TRUE) +
  geom_label(
    data = final_points,
    aes(x = annotation_x, y = topic_growth_index, label = annotation_label),
    inherit.aes = FALSE,
    hjust = 0,
    vjust = 0.5,
    size = 2.7,
    fontface = "bold",
    colour = "#29434A",
    fill = "white",
    label.size = 0.15,
    label.padding = grid::unit(0.12, "lines"),
    show.legend = FALSE
  ) +
  facet_wrap(~ topic_plot, ncol = 3, scales = "free_y") +
  scale_x_continuous(
    limits = c(x_min_plot, x_max_plot),
    breaks = c(2010, 2015, 2020, 2025),
    labels = c("2010", "2015", "2020", "2025"),
    expand = expansion(mult = c(0, 0))
  ) +
  scale_y_continuous(labels = comma_format(accuracy = 1), expand = expansion(mult = c(0, 0.10))) +
  labs(
    title = "Rapidly emerging topics in the evidence base",
    subtitle = paste0(
      "Growth indexed to 2010–2014; dashed grey = fitted background database growth (",
      number(background_growth_ratio, accuracy = 0.01), "× by 2021–2025)"
    ),
    x = "Publication year",
    y = "Growth index (2010–2014 mean = 100)",
    caption = "Red = topic output; dashed grey = background evidence-base trend. Red above grey indicates faster-than-background growth. Labels show the number of records tagged with each topic in its final observed year. Plastics and solid waste is indexed to its first observed year because it has no 2010–2014 records."
  ) +
  theme_minimal(base_size = 10.5) +
  theme(
    panel.grid.major.y = element_line(colour = "#E5E8E9", linewidth = 0.3),
    panel.grid.minor = element_blank(),
    panel.grid.major.x = element_blank(),
    strip.background = element_rect(fill = "#EEF2F2", colour = NA),
    strip.text = element_text(face = "bold", colour = "#29434A", size = 8.0, lineheight = 0.9, hjust = 0.5),
    strip.placement = "inside",
    strip.clip = "on",
    axis.title = element_text(face = "bold", colour = "#45616A"),
    axis.text = element_text(colour = "#29434A", size = 8.2),
    axis.text.x = element_text(angle = 45, hjust = 1, vjust = 1, size = 8),
    plot.title = element_text(face = "bold", size = 17, colour = "#29434A"),
    plot.subtitle = element_text(colour = "#45616A", size = 10.5),
    plot.caption = element_text(colour = "#5B6D72", size = 8.2, hjust = 0),
    panel.spacing = grid::unit(1.25, "lines"),
    plot.background = element_rect(fill = "white", colour = NA),
    panel.background = element_rect(fill = "white", colour = NA),
    plot.margin = margin(16, 20, 18, 16)
  )

ggsave(file.path(out_dir, "figure_06_rapidly_emerging_topics_annotated.pdf"), p, width = 190, height = 235, units = "mm", device = cairo_pdf)
ggsave(file.path(out_dir, "figure_06_rapidly_emerging_topics_annotated.png"), p, width = 190, height = 235, units = "mm", dpi = 600)
message("Annotated Figure 6 written to: ", out_dir)
