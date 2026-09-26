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

source_labels <- c(
  lens = "Lens",
  scopus = "Scopus",
  openalex = "OpenAlex",
  agricola = "AGRICOLA",
  wos = "Web of Science"
)


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
  unknown <- setdiff(src, names(source_labels))
  if (length(unknown)) stop(sprintf("Unknown source(s) in %s: %s", rid, paste(unknown, collapse = ", ")), call. = FALSE)

  # Fixed source order makes outputs deterministic.
  src <- names(source_labels)[names(source_labels) %in% src]

  n <- n + 1L
  rows[[n]] <- data.frame(
    duplicate_id = rid,
    cite_source = paste(unname(source_labels[src]), collapse = ", "),
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


# Machine-readable provenance matrix: one row per canonical work, one logical
# indicator per database, plus the Workflow 04 inclusion state when supplied.
source_presence <- canonical_sources |>
  transmute(
    record_id = duplicate_id,
    cite_source = as.character(cite_source)
  )

source_membership <- strsplit(source_presence$cite_source, ", ", fixed = TRUE)
for (lab in unname(source_labels)) {
  source_presence[[lab]] <- vapply(source_membership, function(x) lab %in% x, logical(1))
}
source_presence$included_w04 <- source_presence$record_id %in% included_ids

if (length(included_ids)) {
  missing_included <- setdiff(included_ids, source_presence$record_id)
  if (length(missing_included)) {
    stop(sprintf("%d Workflow 04 included record_id values are absent from the canonical provenance matrix", length(missing_included)), call. = FALSE)
  }
  if (sum(source_presence$included_w04) != length(included_ids)) {
    stop("Workflow 04 included-record count does not match provenance matrix", call. = FALSE)
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
  included_records = vapply(unname(source_labels), function(lab) sum(source_presence[[lab]] & source_presence$included_w04), integer(1))
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


# Paired source-contribution figure: black = all deduplicated canonical works;
# olive = Workflow 04 included works. This is separate from, and complementary
# to, the source-intersection UpSet figure below.
bar_long <- screening_summary |>
  select(database, deduplicated_records, included_records) |>
  pivot_longer(
    cols = c(deduplicated_records, included_records),
    names_to = "stage",
    values_to = "records"
  ) |>
  mutate(
    stage = factor(
      stage,
      levels = c("deduplicated_records", "included_records"),
      labels = c("Deduplicated records", "Included records")
    ),
    database = factor(
      database,
      levels = screening_summary$database[order(screening_summary$deduplicated_records, decreasing = TRUE)]
    )
  )

png(
  file.path(output_dir, "database_contribution_deduplicated_vs_included.png"),
  width = 2200, height = 1400, res = 220
)
op <- par(mar = c(6.5, 5.5, 2.0, 1.0), xpd = FALSE)
mat <- rbind(
  screening_summary$deduplicated_records,
  screening_summary$included_records
)
ord <- order(screening_summary$deduplicated_records, decreasing = TRUE)
mat <- mat[, ord, drop = FALSE]
labs <- screening_summary$database[ord]
bp <- barplot(
  mat,
  beside = TRUE,
  names.arg = labs,
  las = 2,
  col = c("black", "#6B6B2A"),
  border = NA,
  ylab = "Canonical records",
  ylim = c(0, max(mat) * 1.12),
  cex.names = 0.95
)
text(bp, mat, labels = format(mat, big.mark = ","), pos = 3, cex = 0.75)
legend(
  "topright",
  legend = c("Deduplicated records", "Included records"),
  fill = c("black", "#6B6B2A"),
  border = NA,
  bty = "n"
)
par(op)
dev.off()

pdf(
  file.path(output_dir, "database_contribution_deduplicated_vs_included.pdf"),
  width = 10.5, height = 7,
  useDingbats = FALSE
)
op <- par(mar = c(6.5, 5.5, 2.0, 1.0), xpd = FALSE)
bp <- barplot(
  mat,
  beside = TRUE,
  names.arg = labs,
  las = 2,
  col = c("black", "#6B6B2A"),
  border = NA,
  ylab = "Canonical records",
  ylim = c(0, max(mat) * 1.12),
  cex.names = 0.95
)
text(bp, mat, labels = format(mat, big.mark = ","), pos = 3, cex = 0.75)
legend(
  "topright",
  legend = c("Deduplicated records", "Included records"),
  fill = c("black", "#6B6B2A"),
  border = NA,
  bty = "n"
)
par(op)
dev.off()

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
  included_w04 = source_presence$included_w04
) |>
  group_by(intersection, degree) |>
  summarise(
    deduplicated_records = n(),
    included_records = sum(included_w04),
    .groups = "drop"
  ) |>
  arrange(desc(deduplicated_records), desc(degree), intersection)

if (sum(intersection_summary$deduplicated_records) != nrow(source_presence)) {
  stop("Exact intersection counts do not sum to all canonical records", call. = FALSE)
}
if (length(included_ids) && sum(intersection_summary$included_records) != length(included_ids)) {
  stop("Exact included intersection counts do not sum to Workflow 04 included records", call. = FALSE)
}

write.csv(
  intersection_summary,
  file.path(output_dir, "source_intersection_screening_summary.csv"),
  row.names = FALSE
)

# One integrated paired UpSet-style figure:
#   left bars = source totals at both stages;
#   top bars = exact source intersections at both stages;
#   lower-right matrix = database combination defining each intersection.
plot_paired_upset <- function(device = c("png", "pdf")) {
  device <- match.arg(device)
  olive <- "#6B6B2A"

  if (device == "png") {
    png(
      file.path(output_dir, "database_contribution_upset.png"),
      width = 3000, height = 1900, res = 220
    )
  } else {
    pdf(
      file.path(output_dir, "database_contribution_upset.pdf"),
      width = 13.6, height = 8.6,
      useDingbats = FALSE
    )
  }
  on.exit(dev.off(), add = TRUE)

  layout(
    matrix(c(0, 1,
             2, 3), nrow = 2, byrow = TRUE),
    widths = c(0.30, 0.70),
    heights = c(0.59, 0.41)
  )

  # Top-right: paired exact-intersection bars.
  par(mar = c(0.8, 5.2, 1.6, 1.0))
  intersection_mat <- rbind(
    intersection_summary$deduplicated_records,
    intersection_summary$included_records
  )
  ibp <- barplot(
    intersection_mat,
    beside = TRUE,
    col = c("black", olive),
    border = NA,
    axes = FALSE,
    ylim = c(0, max(intersection_mat) * 1.12),
    space = c(0.10, 0.65)
  )
  axis(2, las = 1, cex.axis = 0.85)
  mtext("Canonical works in source intersection", side = 2, line = 4.0, cex = 0.9)
  legend(
    "topright",
    legend = c("Deduplicated records", "Included records"),
    fill = c("black", olive),
    border = NA,
    bty = "n",
    cex = 0.82
  )
  intersection_x <- colMeans(ibp)
  intersection_xlim <- range(ibp) + c(-0.8, 0.8)

  # Bottom-left: paired source totals.
  par(mar = c(4.4, 8.3, 0.4, 0.8))
  source_rows <- screening_summary |>
    slice(match(source_order, database))
  source_mat <- rbind(
    source_rows$deduplicated_records,
    source_rows$included_records
  )
  sbp <- barplot(
    source_mat,
    beside = TRUE,
    horiz = TRUE,
    names.arg = source_order,
    las = 1,
    col = c("black", olive),
    border = NA,
    axes = FALSE,
    xlim = c(max(source_mat) * 1.08, 0),
    space = c(0.10, 0.55),
    cex.names = 0.87
  )
  axis(1, las = 1, cex.axis = 0.80)
  mtext("Canonical works contributed", side = 1, line = 3.0, cex = 0.88)
  source_y <- colMeans(sbp)
  source_ylim <- range(sbp) + c(-0.7, 0.7)

  # Bottom-right: intersection membership matrix aligned to top bars.
  par(mar = c(4.4, 5.2, 0.4, 1.0))
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

  # Alternating row guides improve readability while retaining the UpSet form.
  for (i in seq_along(source_y)) {
    abline(h = source_y[[i]], col = "grey92", lwd = 0.8)
  }

  for (j in seq_len(nrow(intersection_summary))) {
    members <- strsplit(intersection_summary$intersection[[j]], " | ", fixed = TRUE)[[1]]
    active <- source_order %in% members

    points(
      rep(intersection_x[[j]], length(source_y)),
      source_y,
      pch = 16,
      col = "grey82",
      cex = 0.75
    )

    if (sum(active) > 1L) {
      segments(
        intersection_x[[j]],
        min(source_y[active]),
        intersection_x[[j]],
        max(source_y[active]),
        lwd = 1.5,
        col = "black"
      )
    }

    points(
      rep(intersection_x[[j]], sum(active)),
      source_y[active],
      pch = 16,
      col = "black",
      cex = 0.92
    )
  }
}

plot_paired_upset("png")
plot_paired_upset("pdf")

report <- list(
  schema = "living-evidence-map-citesource-contribution-v1",
  status = "PASS",
  canonical_records = nrow(canonical_sources),
  workflow04_included_records = if (length(included_ids)) length(included_ids) else NULL,
  databases = unname(source_labels),
  interpretation = list(
    source_set_size = "Number of deduplicated canonical works with at least one manifestation from the database",
    unique_intersection = "Canonical works found by one database only",
    shared_intersection = "Canonical works represented in two or more databases"
  ),
  outputs = list(
    figure_png = "database_contribution_upset.png",
    figure_pdf = "database_contribution_upset.pdf",
    summary_csv = "source_contribution_summary.csv",
    overlap_matrix_csv = "source_overlap_matrix.csv",
    provenance_screening_csv = "source_provenance_screening.csv",
    screening_summary_csv = "source_contribution_screening_summary.csv",
    intersection_screening_summary_csv = "source_intersection_screening_summary.csv",
    paired_bar_png = "database_contribution_deduplicated_vs_included.png",
    paired_bar_pdf = "database_contribution_deduplicated_vs_included.pdf"
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
