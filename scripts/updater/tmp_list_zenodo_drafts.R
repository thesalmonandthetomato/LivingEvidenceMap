#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
})
token <- Sys.getenv("ZENODO_ACCESS_TOKEN")
if (!nzchar(token)) stop("ZENODO_ACCESS_TOKEN is not set",call.=FALSE)
auth <- function(req) req |> req_headers(Authorization=paste("Bearer",token))
resp <- request("https://zenodo.org/api/deposit/depositions?status=draft&size=100&page=1") |>
  auth() |> req_timeout(60) |> req_error(is_error=function(resp) FALSE) |> req_perform()
if (resp_status(resp)!=200L) stop(sprintf("HTTP %d: %s",resp_status(resp),resp_body_string(resp)),call.=FALSE)
items <- resp_body_json(resp,simplifyVector=FALSE)
for (d in items) {
  id <- if (is.null(d$id)) "<none>" else as.character(d$id)
  doi <- if (!is.null(d$metadata$prereserve_doi$doi)) as.character(d$metadata$prereserve_doi$doi[[1L]]) else
         if (!is.null(d$doi)) as.character(d$doi[[1L]]) else "<none>"
  title <- if (!is.null(d$title)) as.character(d$title[[1L]]) else
           if (!is.null(d$metadata$title)) as.character(d$metadata$title[[1L]]) else "<none>"
  nfiles <- if (is.null(d$files)) 0L else length(d$files)
  cat(sprintf("DRAFT id=%s doi=%s files=%d title=%s\n",id,doi,nfiles,title))
}
