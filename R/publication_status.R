# Salmon Living Evidence Map: publication-status screening
# Ported from scripts/65_remove_retractions_and_notices.R.

identify_publication_notices <- function(title) {
  title <- dplyr::coalesce(as.character(title), "")
  dplyr::case_when(
    stringr::str_detect(title, stringr::regex("^\\s*(retraction(?:\\s+notice)?|retracted)\\s*[:\\-—.]", ignore_case = TRUE)) ~ "retraction_notice",
    stringr::str_detect(title, stringr::regex("^\\s*(withdrawn|withdrawal)\\s*[:\\-—.]", ignore_case = TRUE)) ~ "withdrawal_notice",
    stringr::str_detect(title, stringr::regex("^\\s*(correction|corrigendum|erratum)\\s*[:\\-—.]", ignore_case = TRUE)) ~ "correction_notice",
    TRUE ~ NA_character_
  )
}

normalise_doi_for_openalex <- function(doi) {
  dplyr::coalesce(as.character(doi), "") |>
    stringr::str_to_lower() |>
    stringr::str_remove("^https?://(dx\\.)?doi\\.org/") |>
    stringr::str_remove("^doi:\\s*") |>
    stringr::str_trim()
}

lookup_openalex_doi <- function(doi, api_key = Sys.getenv("OPENALEX_API_KEY")) {
  if (!nzchar(doi)) return(tibble::tibble(doi_for_lookup=doi, openalex_id=NA_character_, openalex_title=NA_character_, openalex_is_retracted=FALSE, openalex_lookup_status="not_queried_no_doi", openalex_error=NA_character_))
  if (!nzchar(api_key)) stop("OPENALEX_API_KEY was not found.")
  url <- paste0("https://api.openalex.org/works/doi:", utils::URLencode(doi, reserved=TRUE))
  tryCatch({
    body <- httr2::request(url) |>
      httr2::req_url_query(api_key=api_key, select="id,doi,display_name,is_retracted") |>
      httr2::req_timeout(30) |>
      httr2::req_retry(max_tries=4, backoff=~ 2^.x) |>
      httr2::req_perform() |>
      httr2::resp_body_json(simplifyVector=TRUE)
    tibble::tibble(doi_for_lookup=doi, openalex_id=dplyr::coalesce(as.character(body$id), NA_character_), openalex_title=dplyr::coalesce(as.character(body$display_name), NA_character_), openalex_is_retracted=isTRUE(body$is_retracted), openalex_lookup_status="matched", openalex_error=NA_character_)
  }, httr2_http_404=function(e) tibble::tibble(doi_for_lookup=doi, openalex_id=NA_character_, openalex_title=NA_character_, openalex_is_retracted=FALSE, openalex_lookup_status="not_found", openalex_error=NA_character_), error=function(e) tibble::tibble(doi_for_lookup=doi, openalex_id=NA_character_, openalex_title=NA_character_, openalex_is_retracted=FALSE, openalex_lookup_status="failed", openalex_error=conditionMessage(e)))
}

check_publication_status <- function(records, api_key=Sys.getenv("OPENALEX_API_KEY"), lookup_fun=lookup_openalex_doi) {
  stopifnot(all(c("record_id", "title") %in% names(records)))
  doi_col <- if ("doi_key" %in% names(records)) "doi_key" else if ("doi" %in% names(records)) "doi" else NULL
  if (is.null(doi_col)) { records$doi <- ""; doi_col <- "doi" }
  records <- records |>
    dplyr::mutate(publication_status_row=dplyr::row_number(), title=dplyr::coalesce(as.character(title), ""), doi_for_lookup=normalise_doi_for_openalex(.data[[doi_col]]), notice_type=identify_publication_notices(title))
  doi_records <- records |> dplyr::filter(is.na(notice_type), nzchar(doi_for_lookup)) |> dplyr::distinct(doi_for_lookup)
  lookup_results <- purrr::map_dfr(doi_records$doi_for_lookup, ~ lookup_fun(.x, api_key=api_key))
  audit <- records |>
    dplyr::left_join(lookup_results, by="doi_for_lookup") |>
    dplyr::mutate(openalex_lookup_status=dplyr::case_when(!is.na(notice_type)~"not_queried_notice", !nzchar(doi_for_lookup)~"not_queried_no_doi", TRUE~dplyr::coalesce(openalex_lookup_status,"not_queried")), openalex_is_retracted=dplyr::coalesce(openalex_is_retracted,FALSE), remove_publication_status=!is.na(notice_type)|openalex_is_retracted, removal_reason=dplyr::case_when(!is.na(notice_type)~notice_type, openalex_is_retracted~"retracted_original", TRUE~NA_character_))
  list(audit=audit, removed=dplyr::filter(audit, remove_publication_status), cleared=dplyr::filter(audit, !remove_publication_status))
}
