#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(digest)
  library(googlesheets4)
})

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i) || i == length(args)) return(default)
  args[[i + 1L]]
}

model_registry_path <- arg("--model-registry", "docs/workflow04/kappa_registry.csv")
human_csv_path <- arg("--human-csv", "")
sheet_id <- arg("--sheet-id", "")
credential <- arg("--credential", "")
human_tab <- arg("--human-tab", "w04_human_kappa_registry")
output_dir <- arg("--output-dir", "outputs/workflow09_human_validation")

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

first <- function(x, default = "") {
  if (is.null(x) || !length(x) || is.na(x[[1L]])) return(default)
  as.character(x[[1L]])
}

num <- function(x, default = 0) {
  z <- suppressWarnings(as.numeric(x))
  z[is.na(z)] <- default
  z
}

int <- function(x, default = 0L) {
  z <- suppressWarnings(as.integer(x))
  z[is.na(z)] <- default
  z
}

json_chars <- function(x) {
  if (is.null(x) || !length(x) || !nzchar(as.character(x[[1L]]))) return(character())
  tryCatch(as.character(fromJSON(as.character(x[[1L]]))), error = function(e) character())
}

normalise_decision <- function(x) {
  x <- tolower(trimws(as.character(x)))
  ifelse(
    x %in% c("retain","include","included"), "retain",
    ifelse(
      x %in% c("exclude","excluded"), "exclude",
      ifelse(x %in% c("uncertain","unsure"), "uncertain", "")
    )
  )
}

cohen_from_counts <- function(rr, re, er, ee) {
  rr <- as.numeric(rr); re <- as.numeric(re); er <- as.numeric(er); ee <- as.numeric(ee)
  n <- rr + re + er + ee
  if (!is.finite(n) || n <= 0) return(list(n = 0L, agreement = NA_real_, kappa = NA_real_))
  po <- (rr + ee) / n
  model_retain <- (rr + re) / n
  human_retain <- (rr + er) / n
  pe <- model_retain * human_retain + (1 - model_retain) * (1 - human_retain)
  k <- if (isTRUE(all.equal(pe, 1))) NA_real_ else (po - pe) / (1 - pe)
  list(n = as.integer(n), agreement = as.numeric(po), kappa = as.numeric(k))
}

pattern_stats <- function(patterns, n_raters) {
  n_raters <- as.integer(n_raters)
  lev <- c("retain","exclude","uncertain")
  if (is.na(n_raters) || n_raters < 2L || !length(patterns)) {
    return(list(
      n = 0L,
      agreement_n = 0L,
      raw_agreement = NA_real_,
      metric = if (!is.na(n_raters) && n_raters == 2L) "Cohen's kappa" else "Fleiss' kappa",
      kappa = NA_real_
    ))
  }

  parsed <- lapply(patterns, function(z) {
    vals <- strsplit(as.character(z$pattern %||% ""), " \\| ")[[1L]]
    vals <- vapply(vals, normalise_decision, character(1))
    n <- suppressWarnings(as.integer(z$n %||% 0L))
    if (is.na(n)) n <- 0L
    list(vals = vals, n = n)
  })
  good <- vapply(
    parsed,
    function(z) length(z$vals) == n_raters && all(nzchar(z$vals)) && z$n > 0L,
    logical(1)
  )
  parsed <- parsed[good]
  n <- sum(vapply(parsed, function(z) z$n, integer(1)))
  if (!n) {
    return(list(
      n = 0L, agreement_n = 0L, raw_agreement = NA_real_,
      metric = if (n_raters == 2L) "Cohen's kappa" else "Fleiss' kappa",
      kappa = NA_real_
    ))
  }

  agreement_n <- sum(vapply(
    parsed,
    function(z) if (length(unique(z$vals)) == 1L) z$n else 0L,
    integer(1)
  ))
  raw <- agreement_n / n

  if (n_raters == 2L) {
    cells <- matrix(0, nrow = 3L, ncol = 3L, dimnames = list(lev, lev))
    for (z in parsed) {
      cells[z$vals[[1L]], z$vals[[2L]]] <- cells[z$vals[[1L]], z$vals[[2L]]] + z$n
    }
    pa <- rowSums(cells) / n
    pb <- colSums(cells) / n
    pe <- sum(pa * pb)
    po <- sum(diag(cells)) / n
    k <- if (isTRUE(all.equal(pe, 1))) NA_real_ else (po - pe) / (1 - pe)
    return(list(
      n = as.integer(n), agreement_n = as.integer(agreement_n),
      raw_agreement = as.numeric(raw), metric = "Cohen's kappa",
      kappa = as.numeric(k)
    ))
  }

  category_ratings <- setNames(numeric(length(lev)), lev)
  agreement_sum <- 0
  for (z in parsed) {
    counts <- table(factor(z$vals, levels = lev))
    category_ratings <- category_ratings + as.numeric(counts) * z$n
    p_i <- (sum(as.numeric(counts)^2) - n_raters) / (n_raters * (n_raters - 1))
    agreement_sum <- agreement_sum + p_i * z$n
  }
  p_bar <- agreement_sum / n
  p_j <- category_ratings / (n * n_raters)
  pe <- sum(p_j^2)
  k <- if (isTRUE(all.equal(pe, 1))) NA_real_ else (p_bar - pe) / (1 - pe)
  list(
    n = as.integer(n), agreement_n = as.integer(agreement_n),
    raw_agreement = as.numeric(raw), metric = "Fleiss' kappa",
    kappa = as.numeric(k)
  )
}

`%||%` <- function(x, y) if (is.null(x) || !length(x)) y else x

# ---- Model validation registry ----
if (!file.exists(model_registry_path)) {
  stop("W04 model kappa registry not found: ", model_registry_path, call. = FALSE)
}
model <- read.csv(
  model_registry_path,
  stringsAsFactors = FALSE,
  check.names = FALSE,
  colClasses = "character",
  na.strings = NULL
)
model_required <- c(
  "registry_row_id","date","source","batch_id","records_reviewed","records_compared",
  "model_retain_human_retain","model_retain_human_exclude",
  "model_exclude_human_retain","model_exclude_human_exclude",
  "raw_agreement","human_model_kappa","humans_model_fleiss_kappa"
)
missing_model <- setdiff(model_required, names(model))
if (length(missing_model)) {
  stop("Model validation registry missing field(s): ", paste(missing_model, collapse = ", "), call. = FALSE)
}

model_rr <- sum(int(model$model_retain_human_retain))
model_re <- sum(int(model$model_retain_human_exclude))
model_er <- sum(int(model$model_exclude_human_retain))
model_ee <- sum(int(model$model_exclude_human_exclude))
model_cumulative <- cohen_from_counts(model_rr, model_re, model_er, model_ee)

model_report <- data.frame(
  date = as.character(model$date),
  source = as.character(model$source),
  records_reviewed = int(model$records_reviewed),
  records_compared = int(model$records_compared),
  raw_agreement = suppressWarnings(as.numeric(model$raw_agreement)),
  human_model_kappa = suppressWarnings(as.numeric(model$human_model_kappa)),
  humans_model_fleiss_kappa = suppressWarnings(as.numeric(model$humans_model_fleiss_kappa)),
  batch_id = as.character(model$batch_id),
  registry_row_id = as.character(model$registry_row_id),
  stringsAsFactors = FALSE
)
write.csv(
  model_report,
  file.path(output_dir, "model_validation_history.csv"),
  row.names = FALSE,
  na = ""
)

# ---- Human consistency registry ----
human_cols <- c(
  "consistency_id","date","batch_id","queue_sha256","assignment_scope_id",
  "scope_type","reviewer_key","rater_ids_json","rater_labels_json","n_raters",
  "records_n","record_ids_json","record_ids_sha256","metric",
  "agreement_n","conflict_n","raw_agreement","kappa",
  "patterns_json","pairwise_json","analysis_id","created_by","created_at_utc"
)
empty_human <- function() {
  as.data.frame(
    setNames(replicate(length(human_cols), character(), simplify = FALSE), human_cols),
    stringsAsFactors = FALSE
  )
}

if (nzchar(human_csv_path)) {
  if (!file.exists(human_csv_path)) stop("Human consistency CSV not found: ", human_csv_path, call. = FALSE)
  human <- read.csv(
    human_csv_path,
    stringsAsFactors = FALSE,
    check.names = FALSE,
    colClasses = "character",
    na.strings = NULL
  )
} else {
  if (!nzchar(sheet_id) || !nzchar(credential)) {
    stop("Provide --human-csv or both --sheet-id and --credential", call. = FALSE)
  }
  if (!file.exists(credential)) stop("Google credential file not found: ", credential, call. = FALSE)
  gs4_auth(path = credential, cache = FALSE)
  tabs <- sheet_names(sheet_id)
  if (!human_tab %in% tabs) {
    human <- empty_human()
  } else {
    human <- read_sheet(sheet_id, sheet = human_tab, col_types = "c")
  }
}

if (!nrow(human)) {
  human <- empty_human()
} else {
  missing_human <- setdiff(human_cols, names(human))
  if (length(missing_human)) {
    stop("Human consistency registry missing field(s): ", paste(missing_human, collapse = ", "), call. = FALSE)
  }
  human <- human[, human_cols, drop = FALSE]
  for (nm in human_cols) {
    human[[nm]] <- as.character(human[[nm]])
    human[[nm]][is.na(human[[nm]])] <- ""
  }
  if (any(!nzchar(human$consistency_id)) || anyDuplicated(human$consistency_id)) {
    stop("Human consistency registry identity invariant failed", call. = FALSE)
  }
  if (any(!human$scope_type %in% c("partial","full"))) {
    stop("Human consistency registry contains invalid scope_type", call. = FALSE)
  }
}

record_ids <- function(i) {
  sort(unique(json_chars(human$record_ids_json[[i]])))
}
patterns_for <- function(i) {
  tryCatch(
    fromJSON(as.character(human$patterns_json[[i]]), simplifyVector = FALSE),
    error = function(e) list()
  )
}

included <- rep(FALSE, nrow(human))
superseded_by <- rep("", nrow(human))
cumulative_rows <- list()

reviewer_keys <- unique(human$reviewer_key[nzchar(human$reviewer_key)])
for (key in reviewer_keys) {
  idx <- which(human$reviewer_key == key)
  memberships <- lapply(idx, record_ids)
  local_superseded <- rep(FALSE, length(idx))
  local_superseded_by <- rep("", length(idx))
  full_local <- which(human$scope_type[idx] == "full")

  if (length(full_local)) {
    for (ii in seq_along(idx)) {
      for (jj in full_local) {
        if (ii == jj) next
        a <- memberships[[ii]]
        b <- memberships[[jj]]
        if (length(a) && all(a %in% b)) {
          if (length(b) > length(a) || human$scope_type[idx[[ii]]] != "full") {
            local_superseded[[ii]] <- TRUE
            local_superseded_by[[ii]] <- human$consistency_id[idx[[jj]]]
          }
        }
      }
    }
  }

  keep_local <- which(!local_superseded)
  if (length(keep_local) > 1L) {
    pairs <- combn(keep_local, 2L, simplify = FALSE)
    overlap <- Filter(function(p) {
      length(intersect(memberships[[p[[1L]]]], memberships[[p[[2L]]]])) > 0L
    }, pairs)
    if (length(overlap)) {
      stop(
        "Human consistency registry has overlapping contributing sets for reviewer key ",
        key,
        " without one Full set containing the other. Cumulative kappa is undefined.",
        call. = FALSE
      )
    }
  }

  included[idx[keep_local]] <- TRUE
  superseded_by[idx[local_superseded]] <- local_superseded_by[local_superseded]

  n_raters <- unique(int(human$n_raters[idx[keep_local]], default = NA_integer_))
  n_raters <- n_raters[!is.na(n_raters)]
  if (length(n_raters) != 1L) {
    stop("Human consistency reviewer set has inconsistent rater count: ", key, call. = FALSE)
  }

  pats <- list()
  for (local_i in keep_local) {
    p <- patterns_for(idx[[local_i]])
    pats <- c(pats, p)
  }
  if (length(pats)) {
    pkeys <- vapply(pats, function(p) as.character(p$pattern %||% ""), character(1))
    pvals <- vapply(pats, function(p) int(p$n %||% 0L), integer(1))
    agg <- tapply(pvals, pkeys, sum)
    pats <- lapply(names(agg), function(k) list(pattern = k, n = as.integer(agg[[k]])))
  }

  stat <- pattern_stats(pats, n_raters[[1L]])
  latest <- idx[[max(keep_local)]]
  cumulative_rows[[length(cumulative_rows) + 1L]] <- data.frame(
    reviewer_key = key,
    reviewer_labels = paste(json_chars(human$rater_labels_json[[latest]]), collapse = ", "),
    n_raters = n_raters[[1L]],
    contributing_sets = length(keep_local),
    records_n = stat$n,
    raw_agreement = stat$raw_agreement,
    metric = stat$metric,
    kappa = stat$kappa,
    stringsAsFactors = FALSE
  )
}

human_report <- human
human_report$included_in_cumulative <- included
human_report$superseded_by <- superseded_by
write.csv(
  human_report,
  file.path(output_dir, "human_consistency_history.csv"),
  row.names = FALSE,
  na = ""
)

human_cumulative <- if (length(cumulative_rows)) {
  do.call(rbind, cumulative_rows)
} else {
  data.frame(
    reviewer_key = character(),
    reviewer_labels = character(),
    n_raters = integer(),
    contributing_sets = integer(),
    records_n = integer(),
    raw_agreement = numeric(),
    metric = character(),
    kappa = numeric(),
    stringsAsFactors = FALSE
  )
}
write.csv(
  human_cumulative,
  file.path(output_dir, "human_consistency_cumulative.csv"),
  row.names = FALSE,
  na = ""
)

summary <- list(
  schema = "living-evidence-map-workflow09-human-validation-report-v1",
  generated_at_utc = format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ"),
  model_validation = list(
    saved_sets = nrow(model),
    records_reviewed_sum = sum(int(model$records_reviewed)),
    substantive_comparisons = model_cumulative$n,
    raw_agreement = model_cumulative$agreement,
    cohen_kappa = model_cumulative$kappa,
    contingency = list(
      model_retain_human_retain = model_rr,
      model_retain_human_exclude = model_re,
      model_exclude_human_retain = model_er,
      model_exclude_human_exclude = model_ee
    )
  ),
  human_consistency = list(
    available = nrow(human) > 0L,
    saved_sets = nrow(human),
    reviewer_groups = nrow(human_cumulative),
    cumulative = if (nrow(human_cumulative)) {
      lapply(seq_len(nrow(human_cumulative)), function(i) {
        as.list(human_cumulative[i, , drop = FALSE])
      })
    } else list()
  ),
  files = list(
    model_validation_history = "model_validation_history.csv",
    human_consistency_history = "human_consistency_history.csv",
    human_consistency_cumulative = "human_consistency_cumulative.csv"
  )
)
write_json(
  summary,
  file.path(output_dir, "human_validation_summary.json"),
  auto_unbox = TRUE,
  pretty = TRUE,
  na = "null"
)

cat(sprintf(
  "PASS: W09 human validation report: %d model set(s), %d human-consistency set(s), %d reviewer group(s)\n",
  nrow(model), nrow(human), nrow(human_cumulative)
))
