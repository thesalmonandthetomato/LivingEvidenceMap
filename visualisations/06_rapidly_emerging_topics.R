#!/usr/bin/env Rscript

# Figure 6: Rapidly emerging topics relative to background evidence-base growth.
# Source: Workflow 08 included-only canonical JSONL.

required <- c("dplyr", "ggplot2", "readr", "tidyr", "stringr", "scales", "here", "jsonlite")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) stop("Install required packages: ", paste(missing, collapse = ", "))

library(dplyr); library(ggplot2); library(readr); library(tidyr); library(stringr); library(scales); library(here)
source(here::here("visualisations", "canonical_figure_data.R"))

out_dir <- here::here("visualisations")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

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

topic_order <- c("Monitoring and sampling methods", "Automation and precision aquaculture", "Smoltification and smolt quality", "Novel feed resources", "Welfare assessment and risks", "Climate change", "Sensors, imaging and measurement", "Statistical and modelling methods", "Antimicrobial resistance and One Health", "Energy, greenhouse gases and life-cycle footprint", "By-products and waste as inputs", "Plastics and solid waste")
topic_labels <- c("Monitoring and sampling methods" = "Monitoring and\nsampling methods", "Automation and precision aquaculture" = "Automation and\nprecision aquaculture", "Smoltification and smolt quality" = "Smoltification and\nsmolt quality", "Novel feed resources" = "Novel feed\nresources", "Welfare assessment and risks" = "Welfare assessment\nand risks", "Climate change" = "Climate change", "Sensors, imaging and measurement" = "Sensors, imaging\nand measurement", "Statistical and modelling methods" = "Statistical and\nmodelling methods", "Antimicrobial resistance and One Health" = "Antimicrobial resistance\nand One Health", "Energy, greenhouse gases and life-cycle footprint" = "Energy, greenhouse gases\nand life-cycle footprint", "By-products and waste as inputs" = "By-products and waste\nas inputs", "Plastics and solid waste" = "Plastics and solid waste")

master <- load_figure_master() %>% transmute(record_id, publication_year = year, topic_hierarchy_paths) %>% filter(!is.na(publication_year), publication_year <= 2025L)
expanded <- master %>%
  filter(!is.na(topic_hierarchy_paths), str_trim(topic_hierarchy_paths) != "") %>%
  mutate(path = str_split(topic_hierarchy_paths, "\\s*;\\s*")) %>% unnest(path) %>%
  mutate(path = str_squish(path)) %>% filter(path != "") %>% distinct(record_id, publication_year, path)

topic_matches <- expanded %>% inner_join(rapid_topics, by = c("path" = "canonical_path")) %>% distinct(record_id, publication_year, topic, path)
write_csv(topic_matches %>% count(topic, path, sort = TRUE), file.path(out_dir, "figure_06_rapidly_emerging_topics_taxonomy_mapping.csv"))
missing_topics <- setdiff(topic_order, topic_matches$topic)
if (length(missing_topics) > 0) stop("No database records matched: ", paste(missing_topics, collapse = ", "))

background <- master %>% distinct(record_id, publication_year) %>% count(publication_year, name = "background_records")
all_years <- seq(min(background$publication_year), max(background$publication_year), by = 1)
background <- tibble(publication_year = all_years) %>% left_join(background, by = "publication_year") %>% mutate(background_records = replace_na(background_records, 0L))
topic_counts <- topic_matches %>% distinct(topic, record_id, publication_year) %>% count(topic, publication_year, name = "topic_records")
plot_data <- tidyr::expand_grid(topic = topic_order, publication_year = all_years) %>% left_join(topic_counts, by = c("topic", "publication_year")) %>% mutate(topic_records = replace_na(topic_records, 0L)) %>% left_join(background, by = "publication_year")
background_baseline <- background %>% filter(publication_year >= 2010, publication_year <= 2014) %>% summarise(x = mean(background_records)) %>% pull(x)
background_recent <- background %>% filter(publication_year >= 2021, publication_year <= 2025) %>% summarise(x = mean(background_records)) %>% pull(x)
if (is.na(background_baseline) || background_baseline <= 0) stop("Could not calculate the 2010-2014 background baseline.")
background_growth_ratio <- background_recent / background_baseline
background_fit_data <- background %>% filter(publication_year >= 2010, background_records > 0) %>% mutate(log_records = log(background_records))
background_fit <- lm(log_records ~ publication_year, data = background_fit_data)
background_fit_raw <- tibble(publication_year = all_years, background_trend_raw = exp(as.numeric(predict(background_fit, newdata = data.frame(publication_year = all_years)))))
background_fit_baseline <- mean(background_fit_raw$background_trend_raw[background_fit_raw$publication_year >= 2010 & background_fit_raw$publication_year <= 2014])
plot_data <- plot_data %>% left_join(background_fit_raw, by = "publication_year") %>% mutate(background_growth_index = 100 * background_trend_raw / background_fit_baseline)

topic_baselines <- plot_data %>% group_by(topic) %>% summarise(baseline_2010_2014 = mean(topic_records[publication_year >= 2010 & publication_year <= 2014]), first_observed_year = min(publication_year[topic_records > 0]), first_observed_count = topic_records[publication_year == first_observed_year][1], .groups = "drop")
plot_data <- plot_data %>% left_join(topic_baselines, by = "topic") %>% mutate(topic_growth_index = case_when(topic == "Plastics and solid waste" ~ if_else(publication_year >= first_observed_year & topic_records > 0, 100 * topic_records / first_observed_count, NA_real_), baseline_2010_2014 > 0 ~ 100 * topic_records / baseline_2010_2014, TRUE ~ NA_real_))
summary_data <- plot_data %>% group_by(topic) %>% summarise(baseline_2010_2014 = first(baseline_2010_2014), first_observed_year = first(first_observed_year), mean_2021_2025 = mean(topic_records[publication_year >= 2021 & publication_year <= 2025]), .groups = "drop") %>% mutate(growth_ratio_2010_14_to_2021_25 = if_else(baseline_2010_2014 > 0, mean_2021_2025 / baseline_2010_2014, NA_real_), background_growth_ratio = background_growth_ratio, relative_to_background = growth_ratio_2010_14_to_2021_25 / background_growth_ratio, classification = ifelse(topic == "Plastics and solid waste", "New theme; no 2010-2014 baseline", ifelse(growth_ratio_2010_14_to_2021_25 > background_growth_ratio, "Faster than background", "Not faster than background"))) %>% arrange(desc(relative_to_background))
write_csv(plot_data %>% arrange(topic, publication_year), file.path(out_dir, "figure_06_rapidly_emerging_topics_data.csv"))
write_csv(summary_data, file.path(out_dir, "figure_06_rapidly_emerging_topics_summary.csv"))

plot_data <- plot_data %>% mutate(topic_plot = factor(topic, levels = topic_order, labels = unname(topic_labels[topic_order])))
p <- ggplot(plot_data, aes(x = publication_year)) +
  geom_hline(yintercept = 100, colour = "#D9DEDF", linewidth = 0.35) +
  geom_line(aes(y = background_growth_index), colour = "#8E989B", linewidth = 0.85, linetype = "dashed") +
  geom_line(aes(y = topic_growth_index), colour = "#E55634", linewidth = 0.95, na.rm = TRUE) +
  geom_point(aes(y = topic_growth_index), colour = "#E55634", size = 0.85, na.rm = TRUE) +
  facet_wrap(~ topic_plot, ncol = 3, scales = "free_y") +
  scale_x_continuous(limits = c(2010, max(all_years)), breaks = seq(2010, max(all_years), by = 5), expand = expansion(mult = c(0.01, 0.04))) +
  scale_y_continuous(labels = label_comma()) +
  labs(x = "Publication year", y = "Growth index (2010–2014 mean = 100)", caption = "Red = topic; dashed grey = fitted background evidence-base growth. Plastics and solid waste is indexed to first observed year.") +
  theme_classic(base_size = 9.5) +
  theme(strip.background = element_rect(fill = "#E8EDED", colour = NA), strip.text = element_text(face = "bold", colour = "#2C454A", size = 8.5), axis.title = element_text(face = "bold", colour = "#2C454A"), axis.text = element_text(colour = "#2C454A"), plot.caption = element_text(colour = "#577C84", hjust = 0, size = 7.5), panel.grid.major.y = element_line(colour = "grey90", linewidth = 0.2), panel.grid.minor = element_blank())

ggsave(file.path(out_dir, "figure_06_rapidly_emerging_topics.pdf"), p, width = 210, height = 230, units = "mm", device = cairo_pdf)
ggsave(file.path(out_dir, "figure_06_rapidly_emerging_topics.png"), p, width = 210, height = 230, units = "mm", dpi = 600)
message("Figure 6 written to: ", out_dir)
