#!/usr/bin/env Rscript
# Isolated Shiny W06 geography subset. Topic and spatial constraints come from
# the review-specific approved prompt, never from code or global production config.
suppressPackageStartupMessages({library(jsonlite);library(digest);library(httr2)})
`%||%` <- function(x,y)if(is.null(x)||!length(x)) y else x
env <- function(n)Sys.getenv(n,unset="")
review <- env("W06_REVIEW_ID")
w05_id <- env("W06_W05_DEPOSIT_ID")
prompt_id <- env("W06_PROMPT_DEPOSIT_ID")
prompt_sha <- tolower(env("W06_PROMPT_SHA"))
count_raw <- env("W06_SUBSET_COUNT")
api_key <- env("OPENAI_API_KEY")
model <- "gpt-5.6-luna" # Existing W06 production model; isolated invocation
if(!grepl("^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$",review) ||
   !all(grepl("^[0-9]+$",c(w05_id,prompt_id,count_raw))) ||
   !grepl("^[a-f0-9]{64}$",prompt_sha) || !nzchar(api_key))
  stop("Invalid W06 review, source, prompt identity or API configuration",call.=FALSE)
count <- suppressWarnings(as.integer(count_raw))
if(is.na(count)||count<1L)stop("Invalid positive W06 subset size",call.=FALSE)
token <- env("ZENODO_ACCESS_TOKEN")
if(!nzchar(token))stop("Restricted Zenodo access unavailable",call.=FALSE)
get_json <- function(id){
  url <- paste0("https://zenodo.org/api/deposit/depositions/",id)
  req <- request(url) |> req_auth_bearer_token(token) |> req_timeout(120)
  resp_body_json(req_perform(req),simplifyVector=FALSE)
}
download_item <- function(dep,name) {
  selected <- Filter(function(x)identical(as.character(x$filename %||% ""),name),dep$files %||% list())
  if(length(selected)!=1L)stop("Expected exactly one Zenodo file: ",name,call.=FALSE)
  url <- as.character(selected[[1L]]$links$download %||% "")
  if(!startsWith(url,"https://zenodo.org/"))stop("Untrusted Zenodo file URL",call.=FALSE)
  resp_body_raw(req_perform(request(url) |> req_auth_bearer_token(token) |> req_timeout(180)))
}
sha <- function(x)digest(x,algo="sha256",serialize=FALSE)
source_dep <- get_json(w05_id)
if(!isTRUE(source_dep$submitted) ||
   !identical(as.character(source_dep$metadata$title),
     paste("Living Evidence Map W05 crop coding |",review)))
  stop("W06 requires published W05 finalisation for this review",call.=FALSE)
manifest_bytes <- download_item(source_dep,"w05-final-manifest.json")
manifest <- fromJSON(rawToChar(manifest_bytes),simplifyVector=FALSE)
if(!identical(as.character(manifest$mode),"full_corpus") ||
   as.integer(manifest$processed_records)!=as.integer(manifest$input_records))
  stop("W05 source is not a complete independent full-corpus run",call.=FALSE)
files <- vapply(source_dep$files %||% list(),function(x)as.character(x$filename %||% ""),character(1))
inputs <- grep("^w05-shiny-w04-input-[0-9a-f]{20}[.]jsonl$",files,value=TRUE)
if(length(inputs)!=1L)stop("Expected exactly one archived W05 canonical input JSONL",call.=FALSE)
input_bytes <- download_item(source_dep,inputs[[1L]])
if(!identical(sha(input_bytes),as.character(manifest$input_sha256)))
  stop("W05 source JSONL checksum mismatch",call.=FALSE)
prompt_dep <- get_json(prompt_id)
if(isTRUE(prompt_dep$submitted) ||
   !identical(as.character(prompt_dep$metadata$title),
     paste("Living Evidence Map W06 prompt development |",review)))
  stop("Unapproved or wrong-review W06 prompt archive",call.=FALSE)
prompt_bytes <- download_item(prompt_dep,paste0("w06-prompt-",prompt_sha,".json"))
prompt <- fromJSON(rawToChar(prompt_bytes),simplifyVector=FALSE)
if(!identical(as.character(prompt$review_id),review) ||
   !identical(as.character(prompt$sha256),prompt_sha) ||
   !identical(sha(as.character(prompt$content)),prompt_sha))
  stop("W06 prompt content checksum or review identity mismatch",call.=FALSE)
approved_bytes <- download_item(prompt_dep,paste0("w06-approved-",prompt_sha,".json"))
approved <- fromJSON(rawToChar(approved_bytes),simplifyVector=FALSE)
if(!identical(approved$schema,"lem-w06-prompt-approval-v1") ||
   !identical(approved$review_id,review) ||
   !identical(approved$prompt_sha256,prompt_sha))
  stop("W06 prompt approval does not match immutable version",call.=FALSE)
lines <- strsplit(rawToChar(input_bytes),"\n",fixed=TRUE)[[1L]]
lines <- lines[nzchar(trimws(lines))]
if(length(lines)!=as.integer(manifest$input_records))
  stop("Published W05 source count differs from JSONL",call.=FALSE)
if(count>length(lines))stop("W06 subset size exceeds published W05 corpus",call.=FALSE)
records <- lapply(head(lines,count),function(line){
  x <- fromJSON(line,simplifyVector=FALSE)
  val <- function(z)if(is.null(z)||!length(z))"" else as.character(z[[1L]])
  can <- x[["canonical",exact=TRUE]] %||% list()
  list(record_id=val((x[["identity",exact=TRUE]] %||% list())[["record_id",exact=TRUE]]),
       title=val(can[["title",exact=TRUE]]),
       abstract=val(can[["abstract",exact=TRUE]]))
})
ids <- vapply(records,function(z)z$record_id,character(1))
if(any(!nzchar(ids))||anyDuplicated(ids))
  stop("Duplicate/missing W06 source record IDs",call.=FALSE)
if(any(vapply(records,function(z)grepl("^pending_workflow[0-9]+$",z$abstract),logical(1))))
  stop("Workflow status read as abstract; refuse W06 model execution",call.=FALSE)
schema <- list(type="object",properties=list(
  geography_status=list(type="string",enum=c("RESOLVED","NONE","UNCERTAIN")),
  locations=list(type="array",items=list(type="object",properties=list(
    location_name=list(type="string"),
    location_type=list(type="string"),
    evidence=list(type="string"),
    confidence=list(type="string",enum=c("explicit","inferred","uncertain"))
  ),required=c("location_name","location_type","evidence","confidence"),
     additionalProperties=FALSE)),
  explanation=list(type="string")
),required=c("geography_status","locations","explanation"),additionalProperties=FALSE)
extract_text <- function(x) {
  for(item in x$output %||% list())
    for(part in item$content %||% list())
      if(identical(part$type,"output_text"))return(as.character(part$text))
  stop("No structured model output text",call.=FALSE)
}
out <- file.path(env("RUNNER_TEMP"),"w06-shiny-results")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
results <- vector("list",length(records))
for(i in seq_along(records)){
  rec <- records[[i]]
  payload <- list(model=model,store=FALSE,reasoning=list(effort="low"),
    input=list(
      list(role="system",content=list(list(type="input_text",text=prompt$content))),
      list(role="user",content=list(list(type="input_text",
        text=paste("RECORD ID:",rec$record_id,"TITLE:",rec$title,
                   "ABSTRACT:",rec$abstract,sep="\n"))))),
    text=list(verbosity="low",format=list(type="json_schema",
      name="review_geography",strict=TRUE,schema=schema)))
  response <- tryCatch({
    res <- req_perform(request("https://api.openai.com/v1/responses") |>
      req_auth_bearer_token(api_key) |> req_body_json(payload,auto_unbox=TRUE) |>
      req_timeout(120) |> req_retry(max_tries=3))
    raw <- resp_body_json(res,simplifyVector=FALSE)
    obj <- fromJSON(extract_text(raw),simplifyVector=FALSE)
    if(!obj$geography_status %in% c("RESOLVED","NONE","UNCERTAIN"))
      stop("Invalid geography status",call.=FALSE)
    if(identical(obj$geography_status,"RESOLVED") && !length(obj$locations))
      stop("RESOLVED requires a supported location",call.=FALSE)
    if(length(obj$locations)) for(loc in obj$locations) {
      evidence <- trimws(as.character(loc$evidence %||% ""))
      source <- paste(rec$title,rec$abstract)
      if(!nzchar(evidence) || !grepl(evidence,source,fixed=TRUE))
        stop("Geography evidence not grounded in title/abstract",call.=FALSE)
    }
    list(status="ok",coding=obj,usage=raw$usage %||% list())
  },error=function(e)list(status="needs_review",error=conditionMessage(e)))
  results[[i]] <- c(list(record_id=rec$record_id,title=rec$title,abstract=rec$abstract,
    record_sequence=i,source_input_sha256=sha(input_bytes),
    prompt_sha256=prompt_sha),response)
}
writeLines(vapply(results,function(z)toJSON(z,auto_unbox=TRUE,null="null"),character(1)),
           file.path(out,"w06_subset_results.jsonl"),useBytes=TRUE)
summary <- list(schema="lem-w06-shiny-subset-v1",review_id=review,model=model,
  source_w05_zenodo_id=w05_id,source_input_sha256=sha(input_bytes),
  prompt_zenodo_id=prompt_id,prompt_sha256=prompt_sha,
  corpus_records=length(lines),subset_records=count,
  completed=sum(vapply(results,function(z)identical(z$status,"ok"),logical(1))),
  needs_review=sum(vapply(results,function(z)identical(z$status,"needs_review"),logical(1))),
  mode="subset_test")
write_json(summary,file.path(out,"w06_subset_manifest.json"),auto_unbox=TRUE,pretty=TRUE)
cat(sprintf("PASS W06 topic-agnostic subset n=%d: %d completed; %d needs review\n",
  count,summary$completed,summary$needs_review))
