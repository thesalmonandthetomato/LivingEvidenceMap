# Load the established salmon relevance model saved from the validated
# salmonscopingreview workflow.
#
# Normal screening should use this saved model. Training remains a separate
# reproducibility operation and is not part of the production pipeline.

load_relevance_model <- function(path = "models/relevance/salmon_farming_relevance_model.rds") {
  if (!file.exists(path)) {
    stop("Relevance model not found: ", path, call. = FALSE)
  }

  model <- readRDS(path)

  required <- c("cv_fit", "features", "idf")
  missing <- setdiff(required, names(model))

  if (length(missing) > 0L) {
    stop(
      "Relevance model is missing required components: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }

  model
}

screen_with_saved_relevance_model <- function(records, model_path = "models/relevance/salmon_farming_relevance_model.rds", thresholds = NULL) {
  model <- load_relevance_model(model_path)
  records <- add_screening_keys(records)
  probability <- predict_relevance_probability(model, records)

  if (is.null(thresholds)) {
    thresholds <- list(
      exclude_threshold = 0,
      include_threshold = 1
    )
  }

  records |>
    dplyr::mutate(
      relevance_probability = probability,
      relevance_decision = assign_screening_decision(
        relevance_probability,
        thresholds
      )
    )
}
