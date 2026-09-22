#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
})

api_key <- Sys.getenv("WOS_STARTER_API", unset = "")
if (!nzchar(api_key)) stop("WOS_STARTER_API secret is not available", call. = FALSE)

query <- '((TI=((salmon OR salmonid* OR Salmo OR Oncorhynchus OR "rainbow trout") AND (farm* OR cage* OR pens OR penned OR pen OR aquacultur* OR commercial*))) OR (AB=((salmon OR salmonid* OR Salmo OR Oncorhynchus OR "rainbow trout") AND (farm* OR cage* OR pens OR penned OR pen OR aquacultur* OR commercial*))) OR (AK=((salmon OR salmonid* OR Salmo OR Oncorhynchus OR "rainbow trout") AND (farm* OR cage* OR pens OR penned OR pen OR aquacultur* OR commercial*)))) AND DO=10.*'
out_dir <- "outputs/updater/wos_starter_diagnostic"
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

req <- request("https://api.clarivate.com/apis/wos-starter/v1/documents") |>
  req_headers(`X-ApiKey` = api_key) |>
  req_url_query(
    q = query,
    db = "WOS",
    limit = 50,
    page = 1
  )

resp <- req_perform(req)
status <- resp_status(resp)
raw_text <- resp_body_string(resp)
writeLines(raw_text, file.path(out_dir, "raw_response.json"))

if (status < 200L || status >= 300L) {
  writeLines(toJSON(list(status=status, query=query, response=raw_text),
                    auto_unbox=TRUE, pretty=TRUE),
             file.path(out_dir, "diagnostic.json"))
  stop(sprintf("WoS Starter API returned HTTP %d", status), call. = FALSE)
}

obj <- fromJSON(raw_text, simplifyVector = FALSE)

collect_paths <- function(x, prefix = "") {
  out <- character()
  if (is.list(x)) {
    nms <- names(x)
    if (!is.null(nms)) {
      for (nm in nms) {
        p <- if (nzchar(prefix)) paste0(prefix, ".", nm) else nm
        out <- c(out, p, collect_paths(x[[nm]], p))
      }
    } else {
      for (i in seq_along(x)) {
        p <- paste0(prefix, "[]")
        out <- c(out, collect_paths(x[[i]], p))
      }
    }
  }
  unique(out)
}

paths <- sort(unique(collect_paths(obj)))
writeLines(paths, file.path(out_dir, "field_paths.txt"))

`%||%` <- function(x,y) if (is.null(x)) y else x
metadata <- obj$metadata %||% list()
total <- metadata$total %||% NA_integer_

# Locate the record array without assuming a single response schema.
candidate_arrays <- list(
  hits = obj$hits,
  documents = obj$documents,
  data = obj$data
)
record_name <- names(candidate_arrays)[vapply(candidate_arrays, function(z) is.list(z) && length(z) > 0L, logical(1))][1]
records <- if (!is.na(record_name) && length(record_name)) candidate_arrays[[record_name]] else list()

# If a wrapper contains the actual records, unwrap common variants.
if (length(records) == 1L && is.list(records[[1L]]) && is.null(names(records))) {
  records <- records[[1L]]
}
if (is.list(records) && !is.null(names(records)) && any(c("hits","records","documents") %in% names(records))) {
  nm <- intersect(c("hits","records","documents"), names(records))[1]
  records <- records[[nm]]
}

record_paths <- if (length(records)) sort(unique(unlist(lapply(records, collect_paths)))) else character()

has_path <- function(pattern) any(grepl(pattern, record_paths, ignore.case = TRUE, perl = TRUE))

report <- list(
  status = "success",
  endpoint = "https://api.clarivate.com/apis/wos-starter/v1/documents",
  database = "WOS",
  query = query,
  page = 1,
  limit = 50,
  metadata_total = total,
  records_returned_on_page = length(records),
  field_presence_first_page = list(
    abstract = has_path("abstract"),
    funding_or_funder = has_path("fund|funder|grant"),
    affiliations_or_addresses = has_path("affiliat|address|organization"),
    doi = has_path("doi"),
    title = has_path("title"),
    authors = has_path("author|names"),
    author_keywords = has_path("keyword"),
    source = has_path("source"),
    publication_date_or_year = has_path("publish|date|year"),
    document_type = has_path("doctype|document.?type|types"),
    issn = has_path("issn"),
    isbn = has_path("isbn"),
    pubmed_id = has_path("pubmed|pmid"),
    times_cited = has_path("times.?cited|citations"),
    researcher_id = has_path("researcher")
  ),
  record_field_paths = record_paths,
  top_level_field_paths = paths
)

writeLines(toJSON(report, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null"),
           file.path(out_dir, "diagnostic.json"))
cat(toJSON(report, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null"), "\n")
