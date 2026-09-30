#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
  library(digest)
})
token <- Sys.getenv("ZENODO_ACCESS_TOKEN")
if (!nzchar(token)) stop("ZENODO_ACCESS_TOKEN is not set", call.=FALSE)
draft_id <- "23058211"
name <- "workflow00_upload_canary.txt"
payload <- charToRaw("LivingEvidenceMap Workflow 00 Zenodo upload canary\n")
auth <- function(req) req |> req_headers(Authorization=paste("Bearer",token))
perform <- function(req, expected, label, timeout=120) {
  resp <- req |> req_timeout(timeout) |> req_error(is_error=function(resp) FALSE) |> req_perform()
  st <- resp_status(resp)
  if (!(st %in% expected)) stop(sprintf("%s HTTP %d: %s",label,st,tryCatch(resp_body_string(resp),error=function(e)"")),call.=FALSE)
  resp
}
files_url <- sprintf("https://zenodo.org/api/records/%s/draft/files", draft_id)
entry_url <- paste0(files_url,"/",URLencode(name,reserved=TRUE))

# Ensure no stale canary exists.
resp <- request(entry_url) |> auth() |> req_error(is_error=function(resp) FALSE) |> req_perform()
if (resp_status(resp)==200L) perform(request(entry_url)|>req_method("DELETE")|>auth(),c(200L,204L),"delete stale canary")

# Initialise exactly one named file.
perform(
  request(files_url)|>req_method("POST")|>auth()|>
    req_headers("Content-Type"="application/json")|>
    req_body_json(list(list(key=name)),auto_unbox=TRUE),
  c(200L,201L),"initialise canary"
)

entry <- resp_body_json(perform(request(entry_url)|>auth(),200L,"read initialised canary"),simplifyVector=FALSE)
content_url <- entry$links$content[[1L]]
commit_url <- entry$links$commit[[1L]]
perform(
  request(content_url)|>req_method("PUT")|>auth()|>
    req_headers("Content-Type"="application/octet-stream",Expect="")|>
    req_body_raw(payload),
  c(200L,201L),"upload canary content"
)
perform(request(commit_url)|>req_method("POST")|>auth(),c(200L,201L,202L),"commit canary")

# Verify exact bytes.
verify <- perform(request(paste0(entry_url,"/content"))|>auth(),200L,"download canary")
got <- resp_body_raw(verify)
if (!identical(got,payload)) stop("Canary content mismatch",call.=FALSE)

# Delete and verify absence.
perform(request(entry_url)|>req_method("DELETE")|>auth(),c(200L,204L,504L),"delete canary")
Sys.sleep(2)
chk <- request(entry_url)|>auth()|>req_error(is_error=function(resp) FALSE)|>req_perform()
if (resp_status(chk)==200L) stop("Canary still exists after delete",call.=FALSE)

cat("PASS: Zenodo modern-draft initialise/upload/commit/verify/delete canary succeeded\n")
