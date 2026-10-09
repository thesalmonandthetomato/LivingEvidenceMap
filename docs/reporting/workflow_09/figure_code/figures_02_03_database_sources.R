#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(dplyr)
})

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s", flag), call. = FALSE)
  args[[i + 1L]]
}

input_dir <- arg("--input-dir", "docs/reporting/workflow_09_inputs/current")
output_dir <- arg("--output-dir", "outputs/citesource_contribution")
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

required <- c(
  "w01_source_summary.csv",
  "w01_source_intersections.csv",
  "w01_source_manifest.json",
  "w08_source_summary.csv",
  "w08_source_intersections.csv",
  "w08_source_manifest.json"
)
missing <- required[!file.exists(file.path(input_dir, required))]
if (length(missing)) stop("Missing compact source-reporting input(s): ", paste(missing, collapse = ", "), call. = FALSE)

w01_sources <- read.csv(file.path(input_dir, "w01_source_summary.csv"), stringsAsFactors = FALSE)
w08_sources <- read.csv(file.path(input_dir, "w08_source_summary.csv"), stringsAsFactors = FALSE)
w01_int <- read.csv(file.path(input_dir, "w01_source_intersections.csv"), stringsAsFactors = FALSE)
w08_int <- read.csv(file.path(input_dir, "w08_source_intersections.csv"), stringsAsFactors = FALSE)
w01_manifest <- fromJSON(file.path(input_dir, "w01_source_manifest.json"), simplifyVector = FALSE)
w08_manifest <- fromJSON(file.path(input_dir, "w08_source_manifest.json"), simplifyVector = FALSE)

stopifnot(
  identical(as.character(w01_manifest$stage), "W01"),
  identical(as.character(w08_manifest$stage), "W08"),
  sum(w01_int$records) == as.integer(w01_manifest$canonical_records),
  sum(w08_int$records) == as.integer(w08_manifest$canonical_records)
)

source_order_codes <- w01_sources |>
  arrange(desc(canonical_works), database) |>
  pull(source_code)
label_map <- setNames(w01_sources$database, w01_sources$source_code)
source_order <- unname(label_map[source_order_codes])

# W08 may legitimately have zero final included records from a source. Keep all
# W01 databases in the reporting frame and fill absent W08 counts with zero.
w08_by_code <- setNames(as.integer(w08_sources$canonical_works), w08_sources$source_code)

unique_w01 <- w01_int |> filter(degree == 1L)
unique_w08 <- w08_int |> filter(degree == 1L)
u1 <- setNames(as.integer(unique_w01$records), unique_w01$intersection_key)
u8 <- setNames(as.integer(unique_w08$records), unique_w08$intersection_key)

unique_summary <- tibble(
  source_code = source_order_codes,
  database = source_order,
  unique_deduplicated_records = vapply(source_order_codes, function(code) if (code %in% names(u1)) u1[[code]] else 0L, integer(1)),
  unique_included_records = vapply(source_order_codes, function(code) if (code %in% names(u8)) u8[[code]] else 0L, integer(1))
) |>
  arrange(desc(unique_deduplicated_records), database)

write.csv(unique_summary, file.path(output_dir, "source_unique_contribution_summary.csv"), row.names = FALSE)

plot_unique_contribution <- function(device = c("png", "pdf")) {
  device <- match.arg(device)
  included_col <- "#FF9D78"
  n_sources <- nrow(unique_summary)
  fig_h <- max(5.6, 2.4 + 0.42 * n_sources)
  if (device == "png") {
    png(file.path(output_dir, "database_unique_contribution.png"), width = 2200, height = round(fig_h * 220), res = 220)
  } else {
    pdf(file.path(output_dir, "database_unique_contribution.pdf"), width = 10.0, height = fig_h, useDingbats = FALSE)
  }
  on.exit(dev.off(), add = TRUE)

  ord <- rev(seq_len(n_sources))
  mat <- rbind(unique_summary$unique_deduplicated_records[ord], unique_summary$unique_included_records[ord])
  labs <- unique_summary$database[ord]
  xmax <- max(mat); if (!is.finite(xmax) || xmax <= 0) xmax <- 1

  op <- par(mar = c(4.7, 9.2, 1.2, 1.0), xpd = NA)
  bp <- barplot(
    mat, beside = TRUE, horiz = TRUE, names.arg = labs, las = 1,
    col = c("black", included_col), border = NA,
    xlab = "Records found only by this database",
    xlim = c(0, xmax * 1.18), cex.names = 0.92, cex.axis = 0.90
  )
  text(mat, bp, labels = format(mat, big.mark = ","), pos = 4, offset = 0.35, cex = 0.76)
  legend("bottomright", legend = c("Deduplicated records", "Final included records"),
         fill = c("black", included_col), border = NA, bty = "n", cex = 0.92)
  par(op)
}
plot_unique_contribution("png")
plot_unique_contribution("pdf")

# Merge exact intersections by stable source-code combination. W08 is an
# included-only subset of W01, so missing W08 combinations are explicit zeros.
overlap_summary <- w01_int |>
  filter(degree >= 2L) |>
  transmute(
    intersection_key,
    degree,
    deduplicated_records = as.integer(records)
  ) |>
  left_join(
    w08_int |>
      filter(degree >= 2L) |>
      transmute(intersection_key, included_records = as.integer(records)),
    by = "intersection_key"
  ) |>
  mutate(
    included_records = ifelse(is.na(included_records), 0L, included_records),
    intersection = vapply(strsplit(intersection_key, "|", fixed = TRUE), function(codes) {
      labs <- unname(label_map[codes])
      if (any(is.na(labs))) stop("Unknown source code in source intersection snapshot", call. = FALSE)
      paste(labs, collapse = " | ")
    }, character(1))
  ) |>
  arrange(desc(deduplicated_records), desc(included_records), intersection)

if (!nrow(overlap_summary)) stop("No multi-database overlaps found", call. = FALSE)
if (any(overlap_summary$included_records > overlap_summary$deduplicated_records)) {
  stop("Included intersection count exceeds deduplicated count", call. = FALSE)
}
write.csv(overlap_summary, file.path(output_dir, "source_overlap_intersection_summary.csv"), row.names = FALSE)

plot_overlap_upset <- function(device = c("png", "pdf")) {
  device <- match.arg(device)
  included_col <- "#FF9D78"
  n_intersections <- nrow(overlap_summary)
  n_sources <- length(source_order)
  fig_w <- max(10.5, min(40, 6.5 + 0.22 * n_intersections))
  fig_h <- max(6.8, 4.7 + 0.28 * n_sources)
  if (n_intersections > 120L) warning(sprintf(
    "Overlap figure contains %d intersections; all are retained, but a future low-frequency combination rule may be needed.",
    n_intersections
  ))

  if (device == "png") {
    png(file.path(output_dir, "database_overlap_upset.png"), width = round(fig_w * 220), height = round(fig_h * 220), res = 220)
  } else {
    pdf(file.path(output_dir, "database_overlap_upset.pdf"), width = fig_w, height = fig_h, useDingbats = FALSE)
  }
  on.exit(dev.off(), add = TRUE)

  layout(matrix(c(1, 2), nrow = 2), heights = c(0.58, 0.42))
  par(mar = c(0.6, 8.8, 1.4, 1.0))
  mat <- rbind(overlap_summary$deduplicated_records, overlap_summary$included_records)
  ymax <- max(mat); if (!is.finite(ymax) || ymax <= 0) ymax <- 1
  ibp <- barplot(mat, beside = TRUE, col = c("black", included_col), border = NA,
                 axes = FALSE, ylim = c(0, ymax * 1.14), space = c(0.10, 0.58))
  axis(2, las = 1, cex.axis = 0.88)
  mtext("Records in exact database overlap", side = 2, line = 4.0, cex = 0.95)
  legend("topright", legend = c("Deduplicated records", "Final included records"),
         fill = c("black", included_col), border = NA, bty = "n", cex = 0.92)
  intersection_x <- colMeans(ibp)
  intersection_xlim <- range(ibp) + c(-0.7, 0.7)

  par(mar = c(3.6, 8.8, 0.2, 1.0))
  source_y <- rev(seq_along(source_order))
  plot(NA, xlim = intersection_xlim, ylim = c(0.45, length(source_order) + 0.55),
       xaxt = "n", yaxt = "n", xlab = "", ylab = "", bty = "n")
  axis(2, at = source_y, labels = source_order, las = 1, tick = FALSE, cex.axis = 0.88)
  for (yy in source_y) abline(h = yy, col = "grey92", lwd = 0.8)

  for (j in seq_len(nrow(overlap_summary))) {
    codes <- strsplit(overlap_summary$intersection_key[[j]], "|", fixed = TRUE)[[1]]
    active <- source_order_codes %in% codes
    points(rep(intersection_x[[j]], length(source_y)), source_y, pch = 16, col = "grey82", cex = 0.62)
    segments(intersection_x[[j]], min(source_y[active]), intersection_x[[j]], max(source_y[active]), lwd = 1.35, col = "black")
    points(rep(intersection_x[[j]], sum(active)), source_y[active], pch = 16, col = "black", cex = 0.82)
  }
  mtext(sprintf("%d observed multi-database intersections; singleton contributions are shown separately", n_intersections),
        side = 1, line = 2.2, cex = 0.82)
}
plot_overlap_upset("png")
plot_overlap_upset("pdf")

screening_summary <- tibble(
  source_code = source_order_codes,
  database = source_order,
  deduplicated_records = vapply(source_order_codes, function(code) {
    w01_sources$canonical_works[match(code, w01_sources$source_code)]
  }, integer(1)),
  included_records = vapply(source_order_codes, function(code) {
    if (code %in% names(w08_by_code)) w08_by_code[[code]] else 0L
  }, integer(1))
)
write.csv(screening_summary, file.path(output_dir, "source_contribution_screening_summary.csv"), row.names = FALSE)

report <- list(
  schema = "living-evidence-map-source-contribution-v3",
  status = "PASS",
  input_mode = "compact_workflow_reporting_snapshots",
  workflow01_run_id = as.character(w01_manifest$source_run_id),
  workflow08_run_id = as.character(w08_manifest$source_run_id),
  canonical_records = as.integer(w01_manifest$canonical_records),
  final_included_records = as.integer(w08_manifest$canonical_records),
  databases = source_order,
  overlap_intersections = nrow(overlap_summary),
  outputs = list(
    unique_figure_png = "database_unique_contribution.png",
    unique_figure_pdf = "database_unique_contribution.pdf",
    overlap_figure_png = "database_overlap_upset.png",
    overlap_figure_pdf = "database_overlap_upset.pdf",
    unique_summary_csv = "source_unique_contribution_summary.csv",
    overlap_intersection_summary_csv = "source_overlap_intersection_summary.csv",
    screening_summary_csv = "source_contribution_screening_summary.csv"
  )
)
writeLines(toJSON(report, auto_unbox = TRUE, pretty = TRUE, null = "null"),
           file.path(output_dir, "report.json"), useBytes = TRUE)

cat(sprintf(
  "PASS: source contribution figures from compact snapshots: W01=%s (%d records), W08=%s (%d records)\n",
  w01_manifest$source_run_id, w01_manifest$canonical_records,
  w08_manifest$source_run_id, w08_manifest$canonical_records
))
