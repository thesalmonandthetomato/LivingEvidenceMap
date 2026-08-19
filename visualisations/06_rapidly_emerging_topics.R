#!/usr/bin/env Rscript

# Figure 6: Rapidly emerging topics relative to background evidence-base growth.
# The 12 candidate emerging themes are retained. Each topic is shown as a
# proportional growth trajectory, while the dashed grey line shows the fitted
# proportional growth of the complete evidence base, indexed to 100 at the
# topic's first observed year.

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

master <- readr::read_csv(master_path, show_col_types = FALSE, progress = FALSE)
required_master <- c("topic_hierarchy_paths", "year")
missing_master <- setdiff(required_master, names(master))
if (length(missing_master) > 0) stop("Required columns missing from master: ", paste(missing_master, collapse = ", "))

# Parse topic paths using the same semicolon-separated hierarchy representation
# used by the other visualisations.
raw_paths <- master %>%
  transmute(record_id = row_number(), publication_year = suppressWarnings(as.integer(year)), raw_path = as.character(topic_hierarchy_paths)) %>%
  filter(!is.na(publication_year), !is.na(raw_path), str_trim(raw_path) != "") %>%
  mutate(path = str_split(raw_path, "\\s*;\\s*")) %>%
  unnest(path) %>%
  mutate(path = str_squish(path)) %>%
  filter(path != "") %>%
  distinct(record_id, publication_year, path) %>%
  mutate(
    taxonomy = str_to_lower(str_squish(path)),
    taxonomy = str_replace_all(taxonomy, "[[:punct:]]+", " "),
    taxonomy = str_squish(taxonomy)
  )

# Keep the 12 themes agreed from the database analysis. Plastics and solid
# waste is retained as a newly emerging theme even though it lacks a usable
# pre-2015 rate comparison.
rapid_rules <- tibble::tribble(
  ~topic, ~pattern,
  "Monitoring and sampling methods", "monitoring|sampling|surveillance|assessment methods",
  "Automation and precision aquaculture", "automation|precision aquaculture|precision farming|robotic|robotics",
  "Smoltification and smolt quality", "smoltification|smolt quality|smolt development|smolt performance",
  "Novel feed resources", "novel feed|alternative feed|alternative ingredient|novel ingredient|insect|algae|single cell|microbial protein|plant based feed",
  "Welfare assessment and risks", "welfare assessment|welfare risk|welfare risks|welfare consequence|welfare indicator",
  "Climate change", "climate change|climate warming|global warming|climate adaptation|climate mitigation",
  "Sensors, imaging and measurement", "sensor|imaging|machine vision|computer vision|image analysis|measurement technology",
  "Statistical and modelling methods", "statistical model|modelling|modeling|simulation|forecasting|predictive model|mathematical model",
  "Antimicrobial resistance and One Health", "antimicrobial resistance|antibiotic resistance|one health|antimicrobial stewardship",
  "Energy, greenhouse gases and life-cycle footprint", "greenhouse gas|ghg|carbon footprint|life cycle|life-cycle|energy use|energy consumption|carbon emission",
  "By-products and waste as inputs", "by-product|waste as input|waste valorisation|waste valorization|circular|nutrient recovery|resource recovery",
  "Plastics and solid waste", "plastic|microplastic|solid waste|plastic waste|packaging waste"
)
topic_order <- rapid_rules$topic

topic_matches <- tidyr::crossing(raw_paths %>% distinct(record_id, publication_year, path, taxonomy), rapid_rules) %>%
  filter(str_detect(taxonomy, regex(pattern, ignore_case = TRUE))) %>%
  distinct(record_id, publication_year, topic, path)

write_csv(topic_matches %>% count(topic, path, sort = TRUE), file.path(out_dir, "figure_06_rapidly_emerging_topics_taxonomy_mapping.csv"))
match_counts <- topic_matches %>% count(topic, name = "matched_records")
missing_topics <- setdiff(topic_order, match_counts$topic)
if (length(missing_topics) > 0) stop("No database records matched: ", paste(missing_topics, collapse = ", "))

background <- master %>%
  transmute(record_id = row_number(), publication_year = suppressWarnings(as.integer(year))) %>%
  filter(!is.na(publication_year)) %>%
  distinct(record_id, publication_year) %>%
  count(publication_year, name = "background_records")

all_years <- seq(min(background$publication_year), max(background$publication_year), by = 1)
background <- tibble(publication_year = all_years) %>%
  left_join(background, by = "publication_year") %>%
  mutate(background_records = replace_na(background_records, 0L))

topic_counts <- topic_matches %>% count(topic, publication_year, name = "topic_records")
plot_data <- tidyr::expand_grid(topic = topic_order, publication_year = all_years) %>%
  left_join(topic_counts, by = c("topic", "publication_year")) %>%
  mutate(topic_records = replace_na(topic_records, 0L)) %>%
  left_join(background, by = "publication_year")

# Fit log-linear growth rates. Zeros are excluded from the regression because
# log(0) is undefined. This is appropriate for the 11 established themes.
fit_growth <- function(df, value_col) {
  y <- df[[value_col]]
  keep <- is.finite(y) & y > 0 & is.finite(df$publication_year)
  d <- df[keep, c("publication_year", value_col), drop = FALSE]
  if (nrow(d) < 3 || length(unique(d$publication_year)) < 3) {
    return(list(slope = NA_real_, annual_growth = NA_real_, fit = NULL))
  }
  d$log_y <- log(d[[value_col]])
  fit <- stats::lm(log_y ~ publication_year, data = d)
  slope <- unname(stats::coef(fit)[["publication_year"]])
  list(slope = slope, annual_growth = 100 * (exp(slope) - 1), fit = fit)
}

background_fit <- fit_growth(background, "background_records")
if (is.null(background_fit$fit)) stop("Could not fit background growth trend.")

background_pred <- background %>%
  mutate(background_trend_raw = exp(as.numeric(stats::predict(
    background_fit$fit,
    newdata = data.frame(publication_year = publication_year)
  )))
  )

# Fit each topic independently. Plastics is a special case: it is a genuinely
# new theme with no pre-2015 observations, so no defensible historical growth
# rate exists. It is plotted from its first observed year using the observed
# proportional trajectory, with the background trend shown for comparison.
topic_fit_list <- lapply(topic_order, function(tp) {
  d <- plot_data[plot_data$topic == tp & plot_data$topic_records > 0, c("publication_year", "topic_records")]
  first_year <- min(d$publication_year)
  fit_info <- fit_growth(d, "topic_records")

  if (!is.null(fit_info$fit)) {
    pred <- exp(as.numeric(stats::predict(
      fit_info$fit,
      newdata = data.frame(publication_year = all_years)
    )))
    fit_type <- "log-linear fitted trend"
    annual_growth <- fit_info$annual_growth
  } else {
    pred <- rep(NA_real_, length(all_years))
    fit_type <- "new theme; insufficient history for fitted rate"
    annual_growth <- NA_real_
  }

  tibble(
    topic = tp,
    publication_year = all_years,
    topic_trend_raw = pred,
    topic_annual_growth_percent = annual_growth,
    topic_first_year = first_year,
    fit_type = fit_type
  )
})
topic_trends <- bind_rows(topic_fit_list)

# For the 11 established themes, compare fitted proportional growth rates.
# For plastics, use the observed proportional series rather than inventing a
# growth rate from a zero baseline.
plot_data <- plot_data %>%
  left_join(background_pred %>% select(publication_year, background_trend_raw), by = "publication_year") %>%
  left_join(topic_trends, by = c("topic", "publication_year")) %>%
  group_by(topic) %>%
  arrange(publication_year, .by_group = TRUE) %>%
  mutate(
    first_year = first(topic_first_year),
    background_anchor = background_trend_raw[publication_year == first_year][1],
    background_growth_index = 100 * background_trend_raw / background_anchor,
    topic_first_observed = if_else(publication_year == first_year, topic_records, NA_integer_),
    topic_growth_index_observed = if_else(!is.na(topic_first_observed) & topic_first_observed > 0,
                                          100,
                                          NA_real_),
    topic_growth_index = if_else(
      topic == "Plastics and solid waste",
      if_else(topic_records > 0, 100 * topic_records / first(topic_records[topic_records > 0]), NA_real_),
      100 * topic_trend_raw / topic_trend_raw[publication_year == first_year][1]
    )
  ) %>%
  ungroup()

# Summary table explicitly identifies whether fitted topic growth exceeds the
# background growth rate. Plastics is marked as 'new theme' rather than forced
# into an invalid rate comparison.
summary_data <- topic_trends %>%
  distinct(topic, topic_annual_growth_percent, fit_type) %>%
  mutate(
    background_annual_growth_percent = background_fit$annual_growth,
    excess_annual_growth_percentage_points = topic_annual_growth_percent - background_annual_growth_percent,
    relative_annual_growth_ratio = (1 + topic_annual_growth_percent / 100) /
      (1 + background_annual_growth_percent / 100),
    classification = case_when(
      topic == "Plastics and solid waste" ~ "New theme; no pre-2015 rate",
      topic_annual_growth_percent > background_annual_growth_percent ~ "Faster than background",
      TRUE ~ "Not faster than background"
    )
  ) %>%
  arrange(desc(relative_annual_growth_ratio))

write_csv(plot_data %>% arrange(topic, publication_year), file.path(out_dir, "figure_06_rapidly_emerging_topics_data.csv"))
write_csv(summary_data, file.path(out_dir, "figure_06_rapidly_emerging_topics_summary.csv"))

# Plot proportional growth. The dashed grey line is the fitted background
# evidence-base growth rate, indexed to 100 at the first year in which each
# topic appears. The red line is the topic trajectory. Thus, the visual gap
# between red and grey directly represents above/below-background growth.
p <- ggplot(plot_data, aes(x = publication_year)) +
  geom_hline(yintercept = 100, colour = "#D9DEDF", linewidth = 0.35) +
  geom_line(aes(y = background_growth_index), colour = "#8E989B", linewidth = 0.8, linetype = "dashed") +
  geom_line(aes(y = topic_growth_index), colour = "#E55634", linewidth = 0.95, na.rm = TRUE) +
  geom_point(aes(y = topic_growth_index), colour = "#E55634", size = 0.9, na.rm = TRUE) +
  facet_wrap(~ factor(topic, levels = topic_order), ncol = 3, scales = "free_y") +
  scale_x_continuous(breaks = scales::breaks_pretty(n = 7), expand = expansion(mult = c(0.01, 0.02))) +
  scale_y_continuous(labels = function(x) paste0(comma(x), "%"), expand = expansion(mult = c(0, 0.10))) +
  labs(
    title = "Rapidly emerging topics in the evidence base",
    subtitle = paste0(
      "Proportional growth relative to the background evidence base; background annual growth = ",
      number(background_fit$annual_growth, accuracy = 0.1), "%"
    ),
    x = "Publication year",
    y = "Growth index (first observed year = 100)",
    caption = "Red = topic growth; dashed grey = fitted background database growth. Red above grey indicates growth faster than the background. Plastics and solid waste is shown as a new theme because no pre-2015 baseline exists."
  ) +
  theme_minimal(base_size = 10.5) +
  theme(
    panel.grid.major.y = element_line(colour = "#E5E8E9", linewidth = 0.3),
    panel.grid.minor = element_blank(),
    panel.grid.major.x = element_blank(),
    strip.background = element_rect(fill = "#EEF2F2", colour = NA),
    strip.text = element_text(face = "bold", colour = "#29434A", size = 9.2),
    axis.title = element_text(face = "bold", colour = "#45616A"),
    axis.text = element_text(colour = "#29434A", size = 8.2),
    plot.title = element_text(face = "bold", size = 17, colour = "#29434A"),
    plot.subtitle = element_text(colour = "#45616A", size = 10.5),
    plot.caption = element_text(colour = "#5B6D72", size = 8.2, hjust = 0),
    panel.spacing = grid::unit(1.1, "lines"),
    plot.background = element_rect(fill = "white", colour = NA),
    panel.background = element_rect(fill = "white", colour = NA),
    plot.margin = margin(12, 16, 12, 12)
  )

ggsave(file.path(out_dir, "figure_06_rapidly_emerging_topics.pdf"), p, width = 190, height = 235, units = "mm", device = cairo_pdf)
ggsave(file.path(out_dir, "figure_06_rapidly_emerging_topics.png"), p, width = 190, height = 235, units = "mm", dpi = 600)
message("Figure 6 written to: ", out_dir)
