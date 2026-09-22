#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag), call.=FALSE)
  args[[i+1L]]
}
source <- arg("--source")
run_type <- arg("--run-type")
query <- arg("--query")
reported <- suppressWarnings(as.integer(arg("--reported-results")))
downloaded <- suppressWarnings(as.integer(arg("--downloaded-results")))
parent_run_id <- arg("--parent-run-id")
child_run_id <- arg("--child-run-id", Sys.getenv("GITHUB_RUN_ID","unknown"))
run_attempt <- arg("--run-attempt", Sys.getenv("GITHUB_RUN_ATTEMPT","1"))
artifact_name <- arg("--artifact-name","")
search_version <- arg("--search-version","")
additional_farm_term <- arg("--additional-farm-term","")
output_root <- arg("--output-root","outputs/updater/search_record")

req <- c(source,run_type,query,parent_run_id)
if (any(vapply(req,function(x)is.null(x)||!nzchar(x),logical(1)))) stop("source, run-type, query and parent-run-id are required",call.=FALSE)
if (is.na(reported) || reported < 0L) stop("reported-results must be >= 0",call.=FALSE)
if (is.na(downloaded) || downloaded < 0L) stop("downloaded-results must be >= 0",call.=FALSE)
if (!(run_type %in% c("full","fortnightly","quarterly","expansion"))) stop("invalid run-type",call.=FALSE)

folder <- switch(run_type, full="full_search", fortnightly="fortnightly_update", quarterly="quarterly_sweep", expansion="ad_hoc")
stamp <- format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H-%M-%SZ")
safe_source <- gsub("[^a-z0-9_-]+","_",tolower(source))
base <- sprintf("%s_%s_parent-%s_child-%s_attempt-%s",stamp,safe_source,parent_run_id,child_run_id,run_attempt)
dir <- file.path(output_root,folder)
dir.create(dir,recursive=TRUE,showWarnings=FALSE)

record <- list(
  schema_version="1.0",
  recorded_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ"),
  source=source,
  run_type=run_type,
  search_version=if(nzchar(search_version)) search_version else NULL,
  additional_farm_term=if(nzchar(additional_farm_term)) additional_farm_term else NULL,
  search_string=query,
  reported_search_results=reported,
  successfully_downloaded_results=downloaded,
  complete_download=identical(reported,downloaded),
  github=list(repository=Sys.getenv("GITHUB_REPOSITORY",""), parent_workflow_run_id=parent_run_id, child_workflow_run_id=child_run_id, run_attempt=run_attempt, ref=Sys.getenv("GITHUB_REF_NAME",""), sha=Sys.getenv("GITHUB_SHA","")),
  artifact_name=if(nzchar(artifact_name)) artifact_name else NULL
)

json_path <- file.path(dir,paste0(base,".json"))
md_path <- file.path(dir,paste0(base,".md"))
writeLines(toJSON(record,auto_unbox=TRUE,pretty=TRUE,null="null"),json_path)

md <- c(
  sprintf("# Search record: %s", source),
  "",
  sprintf("- **Date (UTC):** %s", record$recorded_at_utc),
  sprintf("- **Run type:** %s", run_type),
  sprintf("- **Search version:** %s", if(nzchar(search_version)) search_version else "not supplied"),
  sprintf("- **Source:** %s", source),
  sprintf("- **Results reported by source:** %d", reported),
  sprintf("- **Results successfully downloaded:** %d", downloaded),
  sprintf("- **Complete download:** %s", if(reported==downloaded) "yes" else "no"),
  sprintf("- **Parent workflow run:** %s", parent_run_id),
  sprintf("- **Child workflow run:** %s (attempt %s)", child_run_id, run_attempt),
  sprintf("- **Harvest artifact:** %s", if(nzchar(artifact_name)) artifact_name else "not supplied"),
  "",
  "## Search string",
  "",
  "```text",
  query,
  "```"
)
if (nzchar(additional_farm_term)) {
  md <- c(md,"","## Ad hoc expansion","","The immutable species block was unchanged.", sprintf("Additional farm/aquaculture term: `%s`",additional_farm_term))
}
writeLines(md,md_path)
cat(sprintf("SEARCH_RECORD_JSON=%s\nSEARCH_RECORD_MD=%s\n",json_path,md_path))