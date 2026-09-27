#!/usr/bin/env Rscript

# Figure 7: manuscript flow diagram for the Living Evidence Map.
# The layout follows the current presentation template while deriving all
# available counts from the Workflow 08 canonical JSONL and exclusions CSV.

required <- c("dplyr", "ggplot2", "readr", "stringr", "here", "jsonlite")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) stop("Install required packages: ", paste(missing, collapse = ", "))

library(dplyr); library(ggplot2); library(readr); library(stringr); library(here)
source(here::here("visualisations", "canonical_figure_data.R"))

out_dir <- here::here("visualisations")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

canonical <- load_figure_master()
n_included <- nrow(canonical)
n_no_topic <- sum(is.na(canonical$topic_hierarchy_paths) | stringr::str_trim(canonical$topic_hierarchy_paths) == "")
n_topic_classified <- n_included - n_no_topic
n_no_geography <- sum(canonical$geography_status == "NONE" | is.na(canonical$final_primary_country_iso3c) | stringr::str_trim(canonical$final_primary_country_iso3c) == "")
n_geography <- n_included - n_no_geography

exclusions_path <- canonical_arg("--exclusions-csv") %||% Sys.getenv("EXCLUSIONS_CSV", unset = "")
if (!nzchar(exclusions_path)) {
  candidates <- c(
    file.path("data", "master", "current", "workflow08_excluded_records.csv"),
    file.path("outputs", "workflow08_corrected", "workflow08_excluded_records.csv"),
    file.path("outputs", "workflow08", "workflow08_excluded_records.csv")
  )
  hit <- candidates[file.exists(candidates)]
  exclusions_path <- if (length(hit)) hit[[1L]] else ""
}
if (nzchar(exclusions_path) && file.exists(exclusions_path)) {
  exclusions <- readr::read_csv(exclusions_path, show_col_types = FALSE, progress = FALSE)
  ex_by_stage <- exclusions %>% count(exclusion_stage, name = "n")
  get_stage <- function(stage) ex_by_stage$n[match(stage, ex_by_stage$exclusion_stage)] %||% NA_integer_
  n_w03 <- get_stage("workflow03"); n_w04 <- get_stage("workflow04"); n_w07 <- get_stage("workflow07_late"); n_w08 <- get_stage("workflow08")
  n_excluded <- nrow(exclusions)
} else {
  n_w03 <- 9L; n_w04 <- 12876L; n_w07 <- 122L; n_w08 <- 168L; n_excluded <- 13175L
}
n_source <- n_included + n_excluded
n_screened <- n_source - n_w03
n_retained_ta <- n_screened - n_w04
fmt <- function(x) ifelse(is.na(x), "TBC", format(x, big.mark = ",", scientific = FALSE, trim = TRUE))
box <- function(id, x, y, w, h, label, stage) data.frame(id, x, y, w, h, label, stage, stringsAsFactors = FALSE)
boxes <- bind_rows(
  box("agricola", 0.5, 10.0, 1.55, 0.75, "AGRICOLA\nn = TBC", "search"),
  box("scopus", 2.2, 10.0, 1.55, 0.75, "Scopus\nn = TBC", "search"),
  box("wos", 3.9, 10.0, 1.55, 0.75, "WoSCC\nn = TBC", "search"),
  box("lens", 5.6, 10.0, 1.55, 0.75, "The Lens\nn = TBC", "search"),
  box("openalex", 7.3, 10.0, 1.55, 0.75, "OpenAlex\nn = TBC", "search"),
  box("dedup", 3.6, 8.75, 2.4, 0.8, paste0("Deduplicated records\nn = ", fmt(n_source)), "screen"),
  box("dupes", 6.55, 8.75, 2.0, 0.8, "Duplicates\nn = TBC", "exclude"),
  box("retractions", 0.85, 7.45, 2.25, 0.8, paste0("Retractions / withdrawn\nn = ", fmt(n_w03)), "exclude"),
  box("screened", 3.6, 7.45, 2.4, 0.8, paste0("Records screened\nn = ", fmt(n_screened)), "screen"),
  box("excluded_ta", 6.55, 7.45, 2.35, 0.8, paste0("Excluded titles & abstracts\nn = ", fmt(n_w04)), "exclude"),
  box("included_ta", 3.6, 6.15, 2.4, 0.8, paste0("Included titles & abstracts\nn = ", fmt(n_retained_ta)), "retain"),
  box("species", 3.6, 4.9, 2.4, 0.8, paste0("Species annotation\nn = ", fmt(n_retained_ta)), "annotate"),
  box("nogeo", 0.85, 3.65, 2.25, 0.8, paste0("No geography\nn = ", fmt(n_no_geography)), "exclude"),
  box("geo", 3.6, 3.65, 2.4, 0.8, paste0("Geography annotation\nn = ", fmt(n_geography)), "annotate"),
  box("notopic", 0.85, 2.4, 2.25, 0.8, paste0("No topic\nn = ", fmt(n_no_topic)), "exclude"),
  box("topic", 3.6, 2.4, 2.4, 0.8, paste0("Topic classification\nn = ", fmt(n_topic_classified)), "annotate"),
  box("lateex", 6.55, 2.4, 2.35, 0.8, paste0("Late exclusions\nn = ", fmt(n_w07 + n_w08)), "exclude"),
  box("map", 3.6, 1.05, 2.4, 0.85, paste0("Living Evidence Map\nn = ", fmt(n_included)), "map")
)
segments <- data.frame(
  x = c(1.275,2.975,4.675,6.375,8.075, 4.8,4.8,4.8,4.8,4.8,4.8,4.8,4.8, 6.0,6.0,3.6),
  y = c(10.0,10.0,10.0,10.0,10.0, 8.75,7.45,6.15,4.9,3.65,2.4, 7.45,2.4, 9.15,7.85,2.8),
  xend = c(4.8,4.8,4.8,4.8,4.8, 4.8,4.8,4.8,4.8,4.8,4.8, 6.55,6.55, 6.55,6.55,3.1),
  yend = c(9.55,9.55,9.55,9.55,9.55, 8.25,6.95,5.7,4.45,3.2,1.9, 7.85,2.8, 9.15,7.85,2.8)
)
stage_cols <- c(search = "#dce7e7", screen = "#a8bdbe", retain = "#e2b8a2", annotate = "#ffcfba", exclude = "#f0f0ea", map = "#e55634")
label_cols <- c(search = "#2c454a", screen = "#2c454a", retain = "#2c454a", annotate = "#2c454a", exclude = "#2c454a", map = "white")
phase <- data.frame(x = c(0.3,0.3,0.3,0.3), y = c(9.65,7.2,4.0,1.25), label = c("Searching", "Curation and screening", "Annotation and classification", "Map"))
p <- ggplot() +
  geom_segment(data = segments, aes(x = x, y = y, xend = xend, yend = yend), arrow = arrow(length = unit(2.5, "mm"), type = "closed"), linewidth = 0.45, colour = "#577c84") +
  geom_rect(data = boxes, aes(xmin = x - w/2, xmax = x + w/2, ymin = y - h/2, ymax = y + h/2, fill = stage), colour = "#2c454a", linewidth = 0.45, radius = unit(1.5, "mm")) +
  geom_text(data = boxes, aes(x = x, y = y, label = label, colour = stage), size = 3.0, lineheight = 0.9, fontface = "bold") +
  geom_label(data = phase, aes(x = x, y = y, label = label), angle = 90, fill = "#2c454a", colour = "white", label.size = 0, fontface = "bold", size = 3.2) +
  scale_fill_manual(values = stage_cols, guide = "none") +
  scale_colour_manual(values = label_cols, guide = "none") +
  coord_cartesian(xlim = c(0, 9.25), ylim = c(0.25, 10.75), expand = FALSE) +
  theme_void(base_size = 11) +
  theme(plot.background = element_rect(fill = "white", colour = NA), plot.margin = margin(10,10,10,10))

ggsave(file.path(out_dir, "figure_07_flow_diagram.pdf"), p, width = 190, height = 220, units = "mm", device = cairo_pdf)
ggsave(file.path(out_dir, "figure_07_flow_diagram.png"), p, width = 190, height = 220, units = "mm", dpi = 600)
readr::write_csv(boxes %>% select(id, label, stage), file.path(out_dir, "figure_07_flow_diagram_boxes.csv"))
message("Flow diagram written to: ", out_dir)
