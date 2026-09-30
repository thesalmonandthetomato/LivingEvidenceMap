#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
})

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s", flag), call. = FALSE)
  args[[i + 1L]]
}

plan_path <- arg("--plan")
lens_config_path <- arg("--lens-config", "config/lens_search.json")
output_csv <- arg("--output-csv")
output_json <- arg("--output-json")
if (any(vapply(list(plan_path, output_csv, output_json), is.null, logical(1)))) {
  stop("Required: --plan --output-csv --output-json", call. = FALSE)
}
if (!file.exists(plan_path)) stop("Search plan not found", call. = FALSE)
if (!file.exists(lens_config_path)) stop("Lens config not found", call. = FALSE)

now_utc <- function() format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ")
search_date <- format(Sys.Date(), "%Y-%m-%d")
plan <- fromJSON(plan_path, simplifyVector = FALSE)
q <- plan$source_queries

required_queries <- c("lens", "scopus", "openalex", "agricola", "wos")
missing_queries <- required_queries[vapply(required_queries, function(x) is.null(q[[x]]) || !nzchar(trimws(as.character(q[[x]]))), logical(1))]
if (length(missing_queries)) stop(sprintf("Search plan missing source queries: %s", paste(missing_queries, collapse = ", ")), call. = FALSE)

retry_request <- function(req, label) {
  last <- NULL
  for (attempt in seq_len(6L)) {
    resp <- tryCatch(req_perform(req), error = identity)
    if (!inherits(resp, "error")) {
      status <- resp_status(resp)
      if (status < 400L) return(resp)
      body <- tryCatch(resp_body_string(resp), error = function(e) "")
      last <- sprintf("%s HTTP %d: %s", label, status, substr(body, 1L, 1000L))
      if (!(status == 429L || status >= 500L)) stop(last, call. = FALSE)
    } else {
      last <- conditionMessage(resp)
    }
    if (attempt < 6L) Sys.sleep(min(30, 2^(attempt - 1L)))
  }
  stop(sprintf("%s count request failed after 6 attempts: %s", label, last), call. = FALSE)
}

scalar_int <- function(x) {
  if (is.null(x) || !length(x)) return(NA_integer_)
  suppressWarnings(as.integer(as.character(x[[1L]])))
}

count_lens <- function(query) {
  token <- Sys.getenv("LENS_API_TOKEN", "")
  if (!nzchar(token)) stop("LENS_API_TOKEN is required", call. = FALSE)
  cfg <- fromJSON(lens_config_path, simplifyVector = FALSE)
  cfg$api_query$query$bool$must[[1L]]$query_string$query <- query
  payload <- list(query = cfg$api_query$query, size = 1L)
  req <- request("https://api.lens.org/scholarly/search") |>
    req_headers(
      Authorization = paste("Bearer", token),
      `Content-Type` = "application/json",
      Accept = "application/json"
    ) |>
    req_body_json(payload, auto_unbox = TRUE)
  resp <- retry_request(req, "Lens")
  x <- resp_body_json(resp, simplifyVector = FALSE)
  n <- scalar_int(x$total)
  if (is.na(n)) stop("Lens response did not contain total", call. = FALSE)
  n
}

count_scopus <- function(query) {
  token <- Sys.getenv("SCOPUS_API_TOKEN", "")
  if (!nzchar(token)) stop("SCOPUS_API_TOKEN is required", call. = FALSE)
  req <- request("https://api.elsevier.com/content/search/scopus") |>
    req_headers(
      Accept = "application/json",
      `X-ELS-APIKey` = token,
      `User-Agent` = "LivingEvidenceMap W00 search scoping"
    ) |>
    req_url_query(query = query, start = 0L, count = 1L, view = "STANDARD") |>
    req_error(is_error = function(resp) FALSE)
  resp <- retry_request(req, "Scopus")
  x <- fromJSON(resp_body_string(resp), simplifyVector = FALSE)
  n <- scalar_int(x[["search-results"]][["opensearch:totalResults"]])
  if (is.na(n)) stop("Scopus response did not contain opensearch:totalResults", call. = FALSE)
  n
}

count_openalex <- function(query) {
  token <- Sys.getenv("OPENALEX_API_KEY", "")
  if (!nzchar(token)) token <- Sys.getenv("OPENALEX_API_TOKEN", "")
  if (!nzchar(token)) stop("OPENALEX_API_KEY or OPENALEX_API_TOKEN is required", call. = FALSE)
  req <- request("https://api.openalex.org/") |>
    req_headers(
      Accept = "application/json",
      Authorization = paste("Bearer", token),
      `User-Agent` = "LivingEvidenceMap W00 search scoping"
    ) |>
    req_url_query(oql = query, `per-page` = 1L, cursor = "*") |>
    req_error(is_error = function(resp) FALSE)
  resp <- retry_request(req, "OpenAlex")
  x <- fromJSON(resp_body_string(resp), simplifyVector = FALSE)
  n <- scalar_int(x$meta$count)
  if (is.na(n)) stop("OpenAlex response did not contain meta.count", call. = FALSE)
  n
}

count_agricola <- function(query) {
  req <- request("https://www.ebi.ac.uk/europepmc/webservices/rest/search") |>
    req_headers(Accept = "application/json", `User-Agent` = "LivingEvidenceMap W00 search scoping") |>
    req_url_query(
      query = query,
      format = "json",
      resultType = "core",
      pageSize = 1L,
      cursorMark = "*",
      synonym = "false"
    ) |>
    req_error(is_error = function(resp) FALSE)
  resp <- retry_request(req, "AGRICOLA/Europe PMC")
  x <- fromJSON(resp_body_string(resp), simplifyVector = FALSE)
  n <- scalar_int(x$hitCount)
  if (is.na(n)) stop("AGRICOLA response did not contain hitCount", call. = FALSE)
  n
}

count_wos <- function(query) {
  token <- Sys.getenv("WOS_STARTER_API", "")
  if (!nzchar(token)) stop("WOS_STARTER_API is required", call. = FALSE)
  req <- request("https://api.clarivate.com/apis/wos-starter/v1/documents") |>
    req_headers(
      Accept = "application/json",
      `X-ApiKey` = token,
      `User-Agent` = "LivingEvidenceMap W00 search scoping"
    ) |>
    req_url_query(q = query, db = "WOS", limit = 1L, page = 1L) |>
    req_error(is_error = function(resp) FALSE)
  resp <- retry_request(req, "Web of Science")
  x <- fromJSON(resp_body_string(resp), simplifyVector = FALSE)
  n <- scalar_int(x$metadata$total)
  if (is.na(n)) stop("Web of Science response did not contain metadata.total", call. = FALSE)
  n
}

message("Counting Lens...")
lens_n <- count_lens(as.character(q$lens))
message(sprintf("Lens: %d", lens_n))
message("Counting Scopus...")
scopus_n <- count_scopus(as.character(q$scopus))
message(sprintf("Scopus: %d", scopus_n))
message("Counting OpenAlex...")
openalex_n <- count_openalex(as.character(q$openalex))
message(sprintf("OpenAlex: %d", openalex_n))
message("Counting AGRICOLA...")
agricola_n <- count_agricola(as.character(q$agricola))
message(sprintf("AGRICOLA: %d", agricola_n))
message("Counting Web of Science...")
wos_n <- count_wos(as.character(q$wos))
message(sprintf("Web of Science: %d", wos_n))

rows <- data.frame(
  source = c(
    "Lens",
    "Scopus",
    "OpenAlex",
    "AGRICOLA",
    "Web of Science Core Collection",
    "CAB Abstracts",
    "ProQuest Dissertations & Theses Global"
  ),
  access_mode = c(
    rep("API count", 5),
    "Manual search source",
    "Manual search source"
  ),
  search_date = rep(search_date, 7),
  hits = c(lens_n, scopus_n, openalex_n, agricola_n, wos_n, NA_integer_, NA_integer_),
  status = c(
    rep("counted", 5),
    "not counted: no W00 API implementation",
    "not counted: no W00 API implementation"
  ),
  stringsAsFactors = FALSE
)

dir.create(dirname(output_csv), recursive = TRUE, showWarnings = FALSE)
write.csv(rows, output_csv, row.names = FALSE, na = "")

out <- list(
  schema = "living-evidence-map-workflow00-search-scoping-v1",
  workflow = "00_search_scoping",
  status = "success",
  counted_at_utc = now_utc(),
  search_date = search_date,
  search_input_path = plan$input_path,
  original_search_string = plan$original_search_string,
  normalised_search_string = plan$normalised_search_string,
  boolean_validation = plan$validation,
  source_queries = q,
  result_policy = "Counts only. No search-result records or raw API responses are written to disk.",
  counts = lapply(seq_len(nrow(rows)), function(i) {
    list(
      source = rows$source[[i]],
      access_mode = rows$access_mode[[i]],
      search_date = rows$search_date[[i]],
      hits = if (is.na(rows$hits[[i]])) NULL else as.integer(rows$hits[[i]]),
      status = rows$status[[i]]
    )
  })
)
writeLines(toJSON(out, auto_unbox = TRUE, pretty = TRUE, null = "null"), output_json, useBytes = TRUE)
cat("PASS: Workflow 00 search scoping counts complete; no result records persisted.\n")
