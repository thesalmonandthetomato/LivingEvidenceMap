#!/usr/bin/env Rscript
# Isolated W07 Shiny subset. Explicit invocation only; never publishes.
suppressPackageStartupMessages({library(httr2);library(jsonlite);library(digest)})
source("shiny_w07/R/w05_w07_bridge.R")
source("shiny_w07/R/w07_shiny_trial_gate.R")
source("shiny_w07/R/w07_shiny_evidence.R")
getenv <- function(k) Sys.getenv(k,unset="")
review <- getenv("W07_REVIEW_ID")
w05 <- getenv("W07_W05_DEPOSIT_ID")
draft <- getenv("W07_CONFIG_DEPOSIT_ID")
ont_sha <- getenv("W07_ONTOLOGY_SHA")
prompt_sha <- getenv("W07_PROMPT_SHA")
n <- suppressWarnings(as.integer(getenv("W07_SUBSET_COUNT")))
token <- getenv("ZENODO_ACCESS_TOKEN")
api_key <- getenv("OPENAI_API_KEY")
model <- "gpt-5.6-luna"
if(!grepl("^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$",review)||
   !all(grepl("^[0-9]+$",c(w05,draft)))||
   !all(grepl("^[a-f0-9]{64}$",c(ont_sha,prompt_sha)))||
   is.na(n)||n<1L||n>30L||!nzchar(token)||!nzchar(api_key))
  stop("Invalid W07 Shiny subset request; trials limited to 30 records",call.=FALSE)
fetch <- function(url) {
  if(!startsWith(url,"https://zenodo.org/"))
    stop("Untrusted Zenodo URL",call.=FALSE)
  req <- request(url) |> req_auth_bearer_token(token) |> req_timeout(180)
  res <- req_perform(req_error(req,is_error=function(x) FALSE))
  if(resp_status(res)!=200L)return(NULL)
  resp_body_raw(res)
}
deposit <- function(id) {
  bytes <- fetch(paste0("https://zenodo.org/api/deposit/depositions/",id))
  if(is.null(bytes))stop("Zenodo deposition is unavailable",call.=FALSE)
  fromJSON(rawToChar(bytes),simplifyVector=FALSE)
}
file_bytes <- function(dep,name) {
  matching <- Filter(function(f)identical(as.character(f$filename %||% ""),name),
                     dep$files %||% list())
  if(length(matching)!=1L)stop("Missing or duplicate Zenodo file: ",name,call.=FALSE)
  bytes <- fetch(as.character(matching[[1L]]$links$download %||% ""))
  if(is.null(bytes) && isTRUE(dep$submitted))
    bytes <- fetch(paste0("https://zenodo.org/api/records/",as.character(dep$id),
      "/files/",utils::URLencode(name,reserved=TRUE),"/content"))
  if(is.null(bytes))stop("Cannot securely retrieve Zenodo file: ",name,call.=FALSE)
  bytes
}
source_dep <- deposit(w05)
if(!isTRUE(source_dep$submitted) ||
   !identical(as.character(source_dep$metadata$title),
     paste("Living Evidence Map W05 crop coding |",review)) ||
   !identical(as.character(source_dep$metadata$access_right),"restricted"))
  stop("W07 requires a published restricted W05 source for this review",call.=FALSE)
manifest <- fromJSON(rawToChar(file_bytes(source_dep,"w05-final-manifest.json")),
                     simplifyVector=FALSE)
names <- vapply(source_dep$files %||% list(),
                function(x)as.character(x$filename %||% ""),character(1))
canonical <- grep("^w05-shiny-w04-input-[0-9a-f]{20}\\.jsonl$",names,value=TRUE)
if(length(canonical)!=1L)stop("W05 canonical input is missing or ambiguous",call.=FALSE)
bytes <- file_bytes(source_dep,canonical)
records <- w07_bridge_records(bytes,manifest)
dep <- deposit(draft)
if(isTRUE(dep$submitted) ||
   !identical(as.character(dep$metadata$title),
    paste("Living Evidence Map W07 topic configuration |",review)) ||
   !identical(as.character(dep$metadata$access_right),"restricted"))
  stop("W07 configuration must be a matching restricted unpublished draft",call.=FALSE)
version <- function(type,sha) {
  prefix <- paste0("w07-",type,"-",sha,".json")
  mark <- paste0("w07-approved-",type,"-",sha,".json")
  object <- fromJSON(rawToChar(file_bytes(dep,prefix)),simplifyVector=FALSE)
  approval <- fromJSON(rawToChar(file_bytes(dep,mark)),simplifyVector=FALSE)
  w07_trial_validate_version(object,approval,review,type,sha)
}
ontology <- version("ontology",ont_sha)
prompt <- version("prompt",prompt_sha)
prepared <- w07_trial_prepare(records,n,ontology,prompt,review,
  w07_bridge_sha(bytes),ont_sha,prompt_sha)
# Only the supplied ontology determines the topic labels and definitions.
ontology_json <- toJSON(ontology,auto_unbox=TRUE,na="null")
allowed <- ontology$path_id
response_schema <- list(type="object",properties=list(
  assignments=list(type="array",items=list(type="object",properties=list(
    path_id=list(type="string"),
    evidence=list(type="string"),
    explanation=list(type="string"),
    confidence=list(type="string",enum=c("high","medium","low"))
  ),required=c("path_id","evidence","explanation","confidence"),additionalProperties=FALSE)),
  human_review=list(type="boolean"),
  ambiguity=list(type="string")
),required=c("assignments","human_review","ambiguity"),additionalProperties=FALSE)
extract_response <- function(x) {
  for(item in x$output %||% list())
    for(part in item$content %||% list())
      if(identical(part$type,"output_text"))return(as.character(part$text))
  stop("No model output text",call.=FALSE)
}
out <- file.path(getenv("RUNNER_TEMP"),"w07-shiny-results")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
results <- vector("list",n)
for(i in seq_len(n)) {
  rec <- prepared$records[i,,drop=FALSE]
  payload <- list(model=model,store=FALSE,reasoning=list(effort="low"),
    input=list(
      list(role="system",content=list(list(type="input_text",
        text=paste(prompt,"\n\nONTOLOGY (the only authorised topic codes):",
                   ontology_json)))),
      list(role="user",content=list(list(type="input_text",
        text=paste("RECORD ID:",rec$record_id,"TITLE:",rec$title,
                   "ABSTRACT:",rec$abstract,sep="\n"))))),
    text=list(verbosity="low",format=list(type="json_schema",
      name="w07_substantive_topics",strict=TRUE,schema=response_schema)))
  result <- tryCatch({
    res <- req_perform(request("https://api.openai.com/v1/responses") |>
      req_auth_bearer_token(api_key) |> req_body_json(payload,auto_unbox=TRUE) |>
      req_timeout(120) |> req_retry(max_tries=3))
    body <- resp_body_json(res,simplifyVector=FALSE)
    coding <- fromJSON(extract_response(body),simplifyVector=FALSE)
    issues <- w07_validate_model_coding(coding,allowed,rec$title,rec$abstract)
    list(status=if(length(issues))"needs_review" else "ok",
         coding=coding,validation_issues=issues,
         usage=body$usage %||% list())
  },error=function(e)list(status="needs_review",error=conditionMessage(e)))
  results[[i]] <- c(list(record_id=rec$record_id,title=rec$title,
    abstract=rec$abstract),result)
}
writeLines(vapply(results,function(x)toJSON(x,auto_unbox=TRUE,null="null"),
                  character(1)),file.path(out,"w07_subset_results.jsonl"),useBytes=TRUE)
summary <- c(prepared$manifest,list(model=model,
  completed=sum(vapply(results,function(x)identical(x$status,"ok"),logical(1))),
  needs_review=sum(vapply(results,function(x)identical(x$status,"needs_review"),logical(1)))))
write_json(summary,file.path(out,"w07_subset_manifest.json"),auto_unbox=TRUE,pretty=TRUE)
cat(sprintf("PASS experimental W07 subset %d records: %d coded, %d need review\n",
 n,summary$completed,summary$needs_review))
