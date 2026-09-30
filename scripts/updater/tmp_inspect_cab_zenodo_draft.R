#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
})
token <- Sys.getenv("ZENODO_ACCESS_TOKEN")
if (!nzchar(token)) stop("ZENODO_ACCESS_TOKEN is not set", call.=FALSE)
id <- "23058344"
auth <- function(req) req |> req_headers(Authorization=paste("Bearer",token))
fetch <- function(url,label){
  r <- request(url)|>auth()|>req_timeout(60)|>req_error(is_error=function(resp) FALSE)|>req_perform()
  cat(sprintf("%s HTTP=%d\n",label,resp_status(r)))
  body <- tryCatch(resp_body_json(r,simplifyVector=FALSE),error=function(e) NULL)
  if (!is.null(body)) {
    if (!is.null(body$entries)) {
      cat(sprintf("%s entries=%d\n",label,length(body$entries)))
      for (e in body$entries) {
        key <- if (!is.null(e$key)) as.character(e$key[[1L]]) else if (!is.null(e$filename)) as.character(e$filename[[1L]]) else "<none>"
        status <- if (!is.null(e$status)) as.character(e$status[[1L]]) else "<none>"
        size <- if (!is.null(e$size)) e$size else if (!is.null(e$filesize)) e$filesize else NA
        cat(sprintf("%s FILE key=%s status=%s size=%s\n",label,key,status,as.character(size)))
      }
    } else if (is.list(body) && is.null(names(body))) {
      cat(sprintf("%s entries=%d\n",label,length(body)))
      for (e in body) {
        key <- if (!is.null(e$key)) as.character(e$key[[1L]]) else if (!is.null(e$filename)) as.character(e$filename[[1L]]) else "<none>"
        cat(sprintf("%s FILE key=%s\n",label,key))
      }
    } else {
      cat(sprintf("%s BODY_KEYS=%s\n",label,paste(names(body),collapse=",")))
    }
  } else {
    cat(sprintf("%s BODY=%s\n",label,tryCatch(resp_body_string(r),error=function(e)"<unreadable>")))
  }
}
fetch(sprintf("https://zenodo.org/api/records/%s/draft",id),"RDM_DRAFT")
fetch(sprintf("https://zenodo.org/api/records/%s/draft/files",id),"RDM_FILES")
fetch(sprintf("https://zenodo.org/api/deposit/depositions/%s",id),"LEGACY_DRAFT")
fetch(sprintf("https://zenodo.org/api/deposit/depositions/%s/files",id),"LEGACY_FILES")
