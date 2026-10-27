# Offline regression: valid reviewed-only handoff; no network or model calls.
`%||%` <- function(a,b)if(is.null(a)||!length(a))b else a
source("shiny_w07/R/w07_shiny_review_contract.R")
hex <- function(ch)paste(rep(ch,64),collapse="")
model <- list(record_id="test-one",title="Synthetic example",abstract="Test")
decision <- list(event_id="evt1",review_id="review-test",run_id="123",
  record_id="test-one",user_id="reviewer",codes="C05.04",
  relevance="CODED_IN_SCOPE",ontology_sha=hex("a"),prompt_sha=hex("b"),
  queue_sha256=hex("c"),case_sha256=hex("d"),
  supersedes_event_id="",version="1")
payload <- list(schema="lem-w07-human-reviewed-subset-v1",
  review_id="review-test",run_id="123",reviewer_id="reviewer",
  status="review_complete_not_published",sha256=hex("e"),
  manifest=list(ontology_sha256=hex("a"),prompt_sha256=hex("b")),
  model_results=list(model),decision_events=list(decision))
stopifnot(isTRUE(w07_review_handoff_validate(payload,"review-test","123")))
wrong <- payload
wrong$decision_events[[1]]$relevance <- "OUT_OF_SCOPE"
stopifnot(inherits(try(w07_review_handoff_validate(wrong,"review-test","123"),
  silent=TRUE),"try-error"))
missing <- payload
missing$model_results[[2]] <- list(record_id="test-two")
stopifnot(inherits(try(w07_review_handoff_validate(missing,"review-test","123"),
  silent=TRUE),"try-error"))
wrong_review <- payload
wrong_review$review_id <- "other-review"
stopifnot(inherits(try(w07_review_handoff_validate(wrong_review,"review-test","123"),
  silent=TRUE),"try-error"))
cat("PASS W07 reviewed handoff offline contract\n")
