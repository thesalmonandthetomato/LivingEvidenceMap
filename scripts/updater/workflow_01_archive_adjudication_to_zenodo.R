#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

staging_root <- normalizePath(arg("--staging-root"),mustWork=TRUE)
adjudication_run_id <- arg("--adjudication-run-id")
source_workflow01_run_id <- arg("--source-workflow01-run-id")
repository <- arg("--repository")
derived_from_record <- arg("--derived-from-record")
output_dir <- arg("--output-dir")
if (any(vapply(list(adjudication_run_id,source_workflow01_run_id,repository,derived_from_record,output_dir),is.null,logical(1)))) {
  stop("Required: --staging-root --adjudication-run-id --source-workflow01-run-id --repository --derived-from-record --output-dir",call.=FALSE)
}
summary_path <- file.path(staging_root,"summary.json")
if (!file.exists(summary_path)) stop("Adjudication summary.json missing",call.=FALSE)
summary <- fromJSON(summary_path,simplifyVector=FALSE)
state <- as.character(summary$status)
if (!(state %in% c("awaiting_human_review","llm_adjudication_complete"))) stop("Unexpected adjudication state",call.=FALSE)

token <- Sys.getenv("ZENODO_ACCESS_TOKEN")
if (!nzchar(token)) stop("ZENODO_ACCESS_TOKEN is required",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)
output_dir <- normalizePath(output_dir,mustWork=TRUE)
archive_dir <- file.path(output_dir,"archive_files")
dir.create(archive_dir,recursive=TRUE,showWarnings=FALSE)

all_paths <- list.files(staging_root,recursive=TRUE,full.names=TRUE,all.files=TRUE,no..=TRUE)
if (length(all_paths)) suppressWarnings(Sys.setFileTime(all_paths,as.POSIXct("2000-01-01",tz="UTC")))

filename <- sprintf("LivingEvidenceMap_workflow01_adjudication-%s_%s.tar.gz",adjudication_run_id,state)
tar_path <- file.path(archive_dir,filename)
old <- setwd(dirname(staging_root)); on.exit(setwd(old),add=TRUE)
utils::tar(tar_path,files=basename(staging_root),compression="gzip",tar="internal")
setwd(old); on.exit(NULL,add=FALSE)
if (!file.exists(tar_path)||file.info(tar_path)$size<=0) stop("Failed to create adjudication archive",call.=FALSE)

manifest <- list(
  schema="living-evidence-map-workflow01-adjudication-state-v1",
  workflow="01",
  stage="duplicate_adjudication",
  state=state,
  source_workflow01_run_id=source_workflow01_run_id,
  adjudication_github_run_id=adjudication_run_id,
  repository=repository,
  derived_from_zenodo_record_id=derived_from_record,
  model=summary$model,
  auto_threshold=summary$auto_threshold,
  total_cases=as.integer(summary$total_cases),
  automatic_duplicate=as.integer(summary$automatic_duplicate),
  automatic_not_duplicate=as.integer(summary$automatic_not_duplicate),
  human_review_required=as.integer(summary$human_review_required),
  technical_failures=as.integer(summary$technical_failures),
  file_visibility="restricted",
  files=list(adjudication_archive=list(
    filename=filename,
    bytes=unname(file.info(tar_path)$size),
    sha256=digest(file=tar_path,algo="sha256",serialize=FALSE)
  ))
)
manifest_name <- sprintf("LivingEvidenceMap_workflow01_adjudication-%s_manifest.json",adjudication_run_id)
manifest_path <- file.path(archive_dir,manifest_name)
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null"),manifest_path)
archive_paths <- c(tar_path,manifest_path)

api <- "https://zenodo.org/api/deposit/depositions"
auth <- function(req) req |> req_headers(Authorization=paste("Bearer",token))
perform <- function(req,expected,label,timeout=600) {
  resp <- req |> req_timeout(timeout) |> req_error(is_error=function(resp)FALSE) |> req_perform()
  st <- resp_status(resp)
  if (!(st %in% expected)) {
    body <- tryCatch(resp_body_string(resp),error=function(e)"")
    stop(sprintf("Zenodo %s returned HTTP %d: %s",label,st,body),call.=FALSE)
  }
  resp
}
run_url <- sprintf("https://github.com/%s/actions/runs/%s",repository,adjudication_run_id)
title <- sprintf("Living Evidence Map duplicate adjudication | Workflow 01 run %s | %s",source_workflow01_run_id,state)
description <- paste0(
  "<p>Restricted duplicate-adjudication state for Living Evidence Map Workflow 01.</p>",
  "<p>Derived from Workflow 01 Zenodo record ",derived_from_record,
  ". Model adjudication run: <a href=\"",run_url,"\">",adjudication_run_id,"</a>.</p>",
  "<p>Total cases: ",summary$total_cases,
  "; automatic duplicate: ",summary$automatic_duplicate,
  "; automatic not duplicate: ",summary$automatic_not_duplicate,
  "; human review required: ",summary$human_review_required,
  "; technical failures: ",summary$technical_failures,".</p>"
)
metadata <- list(metadata=list(
  title=title,
  upload_type="dataset",
  publication_date=format(Sys.Date(),"%Y-%m-%d"),
  description=description,
  creators=list(list(name="Haddaway, Neal")),
  access_right="restricted",
  access_conditions="Contains bibliographic metadata and abstracts used for duplicate adjudication; access is restricted because source terms may limit redistribution.",
  keywords=list("Living Evidence Map","deduplication","LLM adjudication","Workflow 01",state),
  notes=paste0("Derived from Zenodo record ",derived_from_record,
               ". Source Workflow 01 run ",source_workflow01_run_id,
               ". Adjudication run ",adjudication_run_id,".")
))

created <- perform(
  request(api) |> req_method("POST") |> auth() |>
    req_headers("Content-Type"="application/json") |>
    req_body_raw(charToRaw("{}"),type="application/json"),
  201L,"draft creation",60
) |> resp_body_json(simplifyVector=FALSE)
dep_id <- as.character(created$id); bucket <- as.character(created$links$bucket)
if (!nzchar(dep_id)||!nzchar(bucket)) stop("Zenodo draft response missing id/bucket",call.=FALSE)

perform(
  request(paste0(api,"/",dep_id)) |> req_method("PUT") |> auth() |>
    req_headers("Content-Type"="application/json") |>
    req_body_json(metadata,auto_unbox=TRUE),
  200L,"metadata update",60
)

uploaded <- vector("list",length(archive_paths))
for(i in seq_along(archive_paths)) {
  p <- archive_paths[[i]]; fn <- basename(p)
  url <- paste0(bucket,"/",URLencode(fn,reserved=TRUE))
  ok <- NULL
  for(attempt in seq_len(5L)) {
    resp <- request(url) |> req_method("PUT") |> auth() |> req_headers(Expect="") |>
      req_body_file(p) |> req_timeout(1800) |> req_error(is_error=function(resp)FALSE) |> req_perform()
    st <- resp_status(resp)
    if (st %in% c(200L,201L)) { ok <- resp; break }
    if (!(st %in% c(429L,500L,502L,503L,504L)) || attempt==5L) {
      stop(sprintf("Zenodo upload failed for %s: HTTP %d",fn,st),call.=FALSE)
    }
    Sys.sleep(min(60,5*2^(attempt-1L)))
  }
  uploaded[[i]] <- resp_body_json(ok,simplifyVector=FALSE)
}

published <- perform(
  request(paste0(api,"/",dep_id,"/actions/publish")) |> req_method("POST") |> auth(),
  c(200L,201L,202L),"publish",120
) |> resp_body_json(simplifyVector=FALSE)

receipt <- list(
  status="published",
  workflow="01",
  stage="duplicate_adjudication",
  state=state,
  source_workflow01_run_id=source_workflow01_run_id,
  adjudication_github_run_id=adjudication_run_id,
  derived_from_zenodo_record_id=derived_from_record,
  model=summary$model,
  auto_threshold=summary$auto_threshold,
  total_cases=as.integer(summary$total_cases),
  automatic_duplicate=as.integer(summary$automatic_duplicate),
  automatic_not_duplicate=as.integer(summary$automatic_not_duplicate),
  human_review_required=as.integer(summary$human_review_required),
  technical_failures=as.integer(summary$technical_failures),
  zenodo_record_id=as.character(if(is.null(published$record_id))published$id else published$record_id),
  zenodo_deposition_id=dep_id,
  doi=if(is.null(published$doi))NA_character_ else published$doi,
  record_url=if(!is.null(published$links$html))published$links$html else paste0("https://zenodo.org/records/",dep_id),
  visibility="restricted",
  archive_files=lapply(seq_along(archive_paths),function(i)list(
    filename=basename(archive_paths[[i]]),
    bytes=unname(file.info(archive_paths[[i]])$size),
    sha256=digest(file=archive_paths[[i]],algo="sha256",serialize=FALSE),
    zenodo_checksum=if(is.null(uploaded[[i]]$checksum))NULL else uploaded[[i]]$checksum
  )),
  manifest_sha256=digest(file=manifest_path,algo="sha256",serialize=FALSE),
  published_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
writeLines(toJSON(receipt,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),
           file.path(output_dir,"zenodo_receipt.json"))
cat(sprintf("PASS: published Workflow 01 adjudication state %s as Zenodo record %s\n",
            state,receipt$zenodo_record_id))
