#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(dplyr)
  library(tidyr)
  library(CiteSource)
})

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s", flag), call. = FALSE)
  args[[i + 1L]]
}

input_path <- arg("--input")
included_ids_path <- arg("--included-ids")
output_dir <- arg("--output-dir", "outputs/citesource_contribution")
if (is.null(input_path)) stop("Required: --input", call. = FALSE)
if (!file.exists(input_path)) stop(sprintf("Canonical JSONL not found: %s", input_path), call. = FALSE)

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

known_source_labels <- c(
  lens = "Lens",
  scopus = "Scopus",
  openalex = "OpenAlex",
  agricola = "AGRICOLA",
  wos = "Web of Science",
  cab = "CAB Abstracts",
  proquest = "ProQuest/PQD&T"
)
pretty_source_label <- function(code) {
  if (code %in% names(known_source_labels)) return(unname(known_source_labels[[code]]))
  tools::toTitleCase(gsub("[_-]+", " ", code))
}
observed_source_codes <- character()


included_ids <- character()
if (!is.null(included_ids_path)) {
  if (!file.exists(included_ids_path)) stop(sprintf("Included-ID file not found: %s", included_ids_path), call. = FALSE)
  included_ids <- readLines(included_ids_path, warn = FALSE, encoding = "UTF-8")
  included_ids <- included_ids[nzchar(trimws(included_ids))]
  if (anyDuplicated(included_ids)) stop("Included-ID file contains duplicate record_id values", call. = FALSE)
}

# Read only the provenance needed for this analysis. One canonical work becomes
# one CiteSource citation row; cite_source contains every database manifestation
# represented in that deduplicated work.
con <- file(input_path, "rt", encoding = "UTF-8")
on.exit(close(con), add = TRUE)

rows <- vector("list", 0L)
n <- 0L
repeat {
  line <- readLines(con, n = 1L, warn = FALSE)
  if (!length(line)) break
  if (!nzchar(trimws(line))) next

  rec <- fromJSON(line, simplifyVector = FALSE)
  rid <- as.character(rec$identity$record_id)
  mans <- rec$manifestations

  if (is.null(rid) || !nzchar(rid)) stop("Canonical record missing identity.record_id", call. = FALSE)
  if (is.null(mans) || !length(mans)) stop(sprintf("Canonical record %s has no manifestations", rid), call. = FALSE)

  src <- unique(vapply(mans, function(m) as.character(m$source), character(1)))
  if (any(!nzchar(src))) stop(sprintf("Blank source in canonical record %s", rid), call. = FALSE)
  observed_source_codes <- union(observed_source_codes, src)

  # Alphabetical display-label order makes outputs deterministic without
  # requiring a hard-coded source inventory.
  src <- src[order(vapply(src, pretty_source_label, character(1)))]

  n <- n + 1L
  rows[[n]] <- data.frame(
    duplicate_id = rid,
    cite_source = paste(vapply(src, pretty_source_label, character(1)), collapse = ", "),
    cite_label = "search",
    cite_string = "canonical",
    stringsAsFactors = FALSE
  )
}
close(con)
on.exit(NULL, add = FALSE)

canonical_sources <- bind_rows(rows)
if (!nrow(canonical_sources)) stop("No canonical records parsed", call. = FALSE)
if (anyDuplicated(canonical_sources$duplicate_id)) stop("Duplicate canonical record IDs", call. = FALSE)

source_codes <- sort(unique(observed_source_codes))
source_labels <- setNames(vapply(source_codes, pretty_source_label, character(1)), source_codes)
if (anyDuplicated(unname(source_labels))) {
  stop("Source display labels must be unique for CiteSource reporting", call. = FALSE)
}


# Machine-readable provenance matrix: one row per canonical work, one logical
# indicator per database, plus the final inclusion state when supplied.
source_presence <- canonical_sources |>
  transmute(
    record_id = duplicate_id,
    cite_source = as.character(cite_source)
  )

source_membership <- strsplit(source_presence$cite_source, ", ", fixed = TRUE)
for (lab in unname(source_labels)) {
  source_presence[[lab]] <- vapply(source_membership, function(x) lab %in% x, logical(1))
}
source_presence$included_final <- source_presence$record_id %in% included_ids

if (length(included_ids)) {
  missing_included <- setdiff(included_ids, source_presence$record_id)
  if (length(missing_included)) {
    stop(sprintf("%d final included record_id values are absent from the canonical provenance matrix", length(missing_included)), call. = FALSE)
  }
  if (sum(source_presence$included_final) != length(included_ids)) {
    stop("final included-record count does not match provenance matrix", call. = FALSE)
  }
}

write.csv(
  source_presence |> select(-cite_source),
  file.path(output_dir, "source_provenance_screening.csv"),
  row.names = FALSE
)

# Use CiteSource directly for source comparison and uniqueness classification.
comparison <- CiteSource::compare_sources(canonical_sources, comp_type = "sources")
classified <- CiteSource::count_unique(canonical_sources)

# Exact per-source contribution after deduplication.
source_summary <- classified |>
  distinct(duplicate_id, cite_source, type) |>
  group_by(cite_source) |>
  summarise(
    canonical_works = n_distinct(duplicate_id),
    unique_to_source = n_distinct(duplicate_id[type == "unique"]),
    shared_with_other_sources = n_distinct(duplicate_id[type == "duplicated"]),
    .groups = "drop"
  ) |>
  mutate(
    unique_share_of_source = unique_to_source / canonical_works,
    share_of_all_canonical_works = canonical_works / nrow(canonical_sources)
  ) |>
  arrange(desc(canonical_works))


screening_summary <- tibble(
  database = unname(source_labels),
  deduplicated_records = vapply(unname(source_labels), function(lab) sum(source_presence[[lab]]), integer(1)),
  included_records = vapply(unname(source_labels), function(lab) sum(source_presence[[lab]] & source_presence$included_final), integer(1))
) |>
  mutate(
    included_share_of_source = included_records / deduplicated_records,
    share_of_all_includes = if (length(included_ids)) included_records / length(included_ids) else NA_real_
  )

write.csv(
  screening_summary,
  file.path(output_dir, "source_contribution_screening_summary.csv"),
  row.names = FALSE
)


# Unique-source contribution figure. A canonical work is "unique" when it
# has manifestations from exactly one database. The paired bars show how many
# such records exist before screening and how many remain in the definitive
# final included corpus.
source_order <- screening_summary |>
  arrange(desc(deduplicated_records), database) |>
  pull(database)

presence_matrix_all <- as.matrix(source_presence[, source_order, drop = FALSE])
storage.mode(presence_matrix_all) <- "logical"
source_degree_all <- rowSums(presence_matrix_all)

unique_summary <- tibble(
  database = source_order,
  unique_deduplicated_records = vapply(source_order, function(lab) {
    sum(source_presence[[lab]] & source_degree_all == 1L)
  }, integer(1)),
  unique_included_records = vapply(source_order, function(lab) {
    sum(source_presence[[lab]] & source_degree_all == 1L & source_presence$included_final)
  }, integer(1))
) |>
  arrange(desc(unique_deduplicated_records), database)

write.csv(
  unique_summary,
  file.path(output_dir, "source_unique_contribution_summary.csv"),
  row.names = FALSE
)

plot_unique_contribution <- function(device = c("png", "pdf")) {
  device <- match.arg(device)
  included_col <- "#6B6B2A"
  n_sources <- nrow(unique_summary)
  fig_h <- max(5.6, 2.4 + 0.42 * n_sources)

  if (device == "png") {
    png(
      file.path(output_dir, "database_unique_contribution.png"),
      width = 2200,
      height = round(fig_h * 220),
      res = 220
    )
  } else {
    pdf(
      file.path(output_dir, "database_unique_contribution.pdf"),
      width = 10.0,
      height = fig_h,
      useDingbats = FALSE
    )
  }
  on.exit(dev.off(), add = TRUE)

  ord <- rev(seq_len(n_sources))
  mat <- rbind(
    unique_summary$unique_deduplicated_records[ord],
    unique_summary$unique_included_records[ord]
  )
  labs <- unique_summary$database[ord]
  xmax <- max(mat)
  if (!is.finite(xmax) || xmax <= 0) xmax <- 1

  op <- par(mar = c(4.7, 9.2, 1.2, 1.0), xpd = NA)
  bp <- barplot(
    mat,
    beside = TRUE,
    horiz = TRUE,
    names.arg = labs,
    las = 1,
    col = c("black", included_col),
    border = NA,
    xlab = "Records found only by this database",
    xlim = c(0, xmax * 1.18),
    cex.names = 0.92,
    cex.axis = 0.90
  )
  text(
    mat,
    bp,
    labels = format(mat, big.mark = ","),
    pos = 4,
    offset = 0.35,
    cex = 0.76
  )
  legend(
    "bottomright",
    legend = c("Deduplicated records", "Final included records"),
    fill = c("black", included_col),
    border = NA,
    bty = "n",
    cex = 0.92
  )
  par(op)
}

plot_unique_contribution("png")
plot_unique_contribution("pdf")

# Validate summary against the logical source matrix produced by CiteSource.
matrix_counts <- comparison |>
  select(starts_with("source__")) |>
  summarise(across(everything(), sum)) |>
  pivot_longer(everything(), names_to = "source", values_to = "canonical_works") |>
  mutate(source = sub("^source__", "", source))

check <- left_join(
  source_summary |> select(cite_source, canonical_works),
  matrix_counts,
  by = c("cite_source" = "source"),
  suffix = c("_summary", "_matrix")
)
stopifnot(nrow(check) == length(source_labels))
stopifnot(all(check$canonical_works_summary == check$canonical_works_matrix))

write.csv(
  source_summary,
  file.path(output_dir, "source_contribution_summary.csv"),
  row.names = FALSE
)
write.csv(
  comparison,
  file.path(output_dir, "source_overlap_matrix.csv"),
  row.names = FALSE
)

# Build exact source-intersection counts for both analysis stages.
# Each record contributes to exactly one intersection combination.
source_order <- screening_summary |>
  arrange(desc(deduplicated_records)) |>
  pull(database)

presence_matrix <- as.matrix(source_presence[, source_order, drop = FALSE])
storage.mode(presence_matrix) <- "logical"

intersection_key <- apply(
  presence_matrix,
  1,
  function(z) paste(source_order[z], collapse = " | ")
)
intersection_degree <- rowSums(presence_matrix)

intersection_summary <- tibble(
  record_id = source_presence$record_id,
  intersection = intersection_key,
  degree = intersection_degree,
  included_final = source_presence$included_final
) |>
  group_by(intersection, degree) |>
  summarise(
    deduplicated_records = n(),
    included_records = sum(included_final),
    .groups = "drop"
  ) |>
  arrange(desc(degree), desc(deduplicated_records), intersection)

if (sum(intersection_summary$deduplicated_records) != nrow(source_presence)) {
  stop("Exact intersection counts do not sum to all canonical records", call. = FALSE)
}
if (length(included_ids) && sum(intersection_summary$included_records) != length(included_ids)) {
  stop("Exact included intersection counts do not sum to final included records", call. = FALSE)
}

write.csv(
  intersection_summary,
  file.path(output_dir, "source_intersection_screening_summary.csv"),
  row.names = FALSE
)

# Standalone overlap-only UpSet-style figure. Singleton intersections are
# deliberately excluded because unique-source contribution is shown separately.
# Every database remains as a matrix row, including databases that contribute
# few shared records. All observed multi-database intersections are retained.
overlap_summary <- intersection_summary |>
  filter(degree >= 2L) |>
  arrange(desc(deduplicated_records), desc(included_records), intersection)

if (!nrow(overlap_summary)) {
  stop("No multi-database overlaps were found for the current canonical corpus", call. = FALSE)
}

write.csv(
  overlap_summary,
  file.path(output_dir, "source_overlap_intersection_summary.csv"),
  row.names = FALSE
)

plot_overlap_upset <- function(device = c("png", "pdf")) {
  device <- match.arg(device)
  included_col <- "#6B6B2A"
  n_intersections <- nrow(overlap_summary)
  n_sources <- length(source_order)

  # Width expands with the number of observed intersections. Nothing is
  # dropped or aggregated here; if future database expansion makes this
  # impractical, aggregation must be an explicit reviewed reporting rule.
  fig_w <- max(10.5, min(40, 6.5 + 0.22 * n_intersections))
  fig_h <- max(6.8, 4.7 + 0.28 * n_sources)
  if (n_intersections > 120L) {
    warning(
      sprintf(
        "Overlap figure contains %d intersections; all are retained, but a future low-frequency combination rule may be needed.",
        n_intersections
      )
    )
  }

  if (device == "png") {
    png(
      file.path(output_dir, "database_overlap_upset.png"),
      width = round(fig_w * 220),
      height = round(fig_h * 220),
      res = 220
    )
  } else {
    pdf(
      file.path(output_dir, "database_overlap_upset.pdf"),
      width = fig_w,
      height = fig_h,
      useDingbats = FALSE
    )
  }
  on.exit(dev.off(), add = TRUE)

  layout(matrix(c(1, 2), nrow = 2), heights = c(0.58, 0.42))

  # Top: exact multi-database intersection sizes at the two reporting stages.
  par(mar = c(0.6, 8.8, 1.4, 1.0))
  intersection_mat <- rbind(
    overlap_summary$deduplicated_records,
    overlap_summary$included_records
  )
  ymax <- max(intersection_mat)
  if (!is.finite(ymax) || ymax <= 0) ymax <- 1

  ibp <- barplot(
    intersection_mat,
    beside = TRUE,
    col = c("black", included_col),
    border = NA,
    axes = FALSE,
    ylim = c(0, ymax * 1.14),
    space = c(0.10, 0.58)
  )
  axis(2, las = 1, cex.axis = 0.88)
  mtext("Records in exact database overlap", side = 2, line = 4.0, cex = 0.95)
  legend(
    "topright",
    legend = c("Deduplicated records", "Final included records"),
    fill = c("black", included_col),
    border = NA,
    bty = "n",
    cex = 0.92
  )
  intersection_x <- colMeans(ibp)
  intersection_xlim <- range(ibp) + c(-0.7, 0.7)

  # Bottom: database-membership matrix. All databases are retained as rows.
  par(mar = c(3.6, 8.8, 0.2, 1.0))
  source_y <- rev(seq_along(source_order))
  source_ylim <- c(0.45, length(source_order) + 0.55)

  plot(
    NA,
    xlim = intersection_xlim,
    ylim = source_ylim,
    xaxt = "n",
    yaxt = "n",
    xlab = "",
    ylab = "",
    bty = "n"
  )
  axis(
    2,
    at = source_y,
    labels = source_order,
    las = 1,
    tick = FALSE,
    cex.axis = 0.88
  )

  for (yy in source_y) {
    abline(h = yy, col = "grey92", lwd = 0.8)
  }

  for (j in seq_len(nrow(overlap_summary))) {
    members <- strsplit(overlap_summary$intersection[[j]], " | ", fixed = TRUE)[[1]]
    active <- source_order %in% members

    points(
      rep(intersection_x[[j]], length(source_y)),
      source_y,
      pch = 16,
      col = "grey82",
      cex = 0.62
    )

    segments(
      intersection_x[[j]],
      min(source_y[active]),
      intersection_x[[j]],
      max(source_y[active]),
      lwd = 1.35,
      col = "black"
    )

    points(
      rep(intersection_x[[j]], sum(active)),
      source_y[active],
      pch = 16,
      col = "black",
      cex = 0.82
    )
  }

  mtext(
    sprintf("%d observed multi-database intersections; singleton contributions are shown separately", n_intersections),
    side = 1,
    line = 2.2,
    cex = 0.82
  )
}

plot_overlap_upset("png")
plot_overlap_upset("pdf")

report <- list(
  schema = "living-evidence-map-citesource-contribution-v2",
  status = "PASS",
  canonical_records = nrow(canonical_sources),
  final_included_records = if (length(included_ids)) length(included_ids) else NULL,
  databases = unname(source_labels),
  overlap_intersections = nrow(overlap_summary),
  interpretation = list(
    source_set_size = "Number of deduplicated canonical works with at least one manifestation from the database",
    unique_intersection = "Canonical works found by one database only",
    shared_intersection = "Canonical works represented in two or more databases",
    unique_figure = "Unique single-database contribution before screening and in the definitive final included corpus",
    overlap_figure = "Exact multi-database intersections only; singleton intersections are excluded because they are reported in the unique-contribution figure"
  ),
  outputs = list(
    unique_figure_png = "database_unique_contribution.png",
    unique_figure_pdf = "database_unique_contribution.pdf",
    overlap_figure_png = "database_overlap_upset.png",
    overlap_figure_pdf = "database_overlap_upset.pdf",
    summary_csv = "source_contribution_summary.csv",
    unique_summary_csv = "source_unique_contribution_summary.csv",
    overlap_matrix_csv = "source_overlap_matrix.csv",
    provenance_screening_csv = "source_provenance_screening.csv",
    screening_summary_csv = "source_contribution_screening_summary.csv",
    intersection_screening_summary_csv = "source_intersection_screening_summary.csv",
    overlap_intersection_summary_csv = "source_overlap_intersection_summary.csv"
  )
)
writeLines(
  toJSON(report, auto_unbox = TRUE, pretty = TRUE, null = "null"),
  file.path(output_dir, "report.json"),
  useBytes = TRUE
)

cat(sprintf("PASS: CiteSource contribution analysis for %d canonical works\n", nrow(canonical_sources)))
print(source_summary)
if (length(included_ids)) print(screening_summary)
