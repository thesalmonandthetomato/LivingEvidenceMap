#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

source_slug <- arg("--source")
query <- arg("--query")
config_path <- arg("--config","config/workflow00_ebsco_sources.json")
output_dir <- arg("--output-dir","outputs/updater/source_child")
if (is.null(source_slug) || is.null(query)) stop("--source and --query are required",call.=FALSE)
if (!file.exists(config_path)) stop("EBSCO source config not found",call.=FALSE)

uid <- Sys.getenv("EBSCO_EHOST_UID")
pwd <- Sys.getenv("EBSCO_EHOST_PWD")
if (!nzchar(uid) || !nzchar(pwd)) stop("EBSCO_EHOST_UID and EBSCO_EHOST_PWD are required",call.=FALSE)

cfg <- fromJSON(config_path,simplifyVector=FALSE)
src <- cfg$sources[[source_slug]]
if (is.null(src)) stop(sprintf("Unknown EBSCO source: %s",source_slug),call.=FALSE)
db_code <- as.character(src$db_code)
db_name <- as.character(src$display_name)

req <- request("https://eit.ebscohost.com/Services/SearchService.asmx/Search") |>
  req_url_query(
    prof=uid,
    pwd=pwd,
    authType="profile",
    db=db_code,
    query=query,
    format="detailed",
    startrec="1",
    numrec="1"
  ) |>
  req_timeout(180) |>
  req_error(is_error=function(resp) FALSE)
resp <- req_perform(req)
if (resp_status(resp) != 200L) stop(sprintf("EBSCO %s returned HTTP %d",source_slug,resp_status(resp)),call.=FALSE)
txt <- resp_body_string(resp)

m <- regexpr("<Hits[^>]*>[[:space:]]*([0-9]+)[[:space:]]*</Hits>",txt,perl=TRUE)
if (m[[1]] < 0L) stop(sprintf("EBSCO %s response did not contain Hits",source_slug),call.=FALSE)
hit_tag <- regmatches(txt,m)
hits <- suppressWarnings(as.integer(sub(".*<Hits[^>]*>[[:space:]]*([0-9]+)[[:space:]]*</Hits>.*","\\1",hit_tag,perl=TRUE)))
if (is.na(hits)) stop(sprintf("Could not parse EBSCO hit count for %s",source_slug),call.=FALSE)

dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)
manifest <- list(
  workflow="workflow_00h_ebsco_scope_count",
  status="success",
  source=source_slug,
  database_code=db_code,
  database_name=db_name,
  query=query,
  reported_total=hits,
  records_retrieved=0L,
  count_only=TRUE,
  result_policy="Count only. No bibliographic records or raw API responses persisted.",
  generated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null"),file.path(output_dir,"manifest.json"))
cat(sprintf("PASS: EBSCO scoping source=%s db=%s hits=%d\n",source_slug,db_code,hits))
