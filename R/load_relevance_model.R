# Load the established salmon relevance model saved from the validated
# salmonscopingreview workflow.
#
# Normal screening uses this saved model and its validated thresholds. Training
# remains a separate reproducibility operation and is not part of production.

load_relevance_model <- function(path = "models/relevance/salmon_farming_relevance_model.rds") {
  if (!file.exists(path)) {
    stop("Relevance model not found: ", path, call. = FALSE)
  }

  bundle <- readRDS(path)

  required <- c("model", "thresholds")
  missing <- setdiff(required, names(bundle))

  if (length(missing) > 0L) {
    stop(
      "Relevance model bundle is missing required components: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }

  model_required <- c("cv_fit", "features", "idf")
  model_missing <- setdiff(model_required, names(bundle$model))
  if (length(model_missing) > 0L) {
    stop(
      "Relevance model is missing required components: ",
      paste(model_missing, collapse = ", "),
      call. = FALSE
    )
  }

  threshold_required <- c("exclude_threshold", "include_threshold")
  threshold_missing <- setdiff(threshold_required, names(bundle$thresholds))
  if (length(threshold_missing) > 0L) {
    stop(
      "Relevance model bundle is missing validated thresholds: ",
      paste(threshold_missing, collapse = ", "),
      call. = FALSE
    )
  }

  bundle
}

screen_with_saved_relevance_model <- function(
    records,
    model_path = "models/relevance/salmon_farming_relevance_model.rds"
) {
  bundle <- load_relevance_model(model_path)
  records <- add_screening_keys(records)
  probability <- predict_relevance_probability(bundle$model, records)

  records |>
    dplyr::mutate(
      relevance_probability = probability,
      relevance_decision = assign_screening_decision(
        relevance_probability,
        bundle$thresholds
      )
    )
}
