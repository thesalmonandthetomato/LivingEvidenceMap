# Assign primary study countries from geography evidence.
#
# This layer consumes geography mentions; it does not read files or choose a
# corpus. The same classifier can therefore be used for the master, updates,
# and small validation fixtures.
#
# Decision hierarchy:
#   1. Country explicitly named in the title takes precedence.
#   2. A title naming only a continent/macro-region is sent to review.
#   3. Otherwise, abstract countries are ranked by evidence strength.
#   4. Exact ties are sent to review rather than resolved arbitrarily.

assign_primary_country <- function(mentions) {
  required <- c("record_sequence", "record_id", "source", "matched_text",
                "country_name", "iso3c", "region_name")
  missing <- setdiff(required, names(mentions))
  if (length(missing) > 0L) {
    stop("Geography mentions are missing: ", paste(missing, collapse = ", "), call. = FALSE)
  }

  if (!nrow(mentions)) {
    return(list(ranking = data.frame(), assignments = data.frame(),
                summary = data.frame(), review_queue = data.frame()))
  }

  mentions <- mentions |>
    dplyr::mutate(
      source = tolower(as.character(source)),
      country_name = as.character(country_name),
      iso3c = as.character(iso3c),
      region_name = as.character(region_name),
      matched_text_lower = tolower(dplyr::coalesce(as.character(matched_text), "")),
      context_lower = if ("context" %in% names(mentions))
        tolower(dplyr::coalesce(as.character(context), "")) else ""
    )

  country_mentions <- mentions |>
    dplyr::filter(!is.na(iso3c), nzchar(iso3c))

  artefact_pattern <- paste(
    c("copyright", "all rights reserved", "creative commons", "published by",
      "publisher", "springer", "elsevier", "wiley", "taylor & francis",
      "translate with", "translation", "language selector", "software", "version",
      "manufacturer", "manufactured by", "supplied by", "provided by",
      "purchased from", "equipment", "instrument", "microscope", "camera",
      "reader", "incubator", "analyser", "analyzer"), collapse = "|"
  )

  species_adjective <- function(context, matched) {
    if (!nzchar(matched) || !nzchar(context)) return(FALSE)
    escaped <- stringr::str_replace_all(matched, "([\\\\.^$|()\\[\\]{}*+?])", "\\\\\\1")
    pattern <- paste0("\\b", escaped, "\\s+(salmon|trout|char|grayling|fish)\\b")
    stringr::str_detect(context, stringr::regex(pattern, ignore_case = TRUE))
  }

  # Anguilla is both a country name and a biological genus (e.g.
  # Anguilla anguilla). When the context is taxonomic, neither Anguilla nor
  # Antigua and Barbuda should be retained as a study-country inference.
  anguilla_taxon_context <- function(context) {
    if (!nzchar(context)) return(FALSE)
    stringr::str_detect(
      context,
      stringr::regex("\\banguilla\\s+[a-z][a-z-]+\\b", ignore_case = TRUE)
    )
  }

  country_mentions <- country_mentions |>
    dplyr::mutate(
      publication_or_vendor_artefact = stringr::str_detect(context_lower, artefact_pattern),
      species_adjective = mapply(species_adjective, context_lower, matched_text_lower),
      anguilla_taxon = mapply(anguilla_taxon_context, context_lower),
      anguilla_country_confusion = anguilla_taxon &
        stringr::str_to_lower(country_name) %in% c("anguilla", "antigua and barbuda")
    ) |>
    dplyr::filter(!publication_or_vendor_artefact, !species_adjective,
                  !anguilla_country_confusion)

  strong_location_pattern <- paste(
    c("conducted in", "conducted at", "study was carried out in",
      "study was undertaken in", "study was performed in", "study area",
      "study site", "study sites", "sampled in", "sampled from",
      "samples were collected in", "samples were collected from", "collected in",
      "collected from", "obtained in", "obtained from", "farms in", "farm in",
      "fish farms in", "aquaculture farms in", "sites in", "site in", "located in",
      "reared in", "raised in", "cultured in", "produced in", "originating from",
      "originated from", "surveyed in", "interviewed in", "fieldwork in",
      "case study in"), collapse = "|"
  )

  substantive_entity_pattern <- paste(
    c("stakeholder", "stakeholders", "farmer", "farmers", "producer", "producers",
      "company", "companies", "industry", "industries", "farm", "farms",
      "hatchery", "hatcheries", "population", "populations", "community",
      "communities", "river", "rivers", "lake", "lakes", "site", "sites"),
    collapse = "|"
  )

  background_pattern <- paste(
    c("previous studies in", "previous research in", "reported in", "reported from",
      "compared with", "compared to", "unlike", "elsewhere in", "for example in",
      "such as", "including"), collapse = "|"
  )

  country_mentions <- country_mentions |>
    dplyr::mutate(
      evidence_tier = dplyr::case_when(
        source == "title" ~ 1L,
        stringr::str_detect(context_lower, strong_location_pattern) ~ 2L,
        stringr::str_detect(context_lower, substantive_entity_pattern) &
          !stringr::str_detect(context_lower, background_pattern) ~ 3L,
        stringr::str_detect(context_lower, background_pattern) ~ 5L,
        TRUE ~ 4L
      )
    )

  title_regions <- mentions |>
    dplyr::filter(source == "title", (is.na(iso3c) | !nzchar(iso3c)),
                  !is.na(region_name), nzchar(region_name)) |>
    dplyr::distinct(record_sequence) |>
    dplyr::mutate(title_has_region_scope = TRUE)

  title_country_counts <- country_mentions |>
    dplyr::filter(source == "title") |>
    dplyr::distinct(record_sequence, iso3c) |>
    dplyr::count(record_sequence, name = "title_country_count")

  ranking <- country_mentions |>
    dplyr::group_by(record_sequence, record_id, iso3c, country_name) |>
    dplyr::summarise(
      best_tier = min(evidence_tier),
      title_mentions = sum(source == "title"),
      substantive_mentions = sum(evidence_tier <= 3L),
      total_mentions = dplyr::n(), .groups = "drop"
    ) |>
    dplyr::left_join(title_country_counts, by = "record_sequence") |>
    dplyr::left_join(title_regions, by = "record_sequence") |>
    dplyr::mutate(
      title_country_count = dplyr::coalesce(title_country_count, 0L),
      title_has_region_scope = dplyr::coalesce(title_has_region_scope, FALSE)
    ) |>
    dplyr::arrange(record_sequence, best_tier, dplyr::desc(substantive_mentions),
                   dplyr::desc(total_mentions), iso3c)

  title_assignments <- ranking |>
    dplyr::filter(title_country_count > 0L, title_mentions > 0L) |>
    dplyr::mutate(assignment_reason = dplyr::if_else(
      title_country_count == 1L,
      "Single title country overrides abstract geography",
      "Countries explicitly co-named in title"
    ))

  abstract_ranked <- ranking |>
    dplyr::filter(title_country_count == 0L, !title_has_region_scope) |>
    dplyr::group_by(record_sequence, record_id) |>
    dplyr::mutate(
      best_tier_record = min(best_tier),
      best_substantive_mentions = max(substantive_mentions[best_tier == best_tier_record]),
      best_total_mentions = max(total_mentions[
        best_tier == best_tier_record & substantive_mentions == best_substantive_mentions
      ]),
      final_tie = sum(best_tier == best_tier_record &
                      substantive_mentions == best_substantive_mentions &
                      total_mentions == best_total_mentions)
    ) |>
    dplyr::ungroup()

  abstract_assignments <- abstract_ranked |>
    dplyr::filter(best_tier == best_tier_record,
                  substantive_mentions == best_substantive_mentions,
                  total_mentions == best_total_mentions, final_tie == 1L) |>
    dplyr::mutate(assignment_reason = dplyr::case_when(
      best_tier == 2L ~ "Primary country from explicit study-location context",
      best_tier == 3L ~ "Primary country from substantive study-entity context",
      best_tier == 4L ~ "Primary country from dominant general mention",
      TRUE ~ "Primary country from strongest available abstract evidence"
    ))

  assignments <- dplyr::bind_rows(title_assignments, abstract_assignments) |>
    dplyr::select(record_sequence, record_id, country_name, iso3c, assignment_reason,
                  best_tier, title_mentions, substantive_mentions, total_mentions) |>
    dplyr::distinct(record_sequence, iso3c, .keep_all = TRUE) |>
    dplyr::arrange(record_sequence, iso3c)

  tie_records <- abstract_ranked |>
    dplyr::filter(final_tie > 1L) |>
    dplyr::distinct(record_sequence, record_id) |>
    dplyr::mutate(review_reason = "Abstract candidates remain exactly tied")

  regional_records <- title_regions |>
    dplyr::inner_join(ranking |> dplyr::distinct(record_sequence, record_id),
                      by = "record_sequence") |>
    dplyr::select(record_sequence, record_id) |>
    dplyr::mutate(review_reason = "Title specifies a continent or macro-region rather than a country")

  review_queue <- dplyr::bind_rows(tie_records, regional_records) |>
    dplyr::distinct(record_sequence, .keep_all = TRUE)

  collapse_unique <- function(x) {
    values <- sort(unique(stats::na.omit(as.character(x))))
    values <- values[nzchar(values)]
    if (!length(values)) NA_character_ else paste(values, collapse = "; ")
  }

  summary <- assignments |>
    dplyr::group_by(record_sequence, record_id) |>
    dplyr::summarise(
      primary_countries = collapse_unique(country_name),
      primary_iso3c = collapse_unique(iso3c),
      primary_country_count = dplyr::n_distinct(iso3c),
      assignment_reasons = collapse_unique(assignment_reason), .groups = "drop"
    ) |>
    dplyr::full_join(review_queue, by = c("record_sequence", "record_id")) |>
    dplyr::mutate(
      primary_country_count = dplyr::coalesce(primary_country_count, 0L),
      review_required = !is.na(review_reason)
    ) |>
    dplyr::arrange(record_sequence)

  list(ranking = ranking, assignments = assignments, summary = summary,
       review_queue = review_queue)
}
