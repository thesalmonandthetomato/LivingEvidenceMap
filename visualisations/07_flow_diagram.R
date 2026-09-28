#!/usr/bin/env Rscript

# Workflow 09 manuscript flow diagram.
#
# Authoritative count provenance:
#   docs/reporting/workflow_09/flow_counts.json
#
# The count manifest links:
#   - Workflow 00/01 source-retrieval + canonical manifest state
#   - Workflow 02 metadata-enrichment state
#   - Workflow 08 final included/excluded state
#
# The diagram follows the agreed PowerPoint structure:
# source databases -> combined retrieval -> deduplication -> repair/enrichment ->
# screening -> species/geography/topic annotation -> Living Evidence Map.

required <- c("dplyr", "ggplot2", "readr", "stringr", "here", "jsonlite")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) stop("Install required packages: ", paste(missing, collapse = ", "))

library(dplyr)
library(ggplot2)
library(readr)
library(stringr)
library(here)
library(jsonlite)

source(here::here("visualisations", "canonical_figure_data.R"))

out_dir <- here::here("visualisations")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# -------------------------------------------------------------------------
# 1. AUTHORITATIVE FINAL STATE
# -------------------------------------------------------------------------

canonical <- load_figure_master()
n_final_included <- nrow(canonical)

exclusions_path <- canonical_arg("--exclusions-csv") %||%
  Sys.getenv("EXCLUSIONS_CSV", unset = "")

if (!nzchar(exclusions_path)) {
  candidates <- c(
    file.path("data", "master", "current", "workflow08_excluded_records.csv"),
    file.path("outputs", "workflow08_corrected", "workflow08_excluded_records.csv"),
    file.path("outputs", "workflow08", "workflow08_excluded_records.csv")
  )
  hit <- candidates[file.exists(candidates)]
  exclusions_path <- if (length(hit)) hit[[1L]] else ""
}

if (!nzchar(exclusions_path) || !file.exists(exclusions_path)) {
  stop(
    "Workflow 08 exclusions CSV is required. Provide --exclusions-csv or set EXCLUSIONS_CSV.",
    call. = FALSE
  )
}

exclusions <- readr::read_csv(exclusions_path, show_col_types = FALSE, progress = FALSE)
if (!all(c("record_id", "exclusion_stage") %in% names(exclusions))) {
  stop("Exclusions CSV must contain record_id and exclusion_stage.", call. = FALSE)
}

stage_counts <- exclusions %>% count(exclusion_stage, name = "n")
stage_n <- function(stage) {
  x <- stage_counts$n[match(stage, stage_counts$exclusion_stage)]
  if (!length(x) || is.na(x)) 0L else as.integer(x)
}

n_w03 <- stage_n("workflow03")
n_w04 <- stage_n("workflow04")
n_w07 <- stage_n("workflow07_late")
n_w08 <- stage_n("workflow08")
n_excluded <- nrow(exclusions)
n_deduplicated <- n_final_included + n_excluded
n_screened_ta <- n_deduplicated - n_w03
n_excluded_ta_total <- n_w04 + n_w07 + n_w08
n_retained_final <- n_screened_ta - n_excluded_ta_total

n_topic_uncoded <- sum(
  is.na(canonical$topic_hierarchy_paths) |
    stringr::str_trim(canonical$topic_hierarchy_paths) == ""
)
n_topic_coded <- n_final_included - n_topic_uncoded

# -------------------------------------------------------------------------
# 2. WORKFLOW 00/01 + WORKFLOW 02 REPORTING COUNTS
# -------------------------------------------------------------------------

counts_path <- canonical_arg("--flow-counts") %||%
  Sys.getenv(
    "FLOW_COUNTS_JSON",
    unset = here::here("docs", "reporting", "workflow_09", "flow_counts.json")
  )

if (!file.exists(counts_path)) stop("Workflow 09 flow-count manifest not found: ", counts_path, call. = FALSE)
flow <- jsonlite::fromJSON(counts_path, simplifyVector = TRUE)

if (!identical(flow$status, "final")) stop("Flow-count manifest is not final.", call. = FALSE)

src <- flow$counts$sources
source_counts <- c(
  "AGRICOLA" = as.integer(src[["AGRICOLA"]]),
  "The Lens" = as.integer(src[["The Lens"]]),
  "OpenAlex" = as.integer(src[["OpenAlex"]]),
  "Scopus" = as.integer(src[["Scopus"]]),
  "WoSCC" = as.integer(src[["WoSCC"]])
)

n_combined <- as.integer(flow$counts$combined_search_results)
n_duplicates_removed <- as.integer(flow$counts$duplicates_removed)
n_enriched <- as.integer(flow$counts$records_enriched_workflow02)

# Assertions bind the figure to the actual authoritative state.
stopifnot(
  sum(source_counts) == n_combined,
  n_combined == 90137L,
  n_duplicates_removed == n_combined - n_deduplicated,
  n_duplicates_removed == 57845L,
  n_deduplicated == 32292L,
  n_enriched == 2190L,
  n_w03 == 9L,
  n_screened_ta == 32283L,
  n_w04 == 12876L,
  n_w07 == 122L,
  n_w08 == 168L,
  n_excluded_ta_total == 13166L,
  n_retained_final == 19117L,
  n_final_included == 19117L,
  n_topic_coded == 18886L,
  n_topic_uncoded == 231L,
  as.integer(flow$counts$final_included) == n_final_included
)

fmt <- function(x) format(as.integer(x), big.mark = ",", scientific = FALSE, trim = TRUE)

# -------------------------------------------------------------------------
# 3. DIAGRAM GEOMETRY
# -------------------------------------------------------------------------

box <- function(id, x, y, w, h, label, stage) {
  data.frame(id, x, y, w, h, label, stage, stringsAsFactors = FALSE)
}

boxes <- bind_rows(
  box("agricola", 2.60, 12.00, 1.45, 0.76, paste0("AGRICOLA\nn = ", fmt(source_counts[["AGRICOLA"]])), "source"),
  box("lens",     4.12, 12.00, 1.45, 0.76, paste0("The Lens\nn = ", fmt(source_counts[["The Lens"]])), "source"),
  box("openalex", 5.64, 12.00, 1.45, 0.76, paste0("OpenAlex\nn = ", fmt(source_counts[["OpenAlex"]])), "source"),
  box("scopus",   7.16, 12.00, 1.45, 0.76, paste0("Scopus\nn = ", fmt(source_counts[["Scopus"]])), "source"),
  box("wos",      8.68, 12.00, 1.45, 0.76, paste0("WoSCC\nn = ", fmt(source_counts[["WoSCC"]])), "source"),

  box("combined", 5.64, 10.88, 2.55, 0.76, paste0("Combined search results\nn = ", fmt(n_combined)), "search"),
  box("dedup", 5.64, 9.78, 2.55, 0.76, paste0("Deduplicated records\nn = ", fmt(n_deduplicated)), "screen"),
  box("dupes", 9.15, 9.78, 2.25, 0.76, paste0("Duplicate records removed\nn = ", fmt(n_duplicates_removed)), "exclude"),

  box("enrichment", 5.64, 8.68, 2.75, 0.76, paste0("Record repair and enrichment\nn enriched = ", fmt(n_enriched)), "repair"),

  box("status_sweep", 5.64, 7.58, 2.85, 0.76, paste0("Records swept for retractions /\nwithdrawal notices\nn = ", fmt(n_deduplicated)), "screen"),
  box("retractions", 9.15, 7.58, 2.25, 0.76, paste0("Retractions excluded\nn = ", fmt(n_w03)), "exclude"),

  box("screened", 5.64, 6.48, 2.65, 0.76, paste0("Records screened at title and abstract\nn = ", fmt(n_screened_ta)), "screen"),
  box("excluded_ta", 9.15, 6.48, 2.55, 0.76, paste0("Records excluded at title and abstract\nn = ", fmt(n_excluded_ta_total)), "exclude"),
  box("retained", 5.64, 5.38, 2.65, 0.76, paste0("Records retained after title and abstract\nn = ", fmt(n_retained_final)), "retain"),

  box("species", 5.64, 4.18, 2.45, 0.76, paste0("Species annotation\nn = ", fmt(n_final_included)), "annotate"),
  box("geography", 5.64, 3.13, 2.45, 0.76, paste0("Geography annotation\nn = ", fmt(n_final_included)), "annotate"),
  box("topic", 5.64, 2.08, 2.45, 0.76, paste0("Topic annotation\nn = ", fmt(n_final_included)), "annotate"),
  box("uncoded", 9.15, 2.08, 2.40, 0.76, paste0("Included but uncoded for topics\nn = ", fmt(n_topic_uncoded)), "result"),

  box("map", 5.64, 0.88, 2.65, 0.86, paste0("Living Evidence Map\nn = ", fmt(n_final_included)), "map")
)

# Source lines join a common collector.
source_vertical <- data.frame(
  x = c(2.60, 4.12, 5.64, 7.16, 8.68),
  y = rep(11.62, 5),
  xend = c(2.60, 4.12, 5.64, 7.16, 8.68),
  yend = rep(11.43, 5)
)
source_collector <- data.frame(x = 2.60, y = 11.43, xend = 8.68, yend = 11.43)

main_arrows <- data.frame(
  x = rep(5.64, 9),
  y = c(11.43, 10.50, 9.40, 8.30, 7.20, 6.10, 5.00, 3.80, 2.75),
  xend = rep(5.64, 9),
  yend = c(11.26, 10.16, 9.06, 7.96, 6.86, 5.76, 4.56, 3.51, 2.46)
)
main_arrows <- bind_rows(
  main_arrows,
  data.frame(x = 5.64, y = 1.70, xend = 5.64, yend = 1.31)
)

side_connectors <- data.frame(
  x = c(6.92, 7.07, 6.97, 6.87),
  y = c(9.78, 7.58, 6.48, 2.08),
  xend = c(8.03, 8.03, 7.88, 7.95),
  yend = c(9.78, 7.58, 6.48, 2.08)
)

phase <- data.frame(
  x = rep(0.92, 4),
  y = c(11.35, 7.20, 3.20, 0.88),
  w = rep(0.54, 4),
  h = c(1.80, 4.35, 3.10, 0.96),
  label = c("Searching", "Curation and screening", "Annotation and classification", "Map"),
  stringsAsFactors = FALSE
)

# -------------------------------------------------------------------------
# 4. PLOT
# -------------------------------------------------------------------------

stage_fill <- c(
  source = "#f5f4f0",
  search = "#dce7e7",
  screen = "#dce7e7",
  repair = "#a8bdbe",
  retain = "#e2b8a2",
  annotate = "#f6d6c6",
  exclude = "#f1efeb",
  result = "#dce7e7",
  map = "#e55634"
)
stage_text <- c(
  source = "#2c454a",
  search = "#2c454a",
  screen = "#2c454a",
  repair = "#2c454a",
  retain = "#2c454a",
  annotate = "#2c454a",
  exclude = "#2c454a",
  result = "#2c454a",
  map = "white"
)

p <- ggplot() +
  geom_segment(
    data = source_vertical,
    aes(x=x, y=y, xend=xend, yend=yend),
    colour = "#577c84", linewidth = 0.55
  ) +
  geom_segment(
    data = source_collector,
    aes(x=x, y=y, xend=xend, yend=yend),
    colour = "#577c84", linewidth = 0.55
  ) +
  geom_segment(
    data = main_arrows,
    aes(x=x, y=y, xend=xend, yend=yend),
    colour = "#577c84", linewidth = 0.55,
    arrow = grid::arrow(length = grid::unit(2.3, "mm"), type = "closed")
  ) +
  geom_segment(
    data = side_connectors,
    aes(x=x, y=y, xend=xend, yend=yend),
    colour = "#577c84", linewidth = 0.55
  ) +
  geom_rect(
    data = boxes,
    aes(
      xmin = x - w/2, xmax = x + w/2,
      ymin = y - h/2, ymax = y + h/2,
      fill = stage
    ),
    colour = "#2c454a", linewidth = 0.45
  ) +
  geom_text(
    data = boxes,
    aes(x=x, y=y, label=label, colour=stage),
    size = 2.95, lineheight = 0.92
  ) +
  geom_rect(
    data = phase,
    aes(
      xmin = x - w/2, xmax = x + w/2,
      ymin = y - h/2, ymax = y + h/2
    ),
    fill = "#577c84", colour = "#2c454a", linewidth = 0.45
  ) +
  geom_text(
    data = phase,
    aes(x=x, y=y, label=label),
    angle = 90, colour = "white", fontface = "bold", size = 3.05
  ) +
  scale_fill_manual(values = stage_fill, guide = "none") +
  scale_colour_manual(values = stage_text, guide = "none") +
  coord_cartesian(xlim = c(0.45, 10.65), ylim = c(0.25, 12.50), expand = FALSE) +
  theme_void(base_size = 11) +
  theme(
    plot.background = element_rect(fill = "white", colour = NA),
    plot.margin = margin(8, 8, 8, 8)
  )

ggsave(
  file.path(out_dir, "figure_07_flow_diagram.pdf"),
  p, width = 210, height = 245, units = "mm", device = cairo_pdf
)
ggsave(
  file.path(out_dir, "figure_07_flow_diagram.png"),
  p, width = 210, height = 245, units = "mm", dpi = 600
)

readr::write_csv(
  boxes %>% select(id, label, stage),
  file.path(out_dir, "figure_07_flow_diagram_boxes.csv")
)

readr::write_csv(
  data.frame(
    metric = c(
      paste0("source_", names(source_counts)),
      "combined_search_results",
      "duplicates_removed",
      "deduplicated_records",
      "records_enriched_workflow02",
      "retractions_excluded",
      "records_screened_title_abstract",
      "records_excluded_title_abstract_total",
      "records_retained_final",
      "final_topic_coded",
      "final_topic_uncoded",
      "final_included"
    ),
    n = c(
      unname(source_counts),
      n_combined,
      n_duplicates_removed,
      n_deduplicated,
      n_enriched,
      n_w03,
      n_screened_ta,
      n_excluded_ta_total,
      n_retained_final,
      n_topic_coded,
      n_topic_uncoded,
      n_final_included
    )
  ),
  file.path(out_dir, "figure_07_flow_diagram_counts.csv")
)

message("Workflow 09 flow diagram written to: ", out_dir)
