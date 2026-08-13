# Salmon Living Evidence Map: LLM relevance adjudication
# Ported from scripts/64_llm_screen_uncertain_records.R and the refined V2 protocol.

salmon_llm_system_prompt <- function() {
  paste(
    "You are screening titles and abstracts for a living evidence map of salmon farming.", "",
    "RETAIN a record when salmon farming is a substantive focus and it concerns one or more eligible farmed salmonids:",
    "- Atlantic salmon", "- Pacific salmon species, including Chinook, coho, sockeye, chum, pink and masu salmon",
    "- rainbow trout", "- farmed salmon where the species is not specified", "",
    "Eligible records may concern any substantive aspect of farming, production, inputs, fish health, welfare, environmental pressures or impacts, products, economics, governance, labour, communities, consumers, or research methods specifically applied to eligible salmon farming.", "",
    "EXCLUDE when:", "- the study concerns only wild salmonids, capture fisheries or conservation;", "- salmon farming is only background, context or a passing example;", "- it concerns only non-eligible aquaculture species;", "- it concerns basic salmon biology without a substantive farming context;", "- the available title and abstract clearly do not concern eligible salmon farming.", "",
    "For mixed-species studies, RETAIN if eligible farmed salmonids are a substantive part of the evidence, analysis or conclusions.", "",
    "Reviews, systematic reviews, meta-analyses, policy papers and synthesis papers are eligible when eligible salmon farming is a substantive focus, even if other aquaculture species, fisheries or food systems are also discussed.", "",
    "Use UNCERTAIN only as a last resort.", "Choose RETAIN whenever the available title and abstract make eligibility more defensible than ineligibility.", "Choose EXCLUDE whenever the available title and abstract make ineligibility more defensible than eligibility.", "Use UNCERTAIN only when the title and abstract genuinely do not contain enough information to make a defensible decision. Do not use UNCERTAIN merely because the paper is broad, multidisciplinary, uses unusual terminology, or requires reasonable inference.", "",
    "DECISION HIERARCHY", "1. If clearly eligible, choose RETAIN.", "2. Otherwise, if clearly ineligible, choose EXCLUDE.", "3. Otherwise, choose UNCERTAIN.", "",
    "Base the decision only on the supplied title and abstract.", "Give one concise reason.", sep = "\n"
  )
}

salmon_llm_response_schema <- function() {
  list(type="object", properties=list(decision=list(type="string", enum=c("retain","exclude","uncertain")), reason=list(type="string")), required=c("decision","reason"), additionalProperties=FALSE)
}

salmon_llm_batch_response_schema <- function() {
  list(
    type = "object",
    properties = list(
      results = list(
        type = "array",
        items = list(
          type = "object",
          properties = list(
            record_id = list(type = "string"),
            decision = list(type = "string", enum = c("retain", "exclude", "uncertain")),
            reason = list(type = "string")
          ),
          required = c("record_id", "decision", "reason"),
          additionalProperties = FALSE
        )
      )
    ),
    required = c("results"),
    additionalProperties = FALSE
  )
}

extract_openai_output_text <- function(response) {
  message_items <- response$output[vapply(response$output, function(item) identical(item$type,"message"), logical(1))]
  content_items <- unlist(lapply(message_items, function(item) item$content), recursive=FALSE)
  text_items <- content_items[vapply(content_items, function(item) identical(item$type,"output_text") && !is.null(item$text), logical(1))]
  if (length(text_items)==0L) stop("No output_text item was returned.")
  text_items[[1]]$text
}

screen_salmon_record <- function(llm_record_key, record_id, title, abstract, api_key=Sys.getenv("OPENAI_API_KEY"), model="gpt-5-mini") {
  if (!nzchar(api_key)) stop("OPENAI_API_KEY was not found.")
  user_prompt <- paste0("TITLE\n", dplyr::coalesce(as.character(title),""), "\n\nABSTRACT\n", dplyr::coalesce(as.character(abstract),""), "\n\nDecide whether this record meets the salmon-farming eligibility criteria.")
  body <- list(model=model, store=FALSE, reasoning=list(effort="low"), input=list(list(role="system",content=list(list(type="input_text",text=salmon_llm_system_prompt()))),list(role="user",content=list(list(type="input_text",text=user_prompt)))), text=list(verbosity="low",format=list(type="json_schema",name="salmon_farming_relevance_screen",strict=TRUE,schema=salmon_llm_response_schema())))
  parsed <- tryCatch({
    response <- httr2::request("https://api.openai.com/v1/responses") |> httr2::req_auth_bearer_token(api_key) |> httr2::req_body_json(body,auto_unbox=TRUE) |> httr2::req_timeout(120) |> httr2::req_retry(max_tries=4,backoff=~ 2^.x) |> httr2::req_perform() |> httr2::resp_body_json()
    jsonlite::fromJSON(extract_openai_output_text(response),simplifyVector=TRUE)
  }, error=function(e) structure(list(message=conditionMessage(e)),class="screening_error"))
  if (inherits(parsed,"screening_error")) return(tibble::tibble(llm_record_key=llm_record_key,record_id=record_id,llm_decision="uncertain",llm_reason=NA_character_,llm_failed=TRUE,llm_error=parsed$message))
  tibble::tibble(llm_record_key=llm_record_key,record_id=record_id,llm_decision=parsed$decision,llm_reason=parsed$reason,llm_failed=FALSE,llm_error=NA_character_)
}

screen_salmon_batch <- function(records, api_key=Sys.getenv("OPENAI_API_KEY"), model="gpt-5-mini") {
  if (!nzchar(api_key)) stop("OPENAI_API_KEY was not found.")
  if (!nrow(records)) return(tibble::tibble())

  record_blocks <- vapply(seq_len(nrow(records)), function(i) {
    paste0(
      "RECORD_ID: ", records$record_id[[i]], "\n",
      "TITLE\n", dplyr::coalesce(as.character(records$title[[i]]), ""), "\n\n",
      "ABSTRACT\n", dplyr::coalesce(as.character(records$abstract[[i]]), ""), "\n"
    )
  }, character(1))

  user_prompt <- paste0(
    "Screen every record below independently. Return exactly one result for every supplied RECORD_ID. ",
    "Do not omit records, merge records, or invent RECORD_IDs. Base each decision only on its supplied title and abstract.\n\n",
    paste(record_blocks, collapse = "\n---\n")
  )

  body <- list(
    model = model,
    store = FALSE,
    reasoning = list(effort = "low"),
    input = list(
      list(role="system", content=list(list(type="input_text", text=salmon_llm_system_prompt()))),
      list(role="user", content=list(list(type="input_text", text=user_prompt)))
    ),
    text = list(
      verbosity = "low",
      format = list(
        type = "json_schema",
        name = "salmon_farming_relevance_batch",
        strict = TRUE,
        schema = salmon_llm_batch_response_schema()
      )
    )
  )

  tryCatch({
    response <- httr2::request("https://api.openai.com/v1/responses") |>
      httr2::req_auth_bearer_token(api_key) |>
      httr2::req_body_json(body, auto_unbox=TRUE) |>
      httr2::req_timeout(180) |>
      httr2::req_retry(max_tries=4, backoff=~ 2^.x) |>
      httr2::req_perform() |>
      httr2::resp_body_json()

    parsed <- jsonlite::fromJSON(extract_openai_output_text(response), simplifyVector=TRUE)
    results <- parsed$results
    if (is.null(results) || !nrow(results)) stop("Batch response contained no results.")

    expected_ids <- as.character(records$record_id)
    returned_ids <- as.character(results$record_id)
    if (length(returned_ids) != length(expected_ids) || anyDuplicated(returned_ids) || !setequal(returned_ids, expected_ids)) {
      stop(sprintf("Batch response record IDs did not match input IDs (expected %d, returned %d).", length(expected_ids), length(returned_ids)))
    }

    results |>
      dplyr::transmute(
        record_id = as.character(record_id),
        llm_decision = as.character(decision),
        llm_reason = as.character(reason),
        llm_failed = FALSE,
        llm_error = NA_character_
      ) |>
      dplyr::left_join(records |> dplyr::select(record_id, llm_record_key), by="record_id") |>
      dplyr::select(llm_record_key, record_id, llm_decision, llm_reason, llm_failed, llm_error)
  }, error=function(e) {
    tibble::tibble(
      llm_record_key = records$llm_record_key,
      record_id = records$record_id,
      llm_decision = "uncertain",
      llm_reason = NA_character_,
      llm_failed = TRUE,
      llm_error = conditionMessage(e)
    )
  })
}
