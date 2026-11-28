#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(httr2)
  library(digest)
})


args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

latest_pointer <- normalizePath(arg("--pointer"),mustWork=TRUE)
pointer_dir <- normalizePath(arg("--pointer-dir"),mustWork=TRUE)
output_root <- arg("--output-root")
if(is.null(output_root)) stop("Required: --pointer --pointer-dir --output-root",call.=FALSE)
if(file.exists(output_root)) stop("Output root already exists",call.=FALSE)

token <- Sys.getenv("ZENODO_ACCESS_TOKEN")
if(!nzchar(token)) stop("ZENODO_ACCESS_TOKEN is required",call.=FALSE)

read_pointer <- function(path){
  x <- fromJSON(path,simplifyVector=FALSE)
  if(!identical(x$status,"published")) stop(sprintf("Pointer is not published: %s",path),call.=FALSE)
  if(!identical(x$visibility,"restricted")) stop(sprintf("Pointer is not restricted: %s",path),call.=FALSE)
  if(is.null(x$state) || !(x$state %in% c("final","delta"))) stop(sprintf("Unsupported Workflow 01 pointer state: %s",x$state),call.=FALSE)
  x
}

# Traverse pointer lineage backwards to the immutable full baseline.
chain_paths <- character()
chain <- list()
p_path <- latest_pointer
repeat{
  p <- read_pointer(p_path)
  chain_paths <- c(chain_paths,p_path)
  chain[[length(chain)+1L]] <- p
  if(identical(p$state,"final")) break
  prev_run <- as.character(p$previous_github_run_id %||% "")
  prev_record <- as.character(p$previous_zenodo_record_id %||% "")
  if(!nzchar(prev_run)||!nzchar(prev_record)) stop("Delta pointer lacks previous run/Zenodo lineage",call.=FALSE)
  prev_path <- file.path(pointer_dir,paste0("run-",prev_run,".json"))
  if(!file.exists(prev_path)) stop(sprintf("Previous Workflow 01 pointer missing: %s",prev_path),call.=FALSE)
  prev <- read_pointer(prev_path)
  if(!identical(as.character(prev$zenodo_record_id),prev_record)) {
    stop(sprintf("Delta lineage mismatch: expected previous Zenodo record %s, pointer has %s",
                 prev_record,as.character(prev$zenodo_record_id)),call.=FALSE)
  }
  p_path <- prev_path
}
chain <- rev(chain)
chain_paths <- rev(chain_paths)
if(!identical(chain[[1L]]$state,"final")) stop("Workflow 01 lineage does not terminate in a full final baseline",call.=FALSE)

# Check replay dependencies before downloading any baseline or delta.
if(length(chain)>1L){
  required <- c("data.table","readr")
  missing <- required[!vapply(required,requireNamespace,logical(1),quietly=TRUE)]
  if(length(missing)) stop("W01 restoration dependencies missing: ",paste(missing,collapse=", "),call.=FALSE)
}

work <- tempfile("workflow01_restore_")
dir.create(work,recursive=TRUE)
on.exit(unlink(work,recursive=TRUE,force=TRUE),add=TRUE)
state_dir <- file.path(work,"state")
baseline_pointer <- chain_paths[[1L]]

# Use the checksum-verifying baseline restorer.
status <- system2("Rscript",c(
  "scripts/updater/workflow_01_restore_state_from_zenodo.R",
  "--pointer",baseline_pointer,
  "--output-root",state_dir
))
if(status!=0L) stop("Failed to restore Workflow 01 full baseline",call.=FALSE)

auth <- function(req) req |> req_headers(Authorization=paste("Bearer",token))

# Retry transient Zenodo deposition API errors (including 502/504), not just
# archive-file transfers. Never retry permission/record errors such as 401/404.
zenodo_get_deposition <- function(api, label) {
  max_attempts <- 5L
  for (attempt in seq_len(max_attempts)) {
    failure <- NULL
    response <- tryCatch(
      request(api) |> auth() |> req_timeout(120) |>
        req_error(is_error=function(resp)FALSE) |> req_perform(),
      error=function(e) {failure <<- conditionMessage(e); NULL}
    )
    status <- if(is.null(response)) NA_integer_ else resp_status(response)
    if(!is.null(response) && status==200L){
      dep <- tryCatch(resp_body_json(response,simplifyVector=FALSE),
                      error=function(e) stop(sprintf("Invalid Zenodo deposition JSON for %s: %s",
                                  label,conditionMessage(e)),call.=FALSE))
      if(!is.list(dep)) stop(sprintf("Unexpected Zenodo deposition response for %s",label),call.=FALSE)
      cat(sprintf("PASS: Zenodo deposition metadata %s attempt=%d/%d\\n",
                  label,attempt,max_attempts))
      return(dep)
    }
    if(is.null(failure)) failure <- sprintf("HTTP %s",if(is.na(status))"unknown" else as.character(status))
    transient <- is.na(status) || status %in% c(408L,425L,429L,500L,502L,503L,504L)
    if(identical(status,403L)) return(NULL)
    if(!transient || attempt==max_attempts){
      stop(sprintf("Zenodo deposition metadata %s failed after %d attempt(s): %s",
                   label,attempt,failure),call.=FALSE)
    }
    retry_after <- if(!is.null(response)) suppressWarnings(as.numeric(resp_header(response,"retry-after"))) else NA_real_
    delay <- if(length(retry_after)==1L && is.finite(retry_after) && retry_after>0) min(120,retry_after) else min(60,3*2^(attempt-1L))
    cat(sprintf("RETRY: Zenodo deposition metadata %s attempt=%d/%d reason=%s delay_seconds=%s\\n",
                label,attempt,max_attempts,failure,format(delay)))
    flush.console()
    Sys.sleep(delay)
  }
}

download_delta <- function(pointer, dest_root){
  dep_id <- as.character(pointer$zenodo_deposition_id)
  if(!nzchar(dep_id)) stop("Delta pointer lacks zenodo_deposition_id",call.=FALSE)
  files <- pointer$archive_files
  if(is.data.frame(files)) files <- lapply(seq_len(nrow(files)),function(i)as.list(files[i,,drop=FALSE]))
  if(is.list(files)&&!is.null(files$filename)) files <- list(files)
  if(!length(files)) stop("Delta pointer lacks archive_files",call.=FALSE)

  api <- paste0("https://zenodo.org/api/deposit/depositions/",dep_id)
  dep <- zenodo_get_deposition(api,dep_id)
  if(!is.null(dep) && !isTRUE(dep$submitted)) stop(sprintf("Zenodo delta %s is not published",dep_id),call.=FALSE)
  bucket <- if(is.null(dep$links$bucket)) "" else as.character(dep$links$bucket)
  record_id <- as.character(pointer$zenodo_record_id)
  stopifnot(length(record_id)==1L,grepl("^[0-9]+$",record_id))
  if(!grepl("^https://zenodo[.]org/api/files/",bucket)) bucket <- ""

  dir.create(dest_root,recursive=TRUE,showWarnings=FALSE)
  downloads <- file.path(dest_root,"downloads")
  dir.create(downloads,showWarnings=FALSE)
  local <- character()
  for(z in files){
    fn <- as.character(z$filename)
    dest <- file.path(downloads,fn)
    record_url <- paste0("https://zenodo.org/api/records/",record_id,"/files/",URLencode(fn,reserved=TRUE),"/content")
    url <- if(nzchar(bucket)) paste0(sub("/$","",bucket),"/",URLencode(fn,reserved=TRUE)) else record_url
    # Zenodo's authenticated bucket occasionally returns transient HTTP 5xx
    # responses or times out even for intact published files. Retry boundedly;
    # accept a file only after checking every published checksum.
    max_attempts <- 5L
    downloaded <- FALSE
    for(attempt in seq_len(max_attempts)){
      if(file.exists(dest)) unlink(dest)
      error_message <- NULL
      resp <- tryCatch(
        request(url) |> req_method("GET") |> auth() |> req_timeout(300) |>
          req_error(is_error=function(resp)FALSE) |> req_perform(path=dest),
        error=function(e){error_message <<- conditionMessage(e);NULL}
      )
      code <- if(is.null(resp)) NA_integer_ else resp_status(resp)
      if(identical(code,403L) && !identical(url,record_url)){
        message("Legacy file endpoint refused access; trying authenticated published-record endpoint")
        url <- record_url
        if(file.exists(dest)) unlink(dest)
        next
      }
      retryable <- is.na(code) || code %in% c(200L,408L,409L,425L,429L,500L,502L,503L,504L)
      failure <- NULL
      if(!is.null(resp) && code==200L && file.exists(dest)){
        if(!identical(as.numeric(file.info(dest)$size),as.numeric(z$bytes))){
          failure <- sprintf("byte mismatch (expected=%s actual=%s)",as.character(z$bytes),as.character(file.info(dest)$size))
          retryable <- TRUE
        } else {
          actual_sha <- digest(file=dest,algo="sha256",serialize=FALSE)
          if(!identical(tolower(actual_sha),tolower(as.character(z$sha256)))){
            failure <- sprintf("SHA256 mismatch (expected=%s actual=%s)",as.character(z$sha256),actual_sha)
            retryable <- TRUE
          } else if(!is.null(z$zenodo_checksum) && nzchar(as.character(z$zenodo_checksum))){
            expected_md5 <- sub("^md5:","",tolower(as.character(z$zenodo_checksum)))
            actual_md5 <- digest(file=dest,algo="md5",serialize=FALSE)
            if(!identical(actual_md5,expected_md5)){
              failure <- sprintf("MD5 mismatch (expected=%s actual=%s)",expected_md5,actual_md5)
              retryable <- TRUE
            }
          }
        }
        if(is.null(failure)){
          downloaded <- TRUE
          cat(sprintf("PASS: verified Zenodo delta file %s (attempt %d/%d, SHA256=%s)\\n",
                      fn,attempt,max_attempts,as.character(z$sha256)))
          break
        }
      } else {
        failure <- if(!is.null(error_message)) error_message else
          sprintf("HTTP %s",if(is.na(code))"unknown" else as.character(code))
      }
      if(file.exists(dest)) unlink(dest)
      if(!retryable || attempt==max_attempts){
        stop(sprintf("Zenodo delta file %s from deposition %s failed after %d attempt(s): %s",
                     fn,dep_id,attempt,failure),call.=FALSE)
      }
      retry_after <- if(!is.null(resp)) suppressWarnings(as.numeric(resp_header(resp,"retry-after"))) else NA_real_
      delay <- if(length(retry_after)==1L && is.finite(retry_after) && retry_after>0) min(120,retry_after) else min(60,3 * 2^(attempt-1L))
      cat(sprintf("RETRY: Zenodo delta file %s attempt=%d/%d reason=%s delay_seconds=%s\\n",
                  fn,attempt,max_attempts,failure,format(delay)))
      flush.console()
      Sys.sleep(delay)
    }
    if(!downloaded || !file.exists(dest)) stop(sprintf("Zenodo download missing after retry: %s",fn),call.=FALSE)
    local <- c(local,dest)
  }
  tar <- local[grepl("\\.tar\\.gz$",local)]
  if(length(tar)!=1L) stop("Expected exactly one delta tar.gz",call.=FALSE)
  extract <- file.path(dest_root,"extract")
  dir.create(extract,showWarnings=FALSE)
  tar_bin <- Sys.which("tar")
  if(!nzchar(tar_bin)) stop("System tar required for W01 delta extraction",call.=FALSE)
  status <- system2(tar_bin,c("-xzf",shQuote(tar),"-C",shQuote(extract)))
  if(status!=0L) stop("W01 delta extraction failed",call.=FALSE)
  manifests <- list.files(extract,pattern="^delta_manifest\\.json$",recursive=TRUE,full.names=TRUE)
  if(length(manifests)!=1L) stop("Expected exactly one restored delta_manifest.json",call.=FALSE)
  dirname(manifests[[1L]])
}

if(length(chain)>1L){
  for(i in 2:length(chain)){
    p <- chain[[i]]
    if(!identical(p$state,"delta")) stop("Only the first lineage member may be full final state",call.=FALSE)
    delta_root <- download_delta(p,file.path(work,paste0("delta-",i)))
    next_state <- file.path(work,paste0("state-",i))
    status <- system2("Rscript",c(
      "scripts/updater/workflow_01_replay_delta.R",
      "--previous-root",state_dir,
      "--delta-dir",delta_root,
      "--output-root",next_state
    ))
    if(status!=0L) stop(sprintf("Failed replaying Workflow 01 delta run %s",p$github_run_id),call.=FALSE)
    unlink(state_dir,recursive=TRUE,force=TRUE)
    state_dir <- next_state
  }
}

if(!dir.create(dirname(output_root),recursive=TRUE,showWarnings=FALSE) && !dir.exists(dirname(output_root))){
  stop("Could not create output parent directory",call.=FALSE)
}
if(!file.rename(state_dir,output_root)){
  stop("Failed to move reconstructed Workflow 01 state to requested output root",call.=FALSE)
}

latest <- chain[[length(chain)]]
audit <- list(
  schema="living-evidence-map-workflow01-current-state-restore-v1",
  status="PASS",
  baseline_github_run_id=as.character(chain[[1L]]$github_run_id),
  baseline_zenodo_record_id=as.character(chain[[1L]]$zenodo_record_id),
  latest_github_run_id=as.character(latest$github_run_id),
  latest_zenodo_record_id=as.character(latest$zenodo_record_id),
  deltas_replayed=max(0L,length(chain)-1L),
  lineage=lapply(chain,function(z)list(
    github_run_id=as.character(z$github_run_id),
    zenodo_record_id=as.character(z$zenodo_record_id),
    state=as.character(z$state),
    manifest_sha256=as.character(z$manifest_sha256)
  )),
  restored_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
writeLines(toJSON(audit,auto_unbox=TRUE,pretty=TRUE,null="null"),
           file.path(output_root,"workflow01_current_state_restore_audit.json"),useBytes=TRUE)
cat(sprintf("PASS: restored Workflow 01 current state from baseline plus %d delta(s); latest run %s\n",
            audit$deltas_replayed,audit$latest_github_run_id))

`%||%` <- function(x,y) if(is.null(x)) y else x
