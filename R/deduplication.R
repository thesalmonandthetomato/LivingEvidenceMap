# Salmon Living Evidence Map: Bramer-style bibliographic deduplication
# Follows the staged logic described by Bramer et al. (2016).

normalise_bibliographic_text <- function(x) {
  x <- dplyr::coalesce(as.character(x), "")
  x <- stringr::str_to_lower(x)
  x <- stringi::stri_trans_general(x, "Latin-ASCII")
  x <- stringr::str_replace_all(x, "[^a-z0-9]+", " ")
  stringr::str_squish(x)
}

normalise_pages <- function(x) {
  x <- dplyr::coalesce(as.character(x), "")
  x <- stringr::str_to_lower(x)
  x <- stringr::str_replace_all(x, "\\s+", "")
  x <- stringr::str_replace_all(x, "[–—−]", "-")
  stringr::str_replace_all(x, "(?i)p$", "")
}

normalise_authors <- function(x) {
  x <- dplyr::coalesce(as.character(x), "")
  x <- stringr::str_to_lower(x)
  x <- stringi::stri_trans_general(x, "Latin-ASCII")
  x <- stringr::str_replace_all(x, "[^a-z0-9]+", " ")
  stringr::str_squish(x)
}

prepare_dedup_fields <- function(records) {
  required <- c("record_id", "title", "authors", "year", "journal", "volume", "issue", "pages")
  missing <- setdiff(required, names(records))
  if (length(missing) > 0) stop("Records are missing required deduplication columns: ", paste(missing, collapse = ", "))
  records |>
    dplyr::mutate(
      record_id = as.character(record_id),
      .dedup_title = normalise_bibliographic_text(title),
      .dedup_author = normalise_authors(authors),
      .dedup_journal = normalise_bibliographic_text(journal),
      .dedup_year = suppressWarnings(as.integer(year)),
      .dedup_volume = normalise_bibliographic_text(volume),
      .dedup_issue = normalise_bibliographic_text(issue),
      .dedup_pages = normalise_pages(pages)
    )
}

make_dedup_key <- function(data, fields) {
  values <- lapply(fields, function(field) data[[field]])
  ok <- Reduce(`&`, lapply(values, function(x) !is.na(x) & x != ""))
  key <- do.call(paste, c(values, sep = "||"))
  key[!ok] <- NA_character_
  key
}

find_exact_duplicate_pairs <- function(data, fields, method) {
  key <- make_dedup_key(data, fields)
  idx <- which(!is.na(key))
  if (!length(idx)) return(tibble::tibble())
  groups <- split(idx, key[idx])
  groups <- groups[lengths(groups) > 1L]
  if (!length(groups)) return(tibble::tibble())
  purrr::map_dfr(groups, function(g) {
    pairs <- utils::combn(g, 2L)
    tibble::tibble(record_i = pairs[1, ], record_j = pairs[2, ], method = method)
  })
}

empty_duplicate_pairs <- function() {
  tibble::tibble(record_i = integer(), record_j = integer(), method = character(), status = character(), record_id_i = character(), record_id_j = character())
}

find_duplicate_candidates <- function(records) {
  data <- prepare_dedup_fields(records)
  automatic <- dplyr::bind_rows(
    find_exact_duplicate_pairs(data, c(".dedup_author", ".dedup_year", ".dedup_title", ".dedup_journal"), "A_author_year_title_journal"),
    find_exact_duplicate_pairs(data, c(".dedup_author", ".dedup_year", ".dedup_title", ".dedup_pages"), "B_author_year_title_pages")
  )
  review <- dplyr::bind_rows(
    find_exact_duplicate_pairs(data, c(".dedup_title", ".dedup_volume", ".dedup_pages"), "C_title_volume_pages"),
    find_exact_duplicate_pairs(data, c(".dedup_author", ".dedup_volume", ".dedup_pages"), "D_author_volume_pages"),
    find_exact_duplicate_pairs(data, c(".dedup_year", ".dedup_volume", ".dedup_issue", ".dedup_pages"), "E_year_volume_issue_pages"),
    find_exact_duplicate_pairs(data, c(".dedup_title"), "F_title"),
    find_exact_duplicate_pairs(data, c(".dedup_author", ".dedup_year"), "G_author_year")
  )
  combined <- dplyr::bind_rows(automatic |> dplyr::mutate(status = "duplicate"), review |> dplyr::mutate(status = "review"))
  if (!nrow(combined)) return(empty_duplicate_pairs())
  combined |> dplyr::distinct(record_i, record_j, .keep_all = TRUE) |>
    dplyr::mutate(record_id_i = records$record_id[record_i], record_id_j = records$record_id[record_j])
}

deduplicate_records <- function(records, existing_records = NULL) {
  # Normalise identifier types before combining sources: Lens RIS IDs are
  # character strings, while readr may infer historical CSV IDs as numeric.
  records <- records |> dplyr::mutate(record_id = as.character(record_id))
  if (!is.null(existing_records)) {
    existing_records <- existing_records |> dplyr::mutate(record_id = as.character(record_id))
    combined <- dplyr::bind_rows(records |> dplyr::mutate(.source = "incoming"), existing_records |> dplyr::mutate(.source = "existing"))
  } else {
    combined <- records |> dplyr::mutate(.source = "incoming")
  }
  candidates <- find_duplicate_candidates(combined)
  if (!nrow(candidates)) return(list(records = combined, candidates = candidates, automatic_duplicates = candidates, review_candidates = candidates))
  candidates <- candidates |> dplyr::mutate(cross_corpus = if (is.null(existing_records)) FALSE else combined$.source[record_i] != combined$.source[record_j])
  automatic <- candidates |> dplyr::filter(status == "duplicate") |>
    dplyr::mutate(
      canonical_index = dplyr::case_when(
        cross_corpus & combined$.source[record_i] == "existing" ~ record_i,
        cross_corpus & combined$.source[record_j] == "existing" ~ record_j,
        TRUE ~ pmin(record_i, record_j)
      ),
      duplicate_index = dplyr::if_else(canonical_index == record_i, record_j, record_i),
      canonical_record_id = combined$record_id[canonical_index],
      duplicate_record_id = combined$record_id[duplicate_index]
    )
  list(records = combined, candidates = candidates, automatic_duplicates = automatic, review_candidates = candidates |> dplyr::filter(status == "review"))
}
