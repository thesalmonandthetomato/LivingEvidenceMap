#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(httr2); library(jsonlite); library(readr); library(dplyr); library(purrr); library(tibble)
})

input_path <- Sys.getenv("ADJUDICATION_INPUT_PATH","")
ontology_path <- Sys.getenv("TOPIC_ONTOLOGY_PATH","data/reference/topic_ontology_v3.csv")
output_dir <- Sys.getenv("ADJUDICATION_OUTPUT_DIR","")
model <- Sys.getenv("ADJUDICATION_MODEL","gpt-5.6-terra")
effort <- Sys.getenv("ADJUDICATION_REASONING_EFFORT","medium")
api_key <- Sys.getenv("OPENAI_API_KEY")
if (!file.exists(input_path) || !file.exists(ontology_path) || !nzchar(output_dir) || !nzchar(api_key)) stop("Missing required input/configuration")
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

records <- read_csv(input_path,show_col_types=FALSE)
ontology <- read_csv(ontology_path,show_col_types=FALSE)
required <- c("record_id","title","abstract","pass_a","pass_b","pass_a_reasons","pass_b_reasons")
if (length(setdiff(required,names(records)))) stop("Missing required input columns")
if (anyDuplicated(records$record_id)) stop("Duplicate record_id")

parse_ids <- function(x) {
  if (is.na(x) || !nzchar(trimws(x))) return(character())
  trimws(sub("=.*$","",unlist(strsplit(x,";"))))
}
entry <- function(r) {
  paste0(
    r$path_id," | ",r$hierarchy_path,
    "\nDefinition: ",r$definition,
    "\nInclude when: ",r$include_when,
    "\nExclude when: ",r$exclude_when,
    ifelse(is.na(r$prompt_logic_note)||!nzchar(r$prompt_logic_note),"",paste0("\nInterpretation note: ",r$prompt_logic_note))
  )
}

payload <- vector("list",nrow(records))
allowed_all <- character()
for (i in seq_len(nrow(records))) {
  a <- parse_ids(records$pass_a[[i]]); b <- parse_ids(records$pass_b[[i]])
  proposed <- union(a,b)
  disputed <- union(setdiff(a,b),setdiff(b,a))
  role_disputed <- intersect(a,b)
  # Objective focused retrieval: all A/B-proposed pathways plus every ontology
  # pathway sharing level_2 with an A/B-proposed pathway.
  levels <- ontology$level_2[match(proposed,ontology$path_id)]
  focus_ids <- unique(c(proposed,ontology$path_id[ontology$level_2 %in% levels]))
  focus <- ontology |> filter(path_id %in% focus_ids)
  allowed_all <- union(allowed_all,focus_ids)
  payload[[i]] <- list(
    record_id=records$record_id[[i]],
    title=records$title[[i]], abstract=records$abstract[[i]],
    pass_a=records$pass_a[[i]], pass_a_reasons=records$pass_a_reasons[[i]],
    pass_b=records$pass_b[[i]], pass_b_reasons=records$pass_b_reasons[[i]],
    disputed_path_ids=disputed,
    shared_path_ids=intersect(a,b),
    focused_ontology=paste(vapply(seq_len(nrow(focus)),function(j) entry(focus[j,]),character(1)),collapse="\n\n")
  )
}

system_prompt <- paste(
"You are an ontology-first adjudicator for a systematic map of salmon aquaculture research.",
"For each record you receive two independent classifications and a RECORD-SPECIFIC FOCUSED ONTOLOGY.",
"The focused ontology contains every pathway proposed by either pass plus all pathways in the same ontology level_2 groups.",
"",
"MANDATORY PROCESS",
"1. Assess every disputed A/B pathway explicitly against its supplied Definition, Include when and Exclude when criteria.",
"2. Preserve shared pathways unless they clearly violate the supplied ontology; document any override.",
"3. A pathway is substantive only if it is an independently substantive research question, intervention, exposure, outcome or conclusion.",
"4. Background, motivation, contextual mentions and incidental measurements are unassigned.",
"5. PRIMARY is central to the main contribution; SECONDARY is independently substantive but non-central.",
"6. Do not infer from title alone. If evidence is insufficient, return needs_more_information.",
"7. Do not prefer A or B, and do not use blind union or intersection.",
"8. Use only path_ids appearing in that record's focused ontology.",
"9. First report the governing ontology criterion and keep/exclude decision for every disputed path; only then give final coding.",
sep="\n")

user_prompt <- paste0("RECORDS\n",toJSON(payload,auto_unbox=TRUE,pretty=FALSE,na="null"))

criterion_schema <- list(
 type="object",
 properties=list(
  path_id=list(type="string",enum=I(allowed_all)),
  governing_criterion=list(type="string"),
  evidence=list(type="string"),
  decision=list(type="string",enum=I(c("KEEP","EXCLUDE"))),
  role=list(type=c("string","null"),enum=I(c("PRIMARY","SECONDARY")))
 ),
 required=I(c("path_id","governing_criterion","evidence","decision","role")),
 additionalProperties=FALSE
)
assignment_schema <- list(
 type="object",
 properties=list(path_id=list(type="string",enum=I(allowed_all)),role=list(type="string",enum=I(c("PRIMARY","SECONDARY")))),
 required=I(c("path_id","role")),additionalProperties=FALSE
)
response_schema <- list(
 type="object",
 properties=list(adjudications=list(
  type="array",
  items=list(
   type="object",
   properties=list(
    record_id=list(type="string",enum=I(records$record_id)),
    status=list(type="string",enum=I(c("resolved","needs_more_information","unresolved"))),
    criteria_assessments=list(type="array",items=criterion_schema),
    assignments=list(type="array",items=assignment_schema),
    pass_alignment=list(type="string",enum=I(c("A","B","hybrid","neither"))),
    rationale=list(type="string")
   ),
   required=I(c("record_id","status","criteria_assessments","assignments","pass_alignment","rationale")),
   additionalProperties=FALSE
  )
 )),
 required=I(c("adjudications")),additionalProperties=FALSE
)

body <- list(
 model=model,store=FALSE,reasoning=list(effort=effort),
 input=list(
  list(role="system",content=list(list(type="input_text",text=system_prompt))),
  list(role="user",content=list(list(type="input_text",text=user_prompt)))
 ),
 text=list(verbosity="low",format=list(type="json_schema",name="focused_topic_adjudication",strict=TRUE,schema=response_schema))
)
resp <- request("https://api.openai.com/v1/responses") |>
 req_auth_bearer_token(api_key) |> req_body_json(body,auto_unbox=TRUE) |>
 req_timeout(600) |> req_retry(max_tries=4,backoff=~2^.x) |>
 req_error(is_error=function(resp) FALSE) |> req_perform()
if (resp_status(resp)>=400) {
 err <- resp_body_string(resp); writeLines(err,file.path(output_dir,"api_error.txt")); stop("OpenAI HTTP ",resp_status(resp),": ",err)
}
response <- resp_body_json(resp)
extract_text <- function(x) {
 m <- x$output[vapply(x$output,function(z) identical(z$type,"message"),logical(1))]
 c <- unlist(lapply(m,function(z) z$content),recursive=FALSE)
 t <- c[vapply(c,function(z) identical(z$type,"output_text")&&!is.null(z$text),logical(1))]
 if(!length(t)) stop("No output_text"); t[[1]]$text
}
parsed <- fromJSON(extract_text(response),simplifyVector=FALSE)
adj <- parsed$adjudications
ids <- vapply(adj,function(x)x$record_id,character(1))
if(length(ids)!=nrow(records)||anyDuplicated(ids)||!setequal(ids,records$record_id)) stop("Returned record IDs do not match input")

rows <- lapply(adj,function(x){
 coding <- if(!length(x$assignments)) "" else paste(vapply(x$assignments,function(a)paste0(a$path_id,"=",a$role),character(1)),collapse="; ")
 trace <- if(!length(x$criteria_assessments)) "" else paste(vapply(x$criteria_assessments,function(a)paste0(a$path_id,":",a$decision," [",a$governing_criterion,"]"),character(1)),collapse=" | ")
 tibble(record_id=x$record_id,status=x$status,final_coding=coding,pass_alignment=x$pass_alignment,criterion_trace=trace,rationale=x$rationale)
}) |> bind_rows() |> left_join(records |> select(record_id,title),by="record_id")
write_csv(rows,file.path(output_dir,"adjudications.csv"),na="")
write_json(response$usage,file.path(output_dir,"usage.json"),auto_unbox=TRUE,pretty=TRUE)
writeLines(system_prompt,file.path(output_dir,"system_prompt.txt"))
writeLines(user_prompt,file.path(output_dir,"focused_payload.txt"))
message("PASS: focused adjudication completed for ",nrow(rows)," records")
