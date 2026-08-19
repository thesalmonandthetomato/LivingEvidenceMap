#!/usr/bin/env Rscript

# Figure 6: Rapidly emerging topics relative to background evidence-base growth.
# Uses the corrected master database and the repository's canonical topic-path
# representation. Topic clusters are matched by explicit keyword patterns
# against the complete Level 2/Level 3 path, rather than assuming that the
# display labels are exact taxonomy labels.

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

if (!file.exists(master_path)) {
  stop("Master database not found at: ", master_path,
       ". Run this script from the repository root.")
}

master <- readr::read_csv(master_path, show_col_types = FALSE, progress = FALSE)
required_master <- c("topic_hierarchy_paths", "year")
missing_master <- setdiff(required_master, names(master))
if (length(missing_master) > 0) {
  stop("Required columns missing from master: ", paste(missing_master, collapse = ", "))
}

# -------------------------------------------------------------------------
# Canonical topic-path expansion -- identical parsing logic to Figure 04.
# -------------------------------------------------------------------------
raw_paths <- master %>%
  transmute(
    record_id = row_number(),
    publication_year = suppressWarnings(as.integer(year)),
    raw_path = as.character(topic_hierarchy_paths)
  ) %>%
  filter(!is.na(publication_year), !is.na(raw_path), str_trim(raw_path) != "") %>%
  mutate(path = str_split(raw_path, "\\s*;\\s*")) %>%
  unnest(path) %>%
  mutate(path = str_squish(path)) %>%
  filter(path != "") %>%
  distinct(record_id, publication_year, path)

parts <- str_split(raw_paths$path, "\\s*>\\s*")
max_depth <- max(lengths(parts))
for (i in seq_len(max_depth)) {
  raw_paths[[paste0("level", i)]] <- vapply(
    parts,
    function(x) if (length(x) >= i) str_squish(x[i]) else NA_character_,
    character(1)
  )
}

raw_paths <- raw_paths %>%
  mutate(
    taxonomy = str_to_lower(str_squish(path)),
    taxonomy = str_replace_all(taxonomy, "[[:punct:]]+", " "),
    taxonomy = str_squish(taxonomy)
  )

# -------------------------------------------------------------------------
# Rapid-emergence clusters.
#
# These are deliberately defined as transparent keyword rules over the
# canonical taxonomy. This avoids fragile exact-label joins and makes the
# classification auditable in the exported mapping file.
# -------------------------------------------------------------------------
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

# A record can legitimately contribute to several emerging clusters, but is
# counted only once within any one cluster.
topic_matches <- tidyr::crossing(
  raw_paths %>% distinct(record_id, publication_year, path, taxonomy),
  rapid_rules
) %>%
  filter(str_detect(taxonomy, regex(pattern, ignore_case = TRUE))) %>%
  distinct(record_id, publication_year, topic, path)

# Audit trail: exactly which canonical taxonomy paths contributed to each
# emerging cluster.
write_csv(
  topic_matches %>% count(topic, path, sort = TRUE),
  file.path(out_dir, "figure_06_rapidly_emerging_topics_taxonomy_mapping.csv")
)

match_counts <- topic_matches %>% count(topic, name = "matched_records")
missing_topics <- setdiff(topic_order, match_counts$topic)
if (length(missing_topics) > 0) {
  stop(
    "No database records matched these emerging-topic rules: ",
    paste(missing_topics, collapse = ", "),
    ". Inspect figure_06_rapidly_emerging_topics_taxonomy_mapping.csv and update the corresponding keyword rule."
  )
}

# Background = all unique records per publication year.
background <- master %>%
  transmute(
    record_id = row_number(),
    publication_year = suppressWarnings(as.integer(year))
  ) %>%
  filter(!is.na(publication_year)) %>%
  distinct(record_id, publication_year) %>%
  count(publication_year, name = "background_records")

all_years <- seq(min(background$publication_year), max(background$publication_year), by = 1)
background <- tibble(publication_year = all_years) %>%
  left_join(background, by = "publication_year") %>%
  mutate(background_records = replace_na(background_records, 0L))

topic_counts <- topic_matches %>%
  count(topic, publication_year, name = "topic_records")

plot_data <- tidyr::expand_grid(
  topic = topic_order,
  publication_year = all_years
) %>%
  left_join(topic_counts, by = c("topic", "publication_year")) %>%
  mutate(topic_records = replace_na(topic_records, 0L)) %>%
  left_join(background, by = "publication_year")

# -------------------------------------------------------------------------
# Growth-rate comparison.
#
# Rather than forcing a baseline window on sparse emerging topics, fit a
# log-linear trend to annual counts after the first non-zero observation.
# The slope is an estimated proportional annual growth rate. The background
# evidence-base slope is fitted independently and shown as a dashed reference
# trajectory. This is robust to topics that genuinely emerge late in the
# database (e.g. plastics/solid waste).
# -------------------------------------------------------------------------
fit_growth <- function(df, value_col) {
  d <- df %>% filter(.data[[value_col]] > 0, is.finite(.data[[value_col]]))
  if (nrow(d) < 3 || n_distinct(d$publication_year) < 3) {
    return(tibble(slope = NA_real_, annual_growth = NA_real_))
  }
  fit <- lm(log(.data[[value_col]]) ~ publication_year, data = d)
  slope <- unname(coef(fit)[["publication_year"]])
  tibble(slope = slope, annual_growth = 100 * (exp(slope) - 1))
}

background_fit <- fit_growth(background, "background_records")

# Calculate a fitted background trajectory on the same absolute scale as each
# topic. This makes the dashed line a genuine background growth-rate trend,
# rather than a separate arbitrarily indexed series.
background_model <- lm(log(background_records) ~ publication_year, data = filter(background, background_records > 0))
background_pred <- background %>%
  mutate(background_trend = exp(predict(background_model, newdata = background)))

trend_rows <- lapply(topic_order, function(tp) {
  d <- plot_data %>% filter(topic == tp)
  f <- fit_growth(d, "topic_records")
  tibble(topic = tp, slope = f$slope, annual_growth_percent = f$annual_growth)
}) %>% bind_rows()

plot_data <- plot_data %>%
  left_join(background_pred %>% select(publication_year, background_trend), by = "publication_year") %>%
  left_join(trend_rows %>% select(topic, slope), by = "topic") %>%
  mutate(
    topic_trend = exp(predict(lm(log(topic_records) ~ publication_year,
                                 data = cur_data() %>% filter(topic_records > 0)),
                              newdata = cur_data()))
  )

# The expression above cannot safely fit separate models inside mutate for
# sparse topics, so construct fitted topic trends explicitly.
topic_trends <- lapply(topic_order, function(tp) {
  d <- plot_data %>% filter(topic == tp, topic_records > 0)
  fit <- lm(log(topic_records) ~ publication_year, data = d)
  tibble(topic = tp, publication_year = all_years,
         topic_trend = exp(predict(fit, newdata = tibble(publication_year = all_years))))
}) %>% bind_rows()

plot_data <- plot_data %>%
  select(-topic_trend) %>%
  left_join(topic_trends, by = c("topic", "publication_year"))

# Growth-rate summary and relative acceleration against the background.
summary_data <- trend_rows %>%
  mutate(
    background_annual_growth_percent = background_fit$annual_growth,
    relative_growth_rate = annual_growth_percent - background_annual_growth_percent
  ) %>%
  arrange(desc(relative_growth_rate))

write_csv(
  plot_data %>% arrange(topic, publication_year),
  file.path(out_dir, "figure_06_rapidly_emerging_topics_data.csv")
)
write_csv(summary_data, file.path(out_dir, "figure_06_rapidly_emerging_topics_summary.csv"))

# -------------------------------------------------------------------------
# Figure
# -------------------------------------------------------------------------
# Each panel uses the same y-axis type (record count) and shows the observed
# annual topic counts together with its fitted growth trajectory. The grey
# dashed trajectory is the fitted growth of the complete evidence base,
# rescaled to the topic's first observed count so that relative acceleration
# is visually interpretable.

plot_data <- plot_data %>%
  group_by(topic) %>%
  mutate(
    first_year = min(publication_year[topic_records > 0], na.rm = TRUE),
    first_topic_count = first(topic_records[publication_year == first_year & topic_records > 0]),
    first_background_trend = first(background_trend[publication_year == first_year]),
    background_rescaled = background_trend * first_topic_count / first_background_trend
  ) %>%
  ungroup()

p <- ggplot(plot_data, aes(x = publication_year)) +
  geom_line(aes(y = background_rescaled), colour = "#B8B8B8", linewidth = 0.7, linetype = "dashed") +
  geom_line(aes(y = topic_trend), colour = "#E55634", linewidth = 0.85) +
  geom_point(aes(y = topic_records), colour = "#E55634", size = 1.0) +
  facet_wrap(~ factor(topic, levels = topic_order), ncol = 3, scales = "free_y") +
  scale_x_continuous(breaks = scales::breaks_pretty(n = 7), expand = expansion(mult = c(0.01, 0.02))) +
  scale_y_continuous(labels = comma, expand = expansion(mult = c(0, 0.10))) +
  labs(
    title = "Rapidly emerging topics in the evidence base",
    subtitle = paste0(
      "Observed annual output and fitted topic growth; dashed line = background database growth rate (",
      number(background_fit$annual_growth, accuracy = 0.1), "% per year)"
    ),
    x = "Publication year",
    y = "Records per year",
    caption = "Red points = observed topic records; red line = fitted log-linear topic trend; dashed grey line = fitted background trend, rescaled to the topic's first observed count."
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

ggsave(file.path(out_dir, "figure_06_rapidly_emerging_topics.pdf"), p,
       width = 190, height = 235, units = "mm", device = cairo_pdf)
ggsave(file.path(out_dir, "figure_06_rapidly_emerging_topics.png"), p,
       width = 190, height = 235, units = "mm", dpi = 600)

message("Figure 6 written to: ", out_dir)
