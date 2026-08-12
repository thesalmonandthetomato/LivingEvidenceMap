# LLM adjudication for species and primary study geography.
#
# Queue construction is deterministic and model execution is injected through
# `model_function`, so this module can be tested without an API call.

build_annotation_adjudication_queue <- function(records, species_review, geography_summary, geography_ranking) {
  required <- c("record_sequence", "record_id", "title", "abstract")
  missing <- setdiff(required, names(records))
  if (length(missing)) stop("Records are missing: ", paste(missing, collapse = ", "), call. = FALSE)

  records <- records |>
    dplyr::mutate(record_id = as.character(record_id), title = dplyr::coalesce(as.character(title), ""), abstract = dplyr::coalesce(as.character(abstract), ""))

  required <- c("record_id", "farmed_species", "farmed_species_id", "assignment_reason", "non_target_species")
  missing <- setdiff(required, names(species_review))
  if (length(missing)) stop("Species review data are missing: ", paste(missing, collapse = ", "), call. = FALSE)

  sp <- species_review |>
    dplyr::mutate(record_id = as.character(record_id)) |>
    dplyr::group_by(record_id) |>
    dplyr::summarise(
      species_review_required = TRUE,
      deterministic_species = paste(sort(unique(stats::na.omit(farmed_species))), collapse = "; "),
      deterministic_species_ids = paste(sort(unique(stats::na.omit(farmed_species_id))), collapse = "; "),
      species_reasons = paste(sort(unique(stats::na.omit(assignment_reason))), collapse = " | "),
      non_target_species = paste(sort(unique(stats::na.omit(non_target_species))), collapse = "; "), .groups = "drop"
    )

  required <- c("record_id", "review_required", "review_reason", "primary_countries", "primary_iso3c")
  missing <- setdiff(required, names(geography_summary))
  if (length(missing)) stop("Geography summary is missing: ", paste(missing, collapse = ", "), call. = FALSE)

  geo <- geography_summary |>
    dplyr::mutate(record_id = as.character(record_id)) |>
    dplyr::filter(review_required) |>
    dplyr::select(record_id, geography_review_required = review_required, geography_review_reason = review_reason,
                  deterministic_primary_countries = primary_countries, deterministic_primary_iso3c = primary_iso3c)

  required <- c("record_id", "country_name", "iso3c", "best_tier")
  missing <- setdiff(required, names(geography_ranking))
  if (length(missing)) stop("Geography ranking is missing: ", paste(missing, collapse = ", "), call. = FALSE)

  candidates <- geography_ranking |>
    dplyr::mutate(record_id = as.character(record_id)) |>
    dplyr::group_by(record_id) |>
    dplyr::summarise(geography_candidates = paste(unique(paste0(country_name, " [", iso3c, "]; tier ", best_tier)), collapse = "; "), .groups = "drop")

  records |>
    dplyr::select(record_sequence, record_id, title, abstract) |>
    dplyr::left_join(sp, by = "record_id") |>
    dplyr::left_join(geo, by = "record_id") |>
    dplyr::left_join(candidates, by = "record_id") |>
    dplyr::mutate(species_review_required = dplyr::coalesce(species_review_required, FALSE),
                  geography_review_required = dplyr::coalesce(geography_review_required, FALSE)) |>
    dplyr::filter(species_review_required | geography_review_required)
}

annotation_adjudication_system_prompt <- function() {
  paste(
    "You are adjudicating species and primary study geography for a salmon-farming scoping review.",
    "Only adjudicate dimensions explicitly flagged for review. Do not change an unflagged dimension.",
    "", "SPECIES:",
    "Eligible farmed salmonids are Atlantic salmon; Pacific salmon species including Chinook, coho, sockeye, chum, pink and masu salmon; rainbow trout; and genuinely unspecified farmed salmon.",
    "Do not infer a species merely because salmon farming is common in that species. If the text only supports generic salmon, use UNSPECIFIED_FARMED_SALMON.",
    "Do not treat wild salmon, fisheries, conservation populations or unrelated fish as farmed species.",
    "Return all eligible farmed salmonids that are substantive study subjects.",
    "", "GEOGRAPHY:",
    "Identify the primary study geography, not every place mentioned.",
    "A single country explicitly named in the title overrides abstract country mentions.",
    "Multiple countries explicitly co-named in the title may all be primary.",
    "Do not use countries mentioned only as background, comparison, literature context, author affiliation, supplier/manufacturer or other incidental context.",
    "If the title names only a continent/macro-region, do not infer a country from incidental abstract mentions.",
    "Known safeguards: New Brunswick = CAN; Northwest alone is not a country; Latin America is not USA; North America is not automatically USA.",
    "Use supplied candidate countries as evidence, but change them when the title/abstract clearly establishes a different location. Do not invent a location without textual evidence.",
    "", "For each dimension choose ACCEPT, CHANGE, or UNRESOLVED.",
    "For species, return a semicolon-separated list, or UNSPECIFIED_FARMED_SALMON, or NONE.",
    "For geography, return ISO3 country code(s), or NONE if no defensible country-level primary geography exists.",
    "Give one concise reason per dimension. Use only the supplied title, abstract and deterministic evidence.", sep = "\n"
  )
}

annotation_adjudication_schema <- function() {
  list(type = "object", properties = list(
    species_decision = list(type = "string", enum = c("ACCEPT", "CHANGE", "UNRESOLVED", "NOT_REVIEWED")),
    species = list(type = "string"), species_reason = list(type = "string"),
    geography_decision = list(type = "string", enum = c("ACCEPT", "CHANGE", "UNRESOLVED", "NOT_REVIEWED")),
    primary_country_iso3c = list(type = "string"), geography_reason = list(type = "string")
  ), required = c("species_decision", "species", "species_reason", "geography_decision", "primary_country_iso3c", "geography_reason"), additionalProperties = FALSE)
}

make_annotation_adjudication_prompt <- function(row) {
  sp_block <- if (isTRUE(row$species_review_required)) paste(
    "SPECIES FLAGGED:", paste(
      "Current species:", dplyr::coalesce(row$deterministic_species, "NONE"),
      "IDs:", dplyr::coalesce(row$deterministic_species_ids, "NONE"),
      "Reasons:", dplyr::coalesce(row$species_reasons, "NONE"),
      "Non-target:", dplyr::coalesce(row$non_target_species, "NONE"), sep = "\n"), sep = "\n"
  ) else "SPECIES NOT FLAGGED: do not change."

  geo_block <- if (isTRUE(row$geography_review_required)) paste(
    "GEOGRAPHY FLAGGED:", paste(
      "Reason:", dplyr::coalesce(row$geography_review_reason, "NONE"),
      "Current:", dplyr::coalesce(row$deterministic_primary_countries, "NONE"),
      "ISO3:", dplyr::coalesce(row$deterministic_primary_iso3c, "NONE"),
      "Candidates:", dplyr::coalesce(row$geography_candidates, "NONE"), sep = "\n"), sep = "\n"
  ) else "GEOGRAPHY NOT FLAGGED: do not change."

  paste("TITLE", row$title, "", "ABSTRACT", row$abstract, "", sp_block, "", geo_block, "", "Adjudicate the flagged dimension(s).", sep = "\n")
}

# Execute adjudication with a supplied model function. The production API
# wrapper belongs outside this core function; tests can supply a mock.
adjudicate_annotation_queue <- function(queue, model_function) {
  if (!is.function(model_function)) stop("model_function must be a function.", call. = FALSE)
  if (!nrow(queue)) return(tibble::tibble())
  required <- c("record_id", "species_review_required", "geography_review_required", "title", "abstract")
  missing <- setdiff(required, names(queue))
  if (length(missing)) stop("Adjudication queue is missing: ", paste(missing, collapse = ", "), call. = FALSE)

  purrr::map_dfr(seq_len(nrow(queue)), function(i) {
    row <- queue[i, , drop = FALSE]
    tryCatch({
      answer <- model_function(annotation_adjudication_system_prompt(), make_annotation_adjudication_prompt(row), annotation_adjudication_schema())
      tibble::tibble(record_id = row$record_id, species_decision = answer$species_decision,
        llm_species = answer$species, species_reason = answer$species_reason,
        geography_decision = answer$geography_decision, llm_primary_country_iso3c = answer$primary_country_iso3c,
        geography_reason = answer$geography_reason, llm_failed = FALSE, llm_error = NA_character_)
    }, error = function(e) {
      tibble::tibble(record_id = row$record_id, species_decision = "UNRESOLVED", llm_species = NA_character_,
        species_reason = NA_character_, geography_decision = "UNRESOLVED", llm_primary_country_iso3c = NA_character_,
        geography_reason = NA_character_, llm_failed = TRUE, llm_error = conditionMessage(e))
    })
  })
}
