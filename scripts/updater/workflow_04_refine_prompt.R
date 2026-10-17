#!/usr/bin/env Rscript
# One manually authorised OpenAI request. Input and output remain in the
# restricted W04 prompt-development Zenodo draft; production W04 is untouched.
suppressPackageStartupMessages({library(jsonlite);library(httr2);library(digest)})
`%||%` <- function(x,y)if(is.null(x))y else x
args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag) { i <- match(flag,args);if(is.na(i)||i==length(args)) stop("Missing ",flag,call.=FALSE);args[[i+1L]] }
deposit <- arg("--draft-id"); name <- arg("--request-file"); sha <- tolower(arg("--request-sha"))
if(!grepl("^[0-9]+$",deposit)||!grepl("^w04-refinement-request-[0-9a-f]{20}\\.json$",name)||
   !grepl("^[0-9a-f]{64}$",sha))stop("Invalid immutable refinement request identity",call.=FALSE)
token <- Sys.getenv("ZENODO_ACCESS_TOKEN","");key <- Sys.getenv("OPENAI_API_KEY","")
if(!nzchar(token)||!nzchar(key))stop("Zenodo or OpenAI token unavailable",call.=FALSE)
endpoint <- paste0("https://zenodo.org/api/deposit/depositions/",deposit)
auth <- function(url) req_headers(request(url),Authorization=paste("Bearer",token))
draft <- resp_body_json(req_perform(auth(endpoint)),simplifyVector=FALSE)
if(isTRUE(draft$submitted))stop("The restricted prompt draft is already published",call.=FALSE)
matches <- Filter(function(x)identical(as.character(x$filename),name),draft$files)
if(length(matches)!=1L)stop("Exactly one archived refinement request required",call.=FALSE)
resp <- req_perform(auth(as.character(matches[[1L]]$links$download)))
bytes <- resp_body_raw(resp)
if(!identical(digest(bytes,algo="sha256",serialize=FALSE),sha))
  stop("Archived request checksum mismatch",call.=FALSE)
input <- fromJSON(rawToChar(bytes),simplifyVector=FALSE)
if(!identical(input$schema,"lem-w04-prompt-refinement-request-v1") ||
   !grepl("^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$",input$review_id) ||
   !grepl("^[0-9]+$",input$source_run_id) ||
   !grepl("^[0-9a-f]{64}$",input$prompt_sha256) ||
   !identical(digest(enc2utf8(input$original_prompt),algo="sha256",serialize=FALSE),input$prompt_sha256) ||
   !length(input$cases) || length(input$cases)>500L)
  stop("Invalid provenance or missing model uncertainty cases",call.=FALSE)
outname <- sub("^w04-refinement-request-","w04-refinement-response-",name)
startedname <- sub("^w04-refinement-request-","w04-refinement-started-",name)
existing_names <- vapply(draft$files %||% list(),function(f)as.character(f$filename),character(1))
if(outname %in% existing_names || startedname %in% existing_names)
  stop("This exact refinement request was already started or completed; refusing a repeated paid call",call.=FALSE)
# Persistent pre-call marker: if the API call or archive fails, retries must be
# reconciled manually, not silently billed again.
bucket <- as.character(draft$links$bucket)
if(!startsWith(bucket,"https://zenodo.org/api/files/")) stop("Unexpected Zenodo bucket",call.=FALSE)
mark <- tempfile(fileext=".json");on.exit(unlink(mark),add=TRUE)
writeLines(toJSON(list(request_sha256=sha,request_file=name,
  launched_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")),
  auto_unbox=TRUE),mark,useBytes=TRUE)
req_perform(auth(paste0(bucket,"/",startedname)) |> req_method("PUT") |> req_body_file(mark))
instruction <- paste(
  "You are an expert in systematic review methodology, bibliographic screening and prompt design. Your task is to critically assess and propose targeted improvements to an existing LLM-based inclusion/exclusion screening prompt.",
  "",
  "You will receive:",
  "1. The complete existing screening prompt, including its eligibility criteria, definitions, decision rules and classification instructions.",
  "2. A set of records classified as uncertain by the screening model, including their bibliographic information, abstracts, original model judgements and final human inclusion/exclusion decisions, with any available human rationales.",
  "3. Optional notes from the user, describing particular concerns, observations or desired improvements.",
  "",
  "Analysis",
  "Before proposing any modifications:",
  "- Read and consider the entire existing screening prompt and all accompanying user notes.",
  "- Examine the uncertain records and their human judgements carefully, comparing the characteristics of records judged eligible with those judged ineligible.",
  "- Look for recurring patterns or meaningful distinctions in the records that could explain the human inclusion/exclusion decisions but are not adequately represented in the current prompt.",
  "- Assess whether existing definitions, eligibility criteria, decision rules, or instructions concerning uncertainty are ambiguous, incomplete, inconsistent, contradictory or unnecessarily restrictive.",
  "- Identify where the current prompt may encourage uncertainty that could reasonably be resolved using information in the title, abstract or other supplied bibliographic information.",
  "- Consider how the user's notes and the patterns observed in the human judgements could be translated into clearer, generally applicable screening instructions.",
  "",
  "Proposed revisions",
  "Using this analysis, propose the minimum necessary, targeted and useful modifications to the existing prompt that are likely to reduce avoidable uncertain classifications and improve conformity with the human judgements.",
  "- Prioritise small, precise changes to existing wording rather than extensive rewriting or adding new sections.",
  "- Ensure that any proposed change is consistent with the rest of the prompt. Resolve relevant contradictions or ambiguities rather than introducing additional or competing rules.",
  "- Prefer modifying, consolidating or removing problematic instructions over simply appending new instructions.",
  "- Develop generalisable rules that could improve classification of future records, not exceptions designed to fit individual examples.",
  "- Incorporate relevant user notes into the proposed changes, ensuring that they are consistent with the overall screening criteria.",
  "- Preserve the substantive scope of the review and all definitions, eligibility criteria and instructions that do not require modification.",
  "- Avoid increasing definitive classifications at the expense of accuracy. A reduction in uncertainty is desirable only where the available evidence supports a defensible inclusion or exclusion decision.",
  "- Do not assume that every uncertain case can or should be resolved. Retain an uncertain classification where genuine ambiguity remains after applying the eligibility criteria.",
  "",
  "Final assessment",
  "Before finalising your proposal, critically review the complete revised prompt to ensure that:",
  "- The proposed modifications address the identified patterns in the human judgements and any relevant user notes.",
  "- The classification rules are clear, internally consistent and free from newly introduced contradictions.",
  "- The modifications are minimal and proportionate to the problems identified.",
  "- Unaffected instructions and the original screening scope have been preserved.",
  "- The revisions have a plausible, generalisable basis for reducing unnecessary uncertainty.",
  "",
  "Required output",
  "Return a JSON object containing exactly two fields:",
  "proposed_prompt: The complete revised screening prompt, preserving the original wording, formatting and structure wherever modifications are unnecessary.",
  "explanation: A concise but informative explanation identifying the main patterns or distinctions identified across human inclusion/exclusion judgements; relevant ambiguity, inconsistency or contradiction in the original prompt; the specific modifications and reasoning; how they are expected to reduce avoidable uncertainty and improve conformity with human decisions; and remaining limitations or trade-offs that minor changes cannot address.",
  "Do not invent evidence, change the human judgements, or claim improved classification performance without subsequent testing.",
  "Do not include Markdown code fences or content outside the JSON object.",
  sep="\n")

payload <- toJSON(list(original_prompt=input$original_prompt,cases=input$cases,
  user_note=input$user_note %||% ""),auto_unbox=TRUE,null="null",digits=NA)
model <- Sys.getenv("W04_PROMPT_REFINEMENT_MODEL","gpt-4.1-mini")
message("Submitting exactly one W04 refinement API request")
api <- request("https://api.openai.com/v1/chat/completions") |>
  req_headers(Authorization=paste("Bearer",key)) |>
  req_body_json(list(model=model,response_format=list(type="json_object"),
    messages=list(list(role="system",content=instruction),
                  list(role="user",content=payload)))) |>
  req_timeout(240) |> req_retry(max_tries=1)
answer <- resp_body_json(req_perform(api),simplifyVector=FALSE)
parsed <- fromJSON(as.character(answer$choices[[1L]]$message$content),simplifyVector=FALSE)
proposed <- as.character(parsed$proposed_prompt %||% "")
if(length(proposed)!=1L||!nzchar(trimws(proposed))||nchar(proposed)>100000L)
  stop("OpenAI returned an invalid complete proposed prompt",call.=FALSE)
result <- list(schema="lem-w04-prompt-refinement-response-v1",
 review_id=input$review_id,source_run_id=input$source_run_id,
 subset_id=input$subset_id,prompt_version_id=input$prompt_version_id,
 prompt_sha256=input$prompt_sha256,request_sha256=sha,
 original_prompt=input$original_prompt,proposed_prompt=proposed,
 explanation=as.character(parsed$explanation %||% ""),
 model=model,usage=answer$usage,
 created_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ"))
tmp <- tempfile(fileext=".json");on.exit(unlink(tmp),add=TRUE)
writeLines(toJSON(result,auto_unbox=TRUE,pretty=TRUE,null="null",digits=NA),tmp,useBytes=TRUE)
bucket <- as.character(draft$links$bucket)
if(!startsWith(bucket,"https://zenodo.org/api/files/")) stop("Unexpected Zenodo bucket",call.=FALSE)
up <- auth(paste0(bucket,"/",outname)) |> req_method("PUT") |> req_body_file(tmp)
status <- resp_status(req_perform(up))
if(!status %in% c(200L,201L))stop("Zenodo result upload failed",call.=FALSE)
message("Saved restricted W04 refinement result: ",outname)
