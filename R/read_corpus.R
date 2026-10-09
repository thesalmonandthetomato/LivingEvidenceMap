# RIS corpus ingestion, ported from the validated salmon workflow.

clean_na <- function(x) {
  x <- stringr::str_squish(x)
  dplyr::na_if(x, "NA")
}

clean_html <- function(x) {
  x <- dplyr::coalesce(x, "")
  x <- stringr::str_replace_all(x, "<[^>]+>", " ")
  x <- stringr::str_replace_all(x, "&nbsp;", " ")
  x <- stringr::str_replace_all(x, "&amp;", "&")
  x <- stringr::str_replace_all(x, "&lt;", "<")
  x <- stringr::str_replace_all(x, "&gt;", ">")
  x <- stringr::str_squish(x)
  dplyr::na_if(x, "")
}

normalise_doi <- function(x) {
  x <- clean_na(x)
  x <- stringr::str_to_lower(x)
  x <- stringr::str_remove(x, "^https?://(dx\\.)?doi\\.org/")
  x <- stringr::str_remove(x, "^doi:\\s*")
  x <- stringr::str_trim(x)
  x[!stringr::str_detect(x, "^10\\.\\d{4,9}/\\S+$")] <- NA_character_
  x
}

parse_ris_like <- function(path) {
  if (!file.exists(path)) stop("Corpus file does not exist: ", path, call. = FALSE)

  lines <- readLines(path, encoding = "UTF-8", warn = FALSE)
  lines <- stringi::stri_enc_toutf8(lines, is_unknown_8bit = TRUE)
  end_idx <- which(stringr::str_detect(lines, "^ER\\s{2}-"))
  if (!length(end_idx)) stop("No ER record terminators were found.", call. = FALSE)

  start_idx <- c(1L, head(end_idx, -1L) + 1L)

  purrr::map2_dfr(start_idx, end_idx, function(start, end) {
    block <- lines[start:end]
    field_lines <- stringr::str_detect(block, "^[A-Z0-9]{2}\\s{2}-")
    field_no <- cumsum(field_lines)
    valid <- field_no > 0
    block <- block[valid]
    field_no <- field_no[valid]

    collapsed <- tibble::tibble(field_no = field_no, text = block) |>
      dplyr::group_by(field_no) |>
      dplyr::summarise(text = paste(text, collapse = " "), .groups = "drop")

    tags <- stringr::str_sub(collapsed$text, 1, 2)
    values <- collapsed$text |>
      stringr::str_replace("^[A-Z0-9]{2}\\s{2}-\\s?", "") |>
      stringr::str_squish()

    get_one <- function(tag) {
      x <- values[tags == tag]
      if (!length(x)) NA_character_ else paste(x, collapse = " | ")
    }

    authors <- values[tags == "AU"]

    tibble::tibble(
      record_sequence = match(end, end_idx),
      type = get_one("TY"),
      record_id = get_one("ID"),
      title = dplyr::coalesce(get_one("TI"), get_one("ST")),
      short_title = get_one("ST"),
      abstract_raw = get_one("AB"),
      authors = if (length(authors)) paste(authors, collapse = " | ") else NA_character_,
      doi_raw = get_one("DO"),
      year_raw = get_one("PY"),
      journal = get_one("T2"),
      volume = get_one("VL"),
      issue = get_one("IS"),
      pages = get_one("SP"),
      url_raw = get_one("UR"),
      raw_field_count = length(tags)
    )
  })
}

read_corpus <- function(path) {
  parse_ris_like(path) |>
    dplyr::mutate(
      dplyr::across(c(type, record_id, title, short_title, journal, volume, issue, pages), clean_na),
      abstract = clean_html(abstract_raw),
      doi = normalise_doi(doi_raw),
      year = suppressWarnings(as.integer(stringr::str_extract(year_raw, "(?:18|19|20)\\d{2}"))),
      title_normalised = title |>
        stringr::str_to_lower() |>
        stringi::stri_trans_general("Latin-ASCII") |>
        stringr::str_replace_all("[^a-z0-9]+", " ") |>
        stringr::str_squish(),
      abstract_word_count = stringr::str_count(dplyr::coalesce(abstract, ""), "\\S+"),
      title_word_count = stringr::str_count(dplyr::coalesce(title, ""), "\\S+"),
      has_title = !is.na(title),
      has_abstract = !is.na(abstract),
      has_valid_doi = !is.na(doi),
      parser_missing_type = is.na(type),
      parser_missing_id = is.na(record_id)
    )
}

make_authors_long <- function(records) {
  required <- c("record_sequence", "record_id", "authors")
  missing <- setdiff(required, names(records))
  if (length(missing)) stop("Records are missing required columns: ", paste(missing, collapse = ", "), call. = FALSE)

  records |>
    dplyr::select(record_sequence, record_id, authors) |>
    tidyr::separate_longer_delim(authors, delim = " | ") |>
    dplyr::rename(author = authors) |>
    dplyr::filter(!is.na(author), author != "") |>
    dplyr::group_by(record_sequence) |>
    dplyr::mutate(author_order = dplyr::row_number()) |>
    dplyr::ungroup()
}
