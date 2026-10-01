#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
  library(xml2)
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
ebsco_config_path <- arg("--ebsco-config", "config/workflow00_ebsco_sources.json")
output_csv <- arg("--output-csv")
output_json <- arg("--output-json")
if (any(vapply(list(plan_path, output_csv, output_json), is.null, logical(1)))) {
  stop("Required: --plan --output-csv --output-json", call. = FALSE)
}
if (!file.exists(plan_path)) stop("Search plan not found", call. = FALSE)
if (!file.exists(lens_config_path)) stop("Lens config not found", call. = FALSE)
if (!file.exists(ebsco_config_path)) stop("EBSCO config not found", call. = FALSE)

now_utc <- function() format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ")
search_date <- format(Sys.Date(), "%Y-%m-%d")
plan <- fromJSON(plan_path, simplifyVector = FALSE)
q <- plan$source_queries

ebsco_cfg <- fromJSON(ebsco_config_path,simplifyVector=FALSE)
ebsco_sources <- names(ebsco_cfg$sources)
required_queries <- c("lens", "scopus", "openalex", "agricola", "pubmed", "ethos", "cba", "epmc_preprints", "wos", ebsco_sources)
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
  token <- trimws(Sys.getenv("SCOPUS_API_TOKEN", ""))
  inst_token <- trimws(Sys.getenv("SCOPUS_INSTTOKEN", ""))
  if (!nzchar(token)) stop("SCOPUS_API_TOKEN is required", call. = FALSE)
  if (!nzchar(inst_token)) stop("SCOPUS_INSTTOKEN is required", call. = FALSE)
  req <- request("https://api.elsevier.com/content/search/scopus") |>
    req_headers(
      Accept = "application/json",
      `X-ELS-APIKey` = token,
      `X-ELS-Insttoken` = inst_token,
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

count_europe_pmc <- function(query, label) {
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
  resp <- retry_request(req, label)
  x <- fromJSON(resp_body_string(resp), simplifyVector = FALSE)
  n <- scalar_int(x$hitCount)
  if (is.na(n)) stop(sprintf("%s response did not contain hitCount", label), call. = FALSE)
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

count_ebsco <- function(source_slug, query) {
  uid <- trimws(Sys.getenv("EBSCO_EHOST_UID",""))
  pwd <- trimws(Sys.getenv("EBSCO_EHOST_PWD",""))
  if (!nzchar(uid) || !nzchar(pwd)) stop("EBSCO_EHOST_UID and EBSCO_EHOST_PWD are required",call.=FALSE)
  src <- ebsco_cfg$sources[[source_slug]]
  if (is.null(src)) stop(sprintf("Unknown EBSCO source: %s",source_slug),call.=FALSE)
  req <- request("https://eit.ebscohost.com/Services/SearchService.asmx/Search") |>
    req_url_query(
      prof=uid,
      pwd=pwd,
      authType="profile",
      db=as.character(src$db_code),
      query=query,
      format="detailed",
      startrec="1",
      numrec="1"
    ) |>
    req_error(is_error=function(resp) FALSE)
  resp <- retry_request(req,as.character(src$display_name))
  doc <- read_xml(resp_body_raw(resp))
  hit_nodes <- xml_find_all(doc,"//*[local-name()='Hits']")
  vals <- suppressWarnings(as.integer(trimws(xml_text(hit_nodes))))
  vals <- vals[!is.na(vals)]
  if (!length(vals)) stop(sprintf("%s response did not contain Hits",as.character(src$display_name)),call.=FALSE)
  vals[[1L]]
}

safe_count <- function(label, fun) {
  message(sprintf("Counting %s...", label))
  tryCatch({
    n <- as.integer(fun())
    message(sprintf("%s: %d", label, n))
    list(hits=n,status="counted live")
  }, error=function(e) {
    message(sprintf("%s FAILED: %s", label, conditionMessage(e)))
    list(hits=NA_integer_,status=paste0("API count failed: ",conditionMessage(e)))
  })
}

lens_r <- safe_count("Lens", function() count_lens(as.character(q$lens)))
scopus_r <- safe_count("Scopus", function() count_scopus(as.character(q$scopus)))
openalex_r <- safe_count("OpenAlex", function() count_openalex(as.character(q$openalex)))
agricola_r <- safe_count("AGRICOLA", function() count_europe_pmc(as.character(q$agricola),"AGRICOLA/Europe PMC"))
pubmed_r <- safe_count("PubMed/MEDLINE", function() count_europe_pmc(as.character(q$pubmed),"PubMed/MEDLINE via Europe PMC"))
ethos_r <- safe_count("EThOS", function() count_europe_pmc(as.character(q$ethos),"EThOS via Europe PMC"))
cba_r <- safe_count("Chinese Biological Abstracts", function() count_europe_pmc(as.character(q$cba),"Chinese Biological Abstracts via Europe PMC"))
preprints_r <- safe_count("Europe PMC preprints", function() count_europe_pmc(as.character(q$epmc_preprints),"Europe PMC preprints"))
wos_r <- safe_count("Web of Science", function() count_wos(as.character(q$wos)))

ebsco_results <- lapply(ebsco_sources,function(src) {
  label <- as.character(ebsco_cfg$sources[[src]]$display_name)
  safe_count(label,function() count_ebsco(src,as.character(q[[src]])))
})
names(ebsco_results) <- ebsco_sources

read_manual_reported <- function(path) {
  if (!file.exists(path)) return(NA_integer_)
  x <- fromJSON(path, simplifyVector=FALSE)
  suppressWarnings(as.integer(x$search$reported_results))
}
cab_n <- read_manual_reported("user_input/workflow00_ris_cab_abstracts_2026-09-30.json")
proquest_n <- read_manual_reported("user_input/workflow00_ris_proquest_2026-09-30.json")

rows <- data.frame(
  source = c(
    "Lens",
    "Scopus",
    "OpenAlex",
    "AGRICOLA",
    "PubMed/MEDLINE",
    "EThOS",
    "Chinese Biological Abstracts",
    "Europe PMC preprints",
    "Web of Science Core Collection",
    vapply(ebsco_sources,function(src) as.character(ebsco_cfg$sources[[src]]$display_name),character(1)),
    "CAB Abstracts",
    "ProQuest Dissertations & Theses Global"
  ),
  access_mode = c(
    rep("API count", 9 + length(ebsco_sources)),
    "Manual W00 registry count",
    "Manual W00 registry count"
  ),
  search_date = c(rep(search_date, 9 + length(ebsco_sources)), "2026-09-30", "2026-09-30"),
  hits = c(
    lens_r$hits, scopus_r$hits, openalex_r$hits, agricola_r$hits, pubmed_r$hits,
    ethos_r$hits, cba_r$hits, preprints_r$hits, wos_r$hits,
    vapply(ebsco_results,function(x) if(is.null(x$hits)) NA_integer_ else as.integer(x$hits),integer(1)),
    cab_n, proquest_n
  ),
  status = c(
    lens_r$status, scopus_r$status, openalex_r$status, agricola_r$status, pubmed_r$status,
    ethos_r$status, cba_r$status, preprints_r$status, wos_r$status,
    vapply(ebsco_results,function(x) as.character(x$status),character(1)),
    "validated W00 manual-search reported count",
    "validated W00 manual-search reported count"
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
