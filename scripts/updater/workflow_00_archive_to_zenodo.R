#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
or_else <- function(x,y) if (is.null(x)) y else x

staging_root <- normalizePath(arg("--staging-root"),mustWork=TRUE)
run_id <- arg("--run-id")
run_type <- arg("--run-type")
search_version <- arg("--search-version")
sources <- strsplit(arg("--sources",""),",",fixed=TRUE)[[1L]]
sources <- sources[nzchar(sources)]
repository <- arg("--repository")
output_dir <- arg("--output-dir")
if (any(vapply(list(run_id,run_type,search_version,repository,output_dir),is.null,logical(1))) || !length(sources)) {
  stop("Required: --staging-root --run-id --run-type --search-version --sources --repository --output-dir",call.=FALSE)
}
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)
output_dir <- normalizePath(output_dir,mustWork=TRUE)

token <- Sys.getenv("ZENODO_ACCESS_TOKEN")
if (!nzchar(token)) stop("ZENODO_ACCESS_TOKEN is not set",call.=FALSE)

allowed_sources <- c("lens","scopus","openalex","agricola","wos")
if (any(!sources %in% allowed_sources)) stop("Unexpected source in --sources",call.=FALSE)

api <- "https://zenodo.org/api/deposit/depositions"
marker <- paste0("LivingEvidenceMap-workflow00-run-",run_id)
run_url <- sprintf("https://github.com/%s/actions/runs/%s",repository,run_id)
archive_dir <- file.path(output_dir,"archive_files")
dir.create(archive_dir,recursive=TRUE,showWarnings=FALSE)

all_paths <- list.files(staging_root,recursive=TRUE,full.names=TRUE,all.files=TRUE,no..=TRUE)
if (length(all_paths)) suppressWarnings(Sys.setFileTime(all_paths,as.POSIXct("2000-01-01",tz="UTC")))

make_tar <- function(base,members,out) {
  members <- members[file.exists(file.path(base,members))]
  if (!length(members)) return(FALSE)
  old <- setwd(base); on.exit(setwd(old),add=TRUE)
  utils::tar(out,files=members,compression="gzip",tar="internal")
  if (!file.exists(out) || file.info(out)$size <= 0) stop(sprintf("Failed to create %s",out),call.=FALSE)
  TRUE
}

archive_paths <- character()
for (src in sources) {
  src_dir <- file.path(staging_root,"harvests",src)
  if (!dir.exists(src_dir)) stop(sprintf("Staged harvest missing for %s",src),call.=FALSE)
  out <- file.path(archive_dir,sprintf("LivingEvidenceMap_workflow00_run-%s_%s-harvest.tar.gz",run_id,src))
  make_tar(file.path(staging_root,"harvests"),src,out)
  archive_paths <- c(archive_paths,out)
}

doc_members <- c("plan","search_records")
if (dir.exists(file.path(staging_root,"expansion_reconciliation"))) {
  doc_members <- c(doc_members,"expansion_reconciliation")
}
doc_out <- file.path(archive_dir,sprintf("LivingEvidenceMap_workflow00_run-%s_search-documentation.tar.gz",run_id))
make_tar(staging_root,doc_members,doc_out)
archive_paths <- c(archive_paths,doc_out)

file_meta <- lapply(archive_paths,function(p) list(
  filename=basename(p),
  bytes=unname(file.info(p)$size),
  sha256=digest(file=p,algo="sha256",serialize=FALSE)
))
names(file_meta) <- basename(archive_paths)

manifest <- list(
  schema="living-evidence-map-workflow00-search-archive-v1",
  github_run_id=run_id,
  github_run_url=run_url,
  repository=repository,
  run_type=run_type,
  search_version=search_version,
  sources=sources,
  file_visibility="restricted",
  files=file_meta
)
manifest_path <- file.path(archive_dir,sprintf("LivingEvidenceMap_workflow00_run-%s_manifest.json",run_id))
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null"),manifest_path)
archive_paths <- c(archive_paths,manifest_path)

total_bytes <- sum(file.info(archive_paths)$size)
if (!is.finite(total_bytes) || total_bytes <= 0) stop("Archive payload is empty",call.=FALSE)
if (total_bytes > 49 * 1024^3) stop("Archive payload exceeds 49 GiB preflight limit",call.=FALSE)
if (length(archive_paths) > 100L) stop("Archive payload exceeds Zenodo 100-file limit",call.=FALSE)

auth_req <- function(url) request(url) |> req_auth_bearer_token(token) |> req_timeout(180)
body_json <- function(resp) resp_body_json(resp,simplifyVector=FALSE)

lookup <- auth_req(api) |> req_url_query(q=marker,size=100) |> req_perform()
existing <- body_json(lookup)
if (!is.list(existing)) existing <- list()

expected_title <- sprintf("Living Evidence Map search archive | %s | Workflow 00 run %s",run_type,run_id)
is_ours <- function(x) {
  kw <- or_else(x$metadata$keywords,character())
  identical(or_else(x$title,""),expected_title) || marker %in% unlist(kw,use.names=FALSE)
}
hits <- Filter(is_ours,existing)
published_hits <- Filter(function(x) isTRUE(x$submitted),hits)
draft_hits <- Filter(function(x) !isTRUE(x$submitted),hits)

if (length(published_hits)) {
  x <- published_hits[[1L]]
  remote <- x$files
  if (is.null(remote)) remote <- list()
  local_md5 <- setNames(vapply(archive_paths,function(p) digest(file=p,algo="md5",serialize=FALSE),character(1)),
                        basename(archive_paths))
  remote_md5 <- setNames(vapply(remote,function(z) sub("^md5:","",or_else(z$checksum,"")),character(1)),
                         vapply(remote,function(z) or_else(z$filename,or_else(z$key,"")),character(1)))
  if (!setequal(names(local_md5),names(remote_md5)) ||
      any(local_md5[sort(names(local_md5))] != remote_md5[sort(names(remote_md5))])) {
    stop(sprintf("Published Zenodo archive already exists for run %s but its files do not match the reproducible local payload",run_id),call.=FALSE)
  }
  receipt <- list(
    status="published",
    github_run_id=run_id,
    github_run_url=run_url,
    run_type=run_type,
    search_version=search_version,
    sources=sources,
    zenodo_record_id=as.character(or_else(x$record_id,x$id)),
    zenodo_deposition_id=as.character(x$id),
    doi=or_else(x$doi,NA_character_),
    record_url=or_else(x$record_url,or_else(x$links$html,NA_character_)),
    title=or_else(x$title,expected_title),
    visibility="restricted",
    total_bytes=total_bytes,
    archive_files=lapply(archive_paths,function(p) list(
      filename=basename(p),
      bytes=unname(file.info(p)$size),
      sha256=digest(file=p,algo="sha256",serialize=FALSE)
    )),
    manifest_sha256=digest(file=manifest_path,algo="sha256",serialize=FALSE),
    published_at_utc=or_else(x$modified,or_else(x$created,NA_character_))
  )
  writeLines(toJSON(receipt,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),
             file.path(output_dir,"zenodo_receipt.json"))
  cat(sprintf("PASS: verified existing published Zenodo archive %s for Workflow 00 run %s\n",
              receipt$zenodo_record_id,run_id))
  quit(save="no",status=0L)
}
if (length(draft_hits)) {
  for (x in draft_hits) {
    id <- as.character(x$id)
    auth_req(paste0(api,"/",id)) |> req_method("DELETE") |> req_perform()
    message(sprintf("Deleted incomplete workflow-generated Zenodo draft %s for run %s",id,run_id))
  }
}

create <- auth_req(api) |> req_method("POST") |> req_body_json(list()) |> req_perform()
dep <- body_json(create)
dep_id <- as.character(dep$id)
writeLines(toJSON(list(status="draft_created",github_run_id=run_id,zenodo_deposition_id=dep_id),
                  auto_unbox=TRUE,pretty=TRUE),
           file.path(output_dir,"zenodo_draft_receipt.json"))

title <- expected_title
description <- paste0(
  "<p>Search archive for the Living Evidence Map Workflow 00 ingestion pipeline.</p>",
  "<p>This record corresponds to GitHub Actions run <a href=\"",run_url,"\">",run_id,"</a> and ",
  "contains the downloaded source search outputs, source manifests, search-plan documentation and provenance records ",
  "for the selected databases. Files are restricted because source database/API terms may limit redistribution.</p>",
  "<p>Run type: ",run_type,". Search strategy version: ",search_version,". Sources: ",
  paste(sources,collapse=", "),".</p>"
)
metadata <- list(
  upload_type="dataset",
  publication_date=format(Sys.Date(),"%Y-%m-%d"),
  title=title,
  creators=list(list(name="Haddaway, Neal")),
  description=description,
  access_right="restricted",
  access_conditions="Files contain database/API search-result exports and are restricted because source licensing or terms may limit redistribution. Access may be granted by the depositor where permitted.",
  keywords=c("Living Evidence Map","evidence synthesis","search archive","Workflow 00",marker),
  related_identifiers=list(list(identifier=run_url,relation="isSupplementTo"))
)

auth_req(paste0(api,"/",dep_id)) |>
  req_method("PUT") |>
  req_body_json(list(metadata=metadata)) |>
  req_perform()

dep <- auth_req(paste0(api,"/",dep_id)) |> req_perform() |> body_json()
bucket <- dep$links$bucket
if (is.null(bucket) || !nzchar(bucket)) stop("Zenodo deposition did not expose an upload bucket",call.=FALSE)

for (p in archive_paths) {
  fn <- basename(p)
  message(sprintf("Uploading %s (%s bytes)",fn,file.info(p)$size))
  upload_url <- paste0(sub("/$","",bucket),"/",URLencode(fn,reserved=TRUE))
  auth_req(upload_url) |>
    req_method("PUT") |>
    req_timeout(1800) |>
    req_body_file(p,type="application/octet-stream") |>
    req_perform()
}

published <- auth_req(paste0(api,"/",dep_id,"/actions/publish")) |>
  req_method("POST") |>
  req_perform() |>
  body_json()

receipt <- list(
  status="published",
  github_run_id=run_id,
  github_run_url=run_url,
  run_type=run_type,
  search_version=search_version,
  sources=sources,
  zenodo_record_id=as.character(or_else(published$record_id,published$id)),
  zenodo_deposition_id=as.character(published$id),
  doi=or_else(published$doi,NA_character_),
  record_url=or_else(published$record_url,or_else(published$links$html,NA_character_)),
  title=title,
  visibility="restricted",
  total_bytes=total_bytes,
  archive_files=lapply(archive_paths,function(p) list(
    filename=basename(p),
    bytes=unname(file.info(p)$size),
    sha256=digest(file=p,algo="sha256",serialize=FALSE)
  )),
  manifest_sha256=digest(file=manifest_path,algo="sha256",serialize=FALSE),
  published_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
writeLines(toJSON(receipt,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),
           file.path(output_dir,"zenodo_receipt.json"))
cat(sprintf("PASS: published restricted Zenodo search archive %s for Workflow 00 run %s\n",
            receipt$zenodo_record_id,run_id))
