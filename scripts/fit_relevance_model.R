# Living Evidence Map: fit and validate the established salmon-farming relevance model.
# This preserves the original model specification; it does not introduce a new classifier.

source("R/read_corpus.R")
source("R/relevance_screening.R")

training_file <- here::here("data", "relevance_training_records.csv")
output_dir <- here::here("models", "relevance")
fs::dir_create(output_dir)
stopifnot(file.exists(training_file))

records <- readr::read_csv(
  training_file,
  show_col_types = FALSE,
  col_types = readr::cols(
    record_id = readr::col_character(),
    validation = readr::col_logical()
  )
)

required <- c("record_id", "title", "abstract", "authors", "doi", "year", "eligibility", "screening_text", "validation", "has_abstract")
stopifnot(all(required %in% names(records)))

model <- fit_relevance_model(records)
validation <- records |>
  dplyr::filter(validation) |>
  dplyr::mutate(
    probability_relevant = predict_relevance_probability(model, dplyr::pick(dplyr::everything()))
  )

thresholds <- select_operating_thresholds(
  truth = validation$eligibility,
  probability = validation$probability_relevant,
  target_sensitivity = 0.99,
  target_precision = 0.95
)

validation <- validation |>
  dplyr::mutate(
    screening_decision = assign_screening_decision(probability_relevant, thresholds)
  )

operating_metrics <- dplyr::bind_rows(
  classification_metrics(validation$eligibility, validation$probability_relevant, thresholds$exclude_threshold) |>
    dplyr::mutate(operating_point = "automatic-exclude boundary"),
  classification_metrics(validation$eligibility, validation$probability_relevant, thresholds$include_threshold) |>
    dplyr::mutate(operating_point = "automatic-retain boundary")
)

model_bundle <- list(
  model = model,
  thresholds = thresholds[c("exclude_threshold", "include_threshold", "target_sensitivity", "target_precision")],
  trained_at = Sys.time(),
  training_rows = sum(!records$validation),
  validation_rows = sum(records$validation),
  specification = list(
    text_fields = "title + abstract",
    title_weighting = "title duplicated twice in screening_text",
    ngram_range = "1:2",
    tfidf = TRUE,
    classifier = "L1-regularised logistic regression via glmnet",
    lambda = "lambda.1se",
    target_sensitivity = 0.99,
    target_precision = 0.95
  )
)

saveRDS(model_bundle, fs::path(output_dir, "salmon_farming_relevance_model.rds"))
readr::write_csv(validation, fs::path(output_dir, "relevance_validation_predictions.csv"), na = "")
readr::write_csv(operating_metrics, fs::path(output_dir, "relevance_operating_metrics.csv"), na = "")

message("Relevance classifier trained and validated.")
message("Automatic-exclude threshold: ", round(thresholds$exclude_threshold, 4))
message("Automatic-retain threshold: ", round(thresholds$include_threshold, 4))
