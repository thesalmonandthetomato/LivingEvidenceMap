# Relevance screening and conservative deduplication for the salmon evidence map.
#
# The screening model and deduplication rules are migrated from the original
# salmon scoping-review project. Package installation is deliberately handled
# by the project environment/CI rather than inside analysis functions.

normalise_screening_title <- function(x) {
  x |>
    dplyr::coalesce("") |>
    stringi::stri_trans_general("Latin-ASCII") |>
    stringr::str_to_lower() |>
    stringr::str_replace_all("&[a-z]+;", " ") |>
    stringr::str_replace_all("[^a-z0-9]+", " ") |>
    stringr::str_squish()
}

normalise_screening_doi <- function(x) {
  x |>
    dplyr::coalesce("") |>
    stringr::str_to_lower() |>
    stringr::str_remove("^https?://(dx\\.)?doi\\.org/") |>
    stringr::str_remove("^doi:\\s*") |>
    stringr::str_trim() |>
    dplyr::na_if("")
}

first_author_key <- function(x) {
  split_authors <- stringr::str_split_fixed(
    dplyr::coalesce(x, ""),
    "\\s*\\|\\s*|\\s*;\\s*",
    2
  )

  split_authors[, 1] |>
    stringi::stri_trans_general("Latin-ASCII") |>
    stringr::str_to_lower() |>
    stringr::str_replace_all("[^a-z0-9]+", " ") |>
    stringr::str_squish()
}

make_screening_text <- function(title, abstract) {
  title <- dplyr::coalesce(title, "")
  abstract <- dplyr::coalesce(abstract, "")

  paste0(
    "TITLE_TITLE ", title,
    " TITLE_TITLE ", title,
    " ABSTRACT ", abstract
  ) |>
    stringr::str_squish()
}

add_screening_keys <- function(records) {
  records |>
    dplyr::mutate(
      record_id = as.character(record_id),
      title = dplyr::coalesce(as.character(title), ""),
      abstract = dplyr::coalesce(as.character(abstract), ""),
      title_key = normalise_screening_title(title),
      doi_key = normalise_screening_doi(doi),
      first_author_key = first_author_key(authors),
      screening_text = make_screening_text(title, abstract),
      has_abstract = nzchar(abstract),
      title_prefix = stringr::str_sub(title_key, 1, 24),
      title_token_key = purrr::map_chr(
        stringr::str_split(title_key, "\\s+"),
        function(tokens) {
          tokens <- tokens[nzchar(tokens)]
          paste(sort(unique(head(tokens, 8))), collapse = " ")
        }
      )
    )
}

find_label_conflicts <- function(records) {
  title_conflicts <- records |>
    dplyr::filter(nzchar(title_key)) |>
    dplyr::group_by(title_key) |>
    dplyr::filter(dplyr::n_distinct(eligibility) > 1L) |>
    dplyr::ungroup() |>
    dplyr::mutate(conflict_basis = "exact normalised title")

  doi_conflicts <- records |>
    dplyr::filter(!is.na(doi_key), nzchar(doi_key)) |>
    dplyr::group_by(doi_key) |>
    dplyr::filter(dplyr::n_distinct(eligibility) > 1L) |>
    dplyr::ungroup() |>
    dplyr::mutate(conflict_basis = "exact normalised DOI")

  dplyr::bind_rows(title_conflicts, doi_conflicts) |>
    dplyr::distinct(
      eligibility, record_id, title, doi_key, conflict_basis,
      .keep_all = TRUE
    )
}

collapse_training_duplicates <- function(records) {
  records |>
    dplyr::mutate(
      duplicate_group = dplyr::if_else(
        nzchar(title_key),
        paste0("title:", title_key),
        paste0("record:", screening_source, ":", record_id)
      )
    ) |>
    dplyr::group_by(duplicate_group, eligibility) |>
    dplyr::arrange(
      dplyr::desc(has_abstract),
      dplyr::desc(nchar(abstract)),
      dplyr::desc(nchar(title))
    ) |>
    dplyr::slice_head(n = 1L) |>
    dplyr::ungroup()
}

stratified_group_split <- function(records, validation_fraction = 0.20,
                                   seed = 20260806L) {
  set.seed(seed)

  groups <- records |>
    dplyr::distinct(duplicate_group, eligibility) |>
    dplyr::group_by(eligibility) |>
    dplyr::mutate(
      random_order = sample.int(dplyr::n()),
      validation = dplyr::row_number() <= ceiling(
        dplyr::n() * validation_fraction
      )
    ) |>
    dplyr::ungroup() |>
    dplyr::select(duplicate_group, validation)

  records |>
    dplyr::left_join(groups, by = "duplicate_group")
}

make_tokens <- function(text) {
  quanteda::tokens(
    text,
    remove_punct = TRUE,
    remove_symbols = TRUE,
    remove_numbers = FALSE,
    remove_url = TRUE,
    split_hyphens = TRUE
  ) |>
    quanteda::tokens_tolower() |>
    quanteda::tokens_remove(quanteda::stopwords("en")) |>
    quanteda::tokens_ngrams(n = 1:2)
}

fit_relevance_model <- function(training_records) {
  train <- training_records |>
    dplyr::filter(!validation)

  tokens <- make_tokens(train$screening_text)

  dfm_counts <- quanteda::dfm(tokens) |>
    quanteda::dfm_trim(min_docfreq = 3, docfreq_type = "count") |>
    quanteda::dfm_trim(max_docfreq = 0.98, docfreq_type = "prop")

  dfm_tfidf <- quanteda::dfm_tfidf(
    dfm_counts,
    scheme_tf = "count",
    scheme_df = "inverse"
  )

  x <- methods::as(dfm_tfidf, "dgCMatrix")
  y <- train$eligibility

  set.seed(20260806L)

  cv_fit <- glmnet::cv.glmnet(
    x = x,
    y = y,
    family = "binomial",
    alpha = 1,
    type.measure = "deviance",
    nfolds = 10,
    standardize = FALSE
  )

  list(
    cv_fit = cv_fit,
    features = quanteda::featnames(dfm_counts),
    idf = as.numeric(
      log10(quanteda::ndoc(dfm_counts) / quanteda::docfreq(dfm_counts))
    ),
    training_n = nrow(train),
    positive_n = sum(y == 1L),
    negative_n = sum(y == 0L)
  )
}

transform_with_model <- function(text, model) {
  counts <- make_tokens(text) |>
    quanteda::dfm() |>
    quanteda::dfm_match(features = model$features)

  x <- methods::as(counts, "dgCMatrix")

  x %*% Matrix::Diagonal(x = model$idf)
}

predict_relevance_probability <- function(model, records) {
  x <- transform_with_model(records$screening_text, model)

  as.numeric(
    stats::predict(
      model$cv_fit,
      newx = x,
      s = "lambda.1se",
      type = "response"
    )
  )
}

classification_metrics <- function(truth, probability, threshold) {
  predicted <- probability >= threshold

  tp <- sum(predicted & truth == 1L)
  fp <- sum(predicted & truth == 0L)
  fn <- sum(!predicted & truth == 1L)
  tn <- sum(!predicted & truth == 0L)

  tibble::tibble(
    threshold = threshold,
    true_positive = tp,
    false_positive = fp,
    false_negative = fn,
    true_negative = tn,
    sensitivity = ifelse(tp + fn == 0, NA_real_, tp / (tp + fn)),
    specificity = ifelse(tn + fp == 0, NA_real_, tn / (tn + fp)),
    precision = ifelse(tp + fp == 0, NA_real_, tp / (tp + fp)),
    negative_predictive_value = ifelse(
      tn + fn == 0, NA_real_, tn / (tn + fn)
    )
  )
}

select_operating_thresholds <- function(truth, probability,
                                         target_sensitivity = 0.99,
                                         target_precision = 0.95) {
  thresholds <- sort(unique(c(0, 1, probability, seq(0, 1, by = 0.001))))

  metrics <- purrr::map_dfr(
    thresholds,
    ~ classification_metrics(truth, probability, .x)
  )

  exclude_candidates <- metrics |>
    dplyr::filter(sensitivity >= target_sensitivity)

  exclude_threshold <- if (nrow(exclude_candidates) == 0L) {
    0
  } else {
    max(exclude_candidates$threshold)
  }

  include_candidates <- metrics |>
    dplyr::filter(precision >= target_precision, true_positive > 0L)

  include_threshold <- if (nrow(include_candidates) == 0L) {
    1
  } else {
    min(include_candidates$threshold)
  }

  if (include_threshold <= exclude_threshold) {
    include_threshold <- min(
      1,
      max(
        exclude_threshold + 0.05,
        stats::quantile(
          probability[truth == 1L],
          probs = 0.25,
          na.rm = TRUE
        )
      )
    )
  }

  list(
    exclude_threshold = exclude_threshold,
    include_threshold = include_threshold,
    metrics = metrics,
    target_sensitivity = target_sensitivity,
    target_precision = target_precision
  )
}

assign_screening_decision <- function(probability, thresholds) {
  dplyr::case_when(
    probability < thresholds$exclude_threshold ~ "automatic_exclude",
    probability >= thresholds$include_threshold ~ "automatic_retain",
    TRUE ~ "review"
  )
}

title_similarity <- function(a, b) {
  1 - stringdist::stringdist(a, b, method = "jw", p = 0.1)
}

deduplicate_new_records <- function(
    new_records,
    master_records,
    fuzzy_threshold = 0.965,
    probable_threshold = 0.985
) {
  dedup_output_columns <- c(
    "incoming_row", "duplicate_status", "duplicate_basis",
    "matched_master_record_id", "matched_master_title",
    "title_similarity", "match_priority"
  )

  new <- new_records |>
    dplyr::select(-dplyr::any_of(dedup_output_columns)) |>
    add_screening_keys() |>
    dplyr::mutate(incoming_row = dplyr::row_number())

  master <- master_records |>
    dplyr::select(-dplyr::any_of(dedup_output_columns)) |>
    add_screening_keys() |>
    dplyr::mutate(master_row = dplyr::row_number())

  safe_similarity <- function(a, b) {
    a <- dplyr::coalesce(as.character(a), "")
    b <- dplyr::coalesce(as.character(b), "")

    if (!nzchar(a) || !nzchar(b)) return(0)

    value <- 1 - stringdist::stringdist(a, b, method = "jw", p = 0.1)

    if (length(value) != 1L || is.na(value)) 0 else as.numeric(value)
  }

  empty_matches <- tibble::tibble(
    incoming_row = integer(), duplicate_status = character(),
    duplicate_basis = character(), matched_master_record_id = character(),
    matched_master_title = character(), title_similarity = double(),
    match_priority = integer()
  )

  exact_title <- new |>
    dplyr::filter(nzchar(title_key)) |>
    dplyr::inner_join(
      master |>
        dplyr::filter(nzchar(title_key)) |>
        dplyr::select(
          title_key,
          master_match_id = record_id,
          master_match_title = title
        ),
      by = "title_key",
      relationship = "many-to-many"
    ) |>
    dplyr::transmute(
      incoming_row,
      duplicate_status = "duplicate",
      duplicate_basis = "exact normalised title",
      matched_master_record_id = .data$master_match_id,
      matched_master_title = .data$master_match_title,
      title_similarity = 1,
      match_priority = 1L
    )

  doi_matches <- new |>
    dplyr::filter(!is.na(doi_key), nzchar(doi_key)) |>
    dplyr::inner_join(
      master |>
        dplyr::filter(!is.na(doi_key), nzchar(doi_key)) |>
        dplyr::select(
          doi_key,
          master_match_id = record_id,
          master_match_title = title,
          master_title_key = title_key
        ),
      by = "doi_key",
      relationship = "many-to-many"
    )

  if (nrow(doi_matches) > 0L) {
    doi_matches <- doi_matches |>
      dplyr::mutate(
        title_similarity = purrr::map2_dbl(
          title_key, master_title_key, safe_similarity
        ),
        duplicate_status = dplyr::case_when(
          title_similarity >= 0.90 ~ "duplicate",
          !nzchar(title_key) | !nzchar(master_title_key) ~
            "possible_duplicate",
          TRUE ~ "doi_conflict_review"
        ),
        duplicate_basis = dplyr::case_when(
          duplicate_status == "duplicate" ~
            "matching DOI plus compatible title",
          duplicate_status == "possible_duplicate" ~
            "matching DOI but one title unavailable",
          TRUE ~ "matching DOI but discordant titles"
        ),
        match_priority = dplyr::case_when(
          duplicate_status == "duplicate" ~ 2L,
          duplicate_status == "possible_duplicate" ~ 5L,
          TRUE ~ 6L
        )
      ) |>
      dplyr::transmute(
        incoming_row, duplicate_status, duplicate_basis,
        matched_master_record_id = .data$master_match_id,
        matched_master_title = .data$master_match_title,
        title_similarity, match_priority
      )
  } else {
    doi_matches <- empty_matches
  }

  fuzzy_new <- new |>
    dplyr::filter(
      nzchar(title_key),
      !incoming_row %in% exact_title$incoming_row
    ) |>
    dplyr::select(
      incoming_row, title_key, year, first_author_key,
      title_prefix, title_token_key
    )

  fuzzy_master <- master |>
    dplyr::filter(nzchar(title_key)) |>
    dplyr::select(
      master_match_id = record_id,
      master_match_title = title,
      master_title_key = title_key,
      master_year = year,
      master_first_author = first_author_key,
      master_prefix = title_prefix,
      master_token_key = title_token_key
    )

  candidate_year <- fuzzy_new |>
    dplyr::filter(!is.na(year)) |>
    dplyr::inner_join(
      fuzzy_master |>
        dplyr::filter(!is.na(master_year)),
      by = c("year" = "master_year"),
      relationship = "many-to-many"
    ) |>
    dplyr::mutate(blocking_basis = "same year")

  candidate_author <- fuzzy_new |>
    dplyr::filter(nzchar(first_author_key)) |>
    dplyr::inner_join(
      fuzzy_master |>
        dplyr::filter(nzchar(master_first_author)),
      by = c("first_author_key" = "master_first_author"),
      relationship = "many-to-many"
    ) |>
    dplyr::mutate(blocking_basis = "same first author")

  candidate_prefix <- fuzzy_new |>
    dplyr::filter(nzchar(title_prefix)) |>
    dplyr::inner_join(
      fuzzy_master |>
        dplyr::filter(nzchar(master_prefix)),
      by = c("title_prefix" = "master_prefix"),
      relationship = "many-to-many"
    ) |>
    dplyr::mutate(blocking_basis = "same title prefix")

  candidate_tokens <- fuzzy_new |>
    dplyr::filter(nzchar(title_token_key)) |>
    dplyr::inner_join(
      fuzzy_master |>
        dplyr::filter(nzchar(master_token_key)),
      by = c("title_token_key" = "master_token_key"),
      relationship = "many-to-many"
    ) |>
    dplyr::mutate(blocking_basis = "same title-token key")

  fuzzy_candidates <- dplyr::bind_rows(
    candidate_year, candidate_author,
    candidate_prefix, candidate_tokens
  ) |>
    dplyr::distinct(incoming_row, master_match_id, .keep_all = TRUE)

  if (nrow(fuzzy_candidates) > 0L) {
    fuzzy_matches <- fuzzy_candidates |>
      dplyr::mutate(
        title_similarity = purrr::map2_dbl(
          title_key, master_title_key, safe_similarity
        )
      ) |>
      dplyr::filter(title_similarity >= fuzzy_threshold) |>
      dplyr::mutate(
        duplicate_status = dplyr::case_when(
          title_similarity >= probable_threshold &
            (
              blocking_basis == "same first author" |
                blocking_basis == "same title prefix" |
                blocking_basis == "same title-token key"
            ) ~ "probable_duplicate",
          TRUE ~ "possible_duplicate"
        ),
        duplicate_basis = dplyr::case_when(
          duplicate_status == "probable_duplicate" ~ paste0(
            "very high title similarity plus ", blocking_basis
          ),
          TRUE ~ paste0("high title similarity plus ", blocking_basis)
        ),
        match_priority = dplyr::case_when(
          duplicate_status == "probable_duplicate" ~ 3L,
          TRUE ~ 4L
        )
      ) |>
      dplyr::group_by(incoming_row) |>
      dplyr::arrange(match_priority, dplyr::desc(title_similarity)) |>
      dplyr::slice_head(n = 1L) |>
      dplyr::ungroup() |>
      dplyr::transmute(
        incoming_row, duplicate_status, duplicate_basis,
        matched_master_record_id = .data$master_match_id,
        matched_master_title = .data$master_match_title,
        title_similarity, match_priority
      )
  } else {
    fuzzy_matches <- empty_matches
  }

  matches <- dplyr::bind_rows(
    exact_title, doi_matches, fuzzy_matches
  ) |>
    dplyr::arrange(incoming_row, match_priority, dplyr::desc(title_similarity)) |>
    dplyr::group_by(incoming_row) |>
    dplyr::slice_head(n = 1L) |>
    dplyr::ungroup() |>
    dplyr::select(-match_priority)

  new |>
    dplyr::left_join(matches, by = "incoming_row") |>
    dplyr::mutate(
      duplicate_status = dplyr::coalesce(duplicate_status, "new"),
      duplicate_basis = dplyr::coalesce(duplicate_basis, "")
    )
}
