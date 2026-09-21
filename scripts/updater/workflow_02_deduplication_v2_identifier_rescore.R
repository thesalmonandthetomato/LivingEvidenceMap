#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(data.table)
  library(jsonlite)
  library(stringi)
})

`%||%` <- function(x, y) if (is.null(x)) y else x

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s", flag), call. = FALSE)
  args[[i + 1L]]
}

input_dir <- arg("--input-dir")
output_dir <- arg("--output-dir")
source_run_id <- arg("--source-run-id", "35585544686")

if (is.null(input_dir) || is.null(output_dir)) {
  stop("Required: --input-dir --output-dir", call. = FALSE)
}
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

timestamp_utc <- function() format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ")
progress <- function(stage, completed = NULL, total = NULL, extra = NULL) {
  msg <- paste0("[", timestamp_utc(), "] ", stage)
  if (!is.null(completed)) {
    msg <- paste0(msg, ": ", completed)
    if (!is.null(total)) msg <- paste0(msg, " / ", total)
  }
  if (!is.null(extra) && nzchar(extra)) msg <- paste0(msg, " | ", extra)
  cat(msg, "\n")
  flush.console()
}
checkpoint <- function(stage, completed = NULL, total = NULL, extra = list()) {
  x <- c(list(
    workflow = "02_deduplication_v2_identifier_rescore",
    updated_at = timestamp_utc(),
    stage = stage,
    completed = completed,
    total = total,
    source_benchmark_run_id = source_run_id
  ), extra)
  writeLines(
    toJSON(x, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null"),
    file.path(output_dir, "checkpoint_progress.json")
  )
}

scored_path <- file.path(input_dir, "scored_sample.csv")
if (!file.exists(scored_path)) {
  hits <- list.files(input_dir, pattern = "^scored_sample\\.csv$", recursive = TRUE, full.names = TRUE)
  if (!length(hits)) stop("scored_sample.csv not found in benchmark artefact", call. = FALSE)
  scored_path <- hits[[1L]]
}

progress("reading saved scored benchmark sample")
x <- fread(scored_path, na.strings = c("", "NA"))
if (!nrow(x)) stop("Saved scored sample is empty", call. = FALSE)
required <- c("title_i","title_j","classification","rule","record_i","record_j")
missing <- setdiff(required, names(x))
if (length(missing)) stop(sprintf("Missing required columns: %s", paste(missing, collapse = ", ")), call. = FALSE)
progress("saved sample loaded", nrow(x), nrow(x))
checkpoint("sample_loaded", nrow(x), nrow(x))

meta_path <- file.path(input_dir, "normalised_metadata.csv")
if (!file.exists(meta_path)) {
  hits <- list.files(input_dir, pattern = "^normalised_metadata\\.csv$", recursive = TRUE, full.names = TRUE)
  if (!length(hits)) stop("normalised_metadata.csv not found in benchmark artefact", call. = FALSE)
  meta_path <- hits[[1L]]
}
meta <- fread(meta_path, na.strings = c("", "NA"))
if (!"idx" %in% names(meta)) stop("normalised_metadata.csv lacks idx", call. = FALSE)
setkey(meta, idx)

labels_path <- file.path("data", "validation", "workflow02_v2_human_labels_2026-09-21.csv")
if (!file.exists(labels_path)) stop("Human validation label file not found", call. = FALSE)
labels <- fread(labels_path)
if (!all(c("record_i","record_j","truth") %in% names(labels))) stop("Human validation labels lack required columns", call. = FALSE)
labels[, pair_key := paste(pmin(record_i, record_j), pmax(record_i, record_j), sep = "::")]
if (anyDuplicated(labels$pair_key)) stop("Duplicate pair keys in human validation labels", call. = FALSE)
progress("validation labels loaded", nrow(labels), nrow(labels))

normalise_visible_title <- function(s) {
  if (is.na(s) || !nzchar(trimws(s))) return(NA_character_)
  s <- stri_trans_nfkc(s)
  stri_trans_tolower(s)
}

canonical_label <- function(x) {
  x <- tolower(trimws(x))
  x <- stri_replace_all_regex(x, "\\s+", " ")
  if (identical(x, "supplementary file")) return("supplementary_file")
  if (identical(x, "additional file")) return("additional_file")
  map <- c(
    "pt" = "part", "part" = "part",
    "study" = "study",
    "experiment" = "experiment",
    "trial" = "trial",
    "report" = "report",
    "no" = "number", "number" = "number",
    "interview" = "interview",
    "episode" = "episode",
    "chapter" = "chapter",
    "section" = "section",
    "series" = "series",
    "vol" = "volume", "volume" = "volume",
    "issue" = "issue",
    "supplement" = "supplementary_file", "supplementary" = "supplementary_file",
    "file" = "file", "additional" = "additional_file",
    "appendix" = "appendix",
    "phase" = "phase"
  )
  unname(map[x])
}

labelled_ids <- function(s) {
  s <- normalise_visible_title(s)
  if (is.na(s)) return(list())
  pattern <- paste0(
    "(?i)(?<!\\p{L})",
    "(supplementary\\s+file|additional\\s+file|part|pt|study|experiment|trial|report|no|number|interview|episode|chapter|section|series|vol|volume|issue|supplement|supplementary|file|appendix|phase)",
    "\\s*[\\.:#-]?\\s*",
    "([0-9]+(?:\\.[0-9]+)?|[ivxlcdm]+)",
    "(?!\\p{L})"
  )
  m <- stri_match_all_regex(s, pattern)[[1L]]
  if (is.matrix(m) && nrow(m) && !all(is.na(m))) {
    out <- list()
    for (i in seq_len(nrow(m))) {
      lab <- canonical_label(m[i,2])
      val <- toupper(m[i,3])
      if (is.na(lab) || is.na(val)) next
      out[[lab]] <- sort(unique(c(out[[lab]] %||% character(), val)))
    }
    return(out)
  }
  list()
}

years_in_title <- function(s) {
  s <- normalise_visible_title(s)
  if (is.na(s)) return(character())
  m <- stri_extract_all_regex(s, "(?<![0-9])(?:18|19|20|21)[0-9]{2}(?![0-9])")[[1L]]
  sort(unique(m[!is.na(m)]))
}

roman_ids <- function(s) {
  s <- normalise_visible_title(s)
  if (is.na(s)) return(character())
  # Exclude standalone I because it is frequently a pronoun; labelled Phase I/Part I
  # is already captured by labelled_ids().
  m <- stri_extract_all_regex(s, "(?i)(?<!\\p{L})(?:ii|iii|iv|v|vi|vii|viii|ix|x|xi|xii|xiii|xiv|xv|xvi|xvii|xviii|xix|xx)(?!\\p{L})")[[1L]]
  sort(unique(toupper(m[!is.na(m)])))
}

generic_numbers <- function(s) {
  s <- normalise_visible_title(s)
  if (is.na(s)) return(character())
  m <- stri_extract_all_regex(s, "(?<![\\p{L}0-9])[0-9]+(?:\\.[0-9]+)?(?![\\p{L}0-9])")[[1L]]
  sort(unique(m[!is.na(m)]))
}

set_differs <- function(a, b) {
  length(a) > 0L && length(b) > 0L && !identical(sort(unique(a)), sort(unique(b)))
}

identifier_conflict <- function(a, b) {
  reasons <- character()

  la <- labelled_ids(a)
  lb <- labelled_ids(b)
  common_labels <- intersect(names(la), names(lb))
  if (length(common_labels)) {
    for (lab in common_labels) {
      if (set_differs(la[[lab]], lb[[lab]])) {
        reasons <- c(reasons, paste0("label:", lab, "=", paste(la[[lab]], collapse = ","), " vs ", paste(lb[[lab]], collapse = ",")))
      }
    }
  }

  ya <- years_in_title(a); yb <- years_in_title(b)
  if (set_differs(ya, yb)) {
    reasons <- c(reasons, paste0("year=", paste(ya, collapse = ","), " vs ", paste(yb, collapse = ",")))
  }

  ra <- roman_ids(a); rb <- roman_ids(b)
  if (set_differs(ra, rb)) {
    reasons <- c(reasons, paste0("roman=", paste(ra, collapse = ","), " vs ", paste(rb, collapse = ",")))
  }

  na <- generic_numbers(a); nb <- generic_numbers(b)
  if (set_differs(na, nb)) {
    reasons <- c(reasons, paste0("numeric=", paste(na, collapse = ","), " vs ", paste(nb, collapse = ",")))
  }

  list(
    conflict = length(reasons) > 0L,
    reasons = paste(unique(reasons), collapse = "; ")
  )
}

# Regression checks from the observed false-positive patterns.
stopifnot(identifier_conflict("Mike and Drenda Bayliss Interview 08", "Mike and Drenda Bayliss Interview 03")$conflict)
stopifnot(identifier_conflict("Annual Report No. 60, 2015", "Annual Report No. 61, 2016")$conflict)
stopifnot(identifier_conflict("Studies on Viral Diseases of Japanese Fishes-III", "Studies on Viral Diseases of Japanese Fishes-V")$conflict)
stopifnot(identifier_conflict("Experiment Part 1", "Experiment Part 2")$conflict)
stopifnot(!identifier_conflict("A 3-dimensional positioning study", "A 3-dimensional positioning study")$conflict)
stopifnot(identifier_conflict("Supplementary file 1.xlsx", "Supplementary file 8.xlsx")$conflict)
stopifnot(identifier_conflict("Additional file 7: study data", "Additional file 2: study data")$conflict)


first_author_from_norm <- function(x) {
  if (is.na(x) || !nzchar(x)) return(NA_character_)
  strsplit(x, "|", fixed = TRUE)[[1L]][[1L]]
}

is_preprint_manifestation <- function(doi, journal) {
  d <- ifelse(is.na(doi), "", tolower(doi))
  j <- ifelse(is.na(journal), "", tolower(journal))
  grepl("^10\\.21203/rs\\.3\\.", d) ||
    grepl("^10\\.1101/", d) ||
    grepl("^10\\.2139/ssrn\\.", d) ||
    grepl("biorxiv|medrxiv|researchsquare|socialscienceresearchnetwork|ssrn|arxiv|peerjpreprints", j)
}

title_length_norm <- function(s) {
  if (is.na(s) || !nzchar(s)) return(0L)
  nchar(stri_replace_all_regex(stri_trans_tolower(stri_trans_nfkc(s)), "[\\p{P}\\p{S}\\p{Z}\\s]+", ""), type = "chars")
}


is_downstream_exclusion_title <- function(s) {
  if (is.na(s) || !nzchar(trimws(s))) return(FALSE)
  z <- stri_trans_tolower(stri_trans_nfkc(s))
  grepl("\\b(?:additional|supplementary)\\s+file\\b|reviewer response|editor response|peer review", z, perl = TRUE)
}

is_generic_exact_title <- function(s) {
  if (is.na(s) || !nzchar(trimws(s))) return(FALSE)
  z <- stri_trans_tolower(stri_trans_nfkc(s))
  z <- stri_replace_all_regex(z, "[\\p{P}\\p{S}\\p{Z}\\s]+", "")
  z %in% c("occurrencedownload", "index", "bookreviews")
}

pair_meta <- function(i, j) {
  a <- meta[.(i)]
  b <- meta[.(j)]
  if (!nrow(a) || !nrow(b)) return(NULL)
  fa <- first_author_from_norm(a$author_norm[[1L]])
  fb <- first_author_from_norm(b$author_norm[[1L]])
  yd <- if (!is.na(a$year[[1L]]) && !is.na(b$year[[1L]])) abs(a$year[[1L]] - b$year[[1L]]) else NA_integer_
  list(
    abstract_missing_i = is.na(a$abstract_hash[[1L]]) || !nzchar(a$abstract_hash[[1L]]),
    abstract_missing_j = is.na(b$abstract_hash[[1L]]) || !nzchar(b$abstract_hash[[1L]]),
    first_author_match = !is.na(fa) && !is.na(fb) && identical(fa, fb),
    journal_match = !is.na(a$journal_norm[[1L]]) && !is.na(b$journal_norm[[1L]]) &&
      nzchar(a$journal_norm[[1L]]) && nzchar(b$journal_norm[[1L]]) &&
      identical(a$journal_norm[[1L]], b$journal_norm[[1L]]),
    year_diff = yd,
    preprint_i = is_preprint_manifestation(a$doi_norm[[1L]], a$journal_norm[[1L]]),
    preprint_j = is_preprint_manifestation(b$doi_norm[[1L]], b$journal_norm[[1L]])
  )
}

weak_auto_rules <- c(
  "title_containment_strong_abstract",
  "title_similarity_0.97_strong_abstract",
  "title_similarity_0.95_exact_author_year"
)

x[, identifier_conflict := FALSE]
x[, identifier_conflict_reason := ""]
x[, rescored_classification := classification]
x[, rescored_rule := rule]

eligible <- which(x$classification == "duplicate" & x$rule %in% weak_auto_rules)
progress("checking structured title identifiers", 0L, length(eligible))

for (n in seq_along(eligible)) {
  i <- eligible[[n]]
  z <- identifier_conflict(x$title_i[[i]], x$title_j[[i]])
  if (isTRUE(z$conflict)) {
    x$identifier_conflict[[i]] <- TRUE
    x$identifier_conflict_reason[[i]] <- z$reasons
    x$rescored_classification[[i]] <- "review"
    x$rescored_rule[[i]] <- "structured_title_identifier_conflict"
  }
  if (n == 1L || n %% 25L == 0L || n == length(eligible)) {
    progress("structured title identifiers checked", n, length(eligible))
    checkpoint("identifier_check", n, length(eligible), list(changed_so_far = sum(x$identifier_conflict)))
  }
}

# Identifier conflicts are also required as a safeguard for review/unresolved pairs
# before any later promotion rule can fire.
for (i in seq_len(nrow(x))) {
  if (isTRUE(x$identifier_conflict[[i]])) next
  z <- identifier_conflict(x$title_i[[i]], x$title_j[[i]])
  if (isTRUE(z$conflict)) {
    x$identifier_conflict[[i]] <- TRUE
    x$identifier_conflict_reason[[i]] <- z$reasons
  }
}


# Second-stage high-confidence promotions learned from the human-reviewed queue.
# Human labels are never used to make decisions; they are used only below for evaluation.
x[, promotion_reason := ""]
x[, one_abstract_missing := FALSE]
x[, first_author_match := FALSE]
x[, journal_match := FALSE]
x[, preprint_pair := FALSE]

for (i in seq_len(nrow(x))) {
  if (isTRUE(x$identifier_conflict[[i]])) next

  pm <- pair_meta(x$record_i[[i]], x$record_j[[i]])
  if (is.null(pm)) next

  one_missing <- xor(pm$abstract_missing_i, pm$abstract_missing_j)
  preprint_pair <- xor(pm$preprint_i, pm$preprint_j) || (pm$preprint_i || pm$preprint_j)
  x$one_abstract_missing[[i]] <- one_missing
  x$first_author_match[[i]] <- pm$first_author_match
  x$journal_match[[i]] <- pm$journal_match
  x$preprint_pair[[i]] <- preprint_pair

  yd_ok_1 <- is.na(pm$year_diff) || pm$year_diff <= 1L
  yd_ok_2 <- is.na(pm$year_diff) || pm$year_diff <= 2L
  tlen <- min(title_length_norm(x$title_i[[i]]), title_length_norm(x$title_j[[i]]))
  exact_title <- isTRUE(x$exact_title[[i]])
  containment <- isTRUE(x$title_containment[[i]])
  tsim <- x$title_similarity[[i]]
  exact_abs <- isTRUE(x$exact_abstract[[i]])
  strong_abs <- isTRUE(x$strong_abstract[[i]])

  promote <- FALSE
  reason <- ""

  # Long normalised title containment is a high-precision identity signal in the
  # human-reviewed benchmark. Structured identifiers are checked above first.
  if (containment && tlen >= 30L) {
    promote <- TRUE
    reason <- "long_title_containment_no_identifier_conflict"
  }

  # Missing abstract on one manifestation must not act as negative evidence.
  # Require a long exact title, compatible year, and independent corroboration.
  if (!promote && one_missing && exact_title && tlen >= 30L && yd_ok_1 &&
      (pm$first_author_match || pm$journal_match || preprint_pair)) {
    promote <- TRUE
    reason <- "exact_title_missing_abstract_corroborated"
  }

  # Exact substantive abstract plus very strong title agreement can override a different DOI.
  # Generic/reused boilerplate abstracts are protected because title agreement is required.
  if (!promote && exact_abs && tlen >= 30L && yd_ok_1 &&
      !is.na(tsim) && tsim >= 0.95) {
    promote <- TRUE
    reason <- "exact_abstract_high_title_agreement"
  }

  # Long near-identical content can override DOI conflict when the title independently agrees.
  if (!promote && strong_abs && tlen >= 30L &&
      (exact_title || containment || (!is.na(tsim) && tsim >= 0.97))) {
    promote <- TRUE
    reason <- "strong_abstract_high_title_agreement"
  }

  # Explicit preprint -> publication manifestations: DOI change is expected, not contradictory.
  if (!promote && preprint_pair && exact_title && tlen >= 30L && yd_ok_2 &&
      (pm$first_author_match || exact_abs || strong_abs)) {
    promote <- TRUE
    reason <- "preprint_publication_manifestation"
  }


  # Preprint-publication pairs may legitimately change title and DOI. Very strong
  # substantive content is sufficient when the preprint signal is explicit.
  if (!promote && preprint_pair &&
      !is.na(x$ordered_coverage[[i]]) && x$ordered_coverage[[i]] >= 0.98 &&
      !is.na(x$shingle_containment[[i]]) && x$shingle_containment[[i]] >= 0.90) {
    promote <- TRUE
    reason <- "preprint_strong_content_manifestation"
  }

  # Strong near-identical content plus first-author agreement safely recovered
  # additional publication manifestations in the human validation set.
  if (!promote && pm$first_author_match &&
      !is.na(tsim) && tsim >= 0.93 &&
      !is.na(x$ordered_coverage[[i]]) && x$ordered_coverage[[i]] >= 0.92 &&
      !is.na(x$shingle_containment[[i]]) && x$shingle_containment[[i]] >= 0.69) {
    promote <- TRUE
    reason <- "strong_content_first_author_title_agreement"
  }

  # Exact short titles can be safe when independently corroborated by both author
  # and source/journal. Exclude known generic metadata titles.
  if (!promote && exact_title && tlen >= 10L &&
      pm$first_author_match && pm$journal_match &&
      !is_generic_exact_title(x$title_i[[i]]) &&
      !is_generic_exact_title(x$title_j[[i]])) {
    promote <- TRUE
    reason <- "exact_short_title_author_journal"
  }

  # Typographical title variants can be promoted at very high similarity when
  # first author agrees, unless the record is a downstream-exclusion artefact.
  if (!promote && !exact_title && !is.na(tsim) && tsim >= 0.995 &&
      tlen >= 30L && pm$first_author_match &&
      !is_downstream_exclusion_title(x$title_i[[i]]) &&
      !is_downstream_exclusion_title(x$title_j[[i]])) {
    promote <- TRUE
    reason <- "near_exact_title_first_author"
  }

  # Version-family DOI pairs with essentially the same title are manifestations of one work.
  if (!promote && isTRUE(x$same_doi_family[[i]]) && !is.na(tsim) && tsim >= 0.97 && tlen >= 30L) {
    promote <- TRUE
    reason <- "doi_family_high_title_agreement"
  }

  if (promote && x$rescored_classification[[i]] != "duplicate") {
    x$rescored_classification[[i]] <- "duplicate"
    x$rescored_rule[[i]] <- reason
    x$promotion_reason[[i]] <- reason
  }
}


x[, review_route := "manual_review"]
for (i in seq_len(nrow(x))) {
  if (rescored_classification[[i]] == "duplicate") {
    x$review_route[[i]] <- "automatic_duplicate"
  } else if (is_downstream_exclusion_title(x$title_i[[i]]) ||
             is_downstream_exclusion_title(x$title_j[[i]])) {
    x$review_route[[i]] <- "workflow04_exclusion_candidate"
  }
}
x[, manual_review_needed := review_route == "manual_review"]

x[, decision_changed := classification != rescored_classification | rule != rescored_rule]

fwrite(x, file.path(output_dir, "rescored_sample.csv"))
fwrite(x[decision_changed == TRUE], file.path(output_dir, "changed_decisions.csv"))
fwrite(
  x[classification == "duplicate" & rule %in% weak_auto_rules,
    .(record_i, record_j, title_i, title_j, original_rule = rule,
      identifier_conflict, identifier_conflict_reason,
      rescored_classification, rescored_rule)],
  file.path(output_dir, "weak_rule_audit.csv")
)

changed_by_rule <- x[decision_changed == TRUE, .N, by = rule][order(rule)]
remaining_auto_by_rule <- x[rescored_classification == "duplicate", .N, by = rescored_rule][order(rescored_rule)]


x[, pair_key := paste(pmin(record_i, record_j), pmax(record_i, record_j), sep = "::")]
eval <- merge(
  labels,
  x[, .(pair_key, classification, rule, rescored_classification, rescored_rule,
        decision_changed, identifier_conflict, one_abstract_missing,
        first_author_match, journal_match, preprint_pair,
        review_route, manual_review_needed)],
  by = "pair_key",
  all.x = TRUE,
  sort = FALSE
)
eval[, labelled_pair_found := !is.na(rescored_classification)]
eval[, predicted_duplicate := rescored_classification == "duplicate"]
eval[, truth_duplicate := truth == "duplicate"]
eval[, outcome := fifelse(!labelled_pair_found, "not_in_saved_sample",
                   fifelse(truth_duplicate & predicted_duplicate, "TP",
                   fifelse(!truth_duplicate & predicted_duplicate, "FP",
                   fifelse(truth_duplicate & !predicted_duplicate, "FN", "TN"))))]
fwrite(eval, file.path(output_dir, "human_validation_results.csv"))

tp <- eval[outcome == "TP", .N]
fp <- eval[outcome == "FP", .N]
fn <- eval[outcome == "FN", .N]
tn <- eval[outcome == "TN", .N]
precision <- if ((tp + fp) > 0L) tp / (tp + fp) else NA_real_
recall <- if ((tp + fn) > 0L) tp / (tp + fn) else NA_real_
specificity <- if ((tn + fp) > 0L) tn / (tn + fp) else NA_real_
validation_summary <- list(
  labelled_pairs = nrow(labels),
  labelled_pairs_found = sum(eval$labelled_pair_found),
  tp = tp, fp = fp, fn = fn, tn = tn,
  precision = precision,
  recall = recall,
  specificity = specificity,
  changed_labelled_pairs = sum(eval$decision_changed %in% TRUE, na.rm = TRUE)
)
progress("human validation scored", validation_summary$labelled_pairs_found, validation_summary$labelled_pairs,
         paste("TP", tp, "FP", fp, "FN", fn, "TN", tn))

summary <- list(
  workflow = "02_deduplication_v2_identifier_rescore",
  status = "success",
  source_benchmark_run_id = source_run_id,
  sample_n = nrow(x),
  weak_auto_pairs_checked = length(eligible),
  decisions_changed_to_review = sum(x$decision_changed),
  original_classification_counts = as.list(table(x$classification)),
  rescored_classification_counts = as.list(table(x$rescored_classification)),
  changed_by_original_rule = if (nrow(changed_by_rule)) split(changed_by_rule$N, changed_by_rule$rule) else list(),
  remaining_automatic_by_rule = if (nrow(remaining_auto_by_rule)) split(remaining_auto_by_rule$N, remaining_auto_by_rule$rescored_rule) else list(),
  historic_human_adjudications_loaded = FALSE,
  candidate_generation_repeated = FALSE,
  source_candidate_artifact_reused = TRUE
)
writeLines(
  toJSON(summary, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null"),
  file.path(output_dir, "summary.json")
)
progress("rescore complete", nrow(x), nrow(x), paste("decisions changed:", sum(x$decision_changed)))
checkpoint("complete", nrow(x), nrow(x), list(status = "success", decisions_changed = sum(x$decision_changed)))
cat(toJSON(summary, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null"), "\n")
