#!/usr/bin/env Rscript

suppressPackageStartupMessages({
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
`%||%` <- function(x,y) if (is.null(x)) y else x

canonical_path <- arg("--canonical")
w03_path <- arg("--workflow03-status")
output_dir <- arg("--output-dir")
sample_size <- as.integer(arg("--sample-size","500"))
seed <- arg("--seed","w04-validation-v1")

if (any(vapply(list(canonical_path,w03_path,output_dir),is.null,logical(1)))) {
  stop("Required: --canonical --workflow03-status --output-dir",call.=FALSE)
}
if (is.na(sample_size) || sample_size < 1L) stop("--sample-size must be >= 1",call.=FALSE)
if (!nzchar(seed)) stop("--seed must be non-empty",call.=FALSE)

read_jsonl <- function(path) {
  x <- readLines(path,warn=FALSE,encoding="UTF-8")
  x <- x[nzchar(trimws(x))]
  lapply(seq_along(x),function(i) {
    tryCatch(fromJSON(x[[i]],simplifyVector=FALSE),
             error=function(e)stop(sprintf("Invalid JSONL %s line %d: %s",path,i,conditionMessage(e)),call.=FALSE))
  })
}
write_jsonl <- function(rows,path) {
  dir.create(dirname(path),recursive=TRUE,showWarnings=FALSE)
  con <- file(path,"wt",encoding="UTF-8"); on.exit(close(con),add=TRUE)
  if (length(rows)) for (x in rows) {
    writeLines(toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)
  }
}
textify <- function(x) {
  if (is.null(x)) return("")
  if (is.character(x)) return(paste(x[!is.na(x)&nzchar(trimws(x))],collapse="; "))
  if (is.atomic(x)) return(paste(as.character(x),collapse="; "))
  if (is.list(x)) return(paste(Filter(nzchar,vapply(x,textify,character(1))),collapse="; "))
  as.character(x)
}
first_nonempty <- function(...) {
  for (x in list(...)) {
    z <- trimws(textify(x))
    if (nzchar(z)) return(z)
  }
  ""
}
record_id <- function(r) first_nonempty((r$identity %||% list())$record_id)
w03_id <- function(r) first_nonempty(r$record_id,(r$identity %||% list())$record_id)
w03_excluded <- function(x) isTRUE((x$publication_status %||% list())$exclude_from_workflow04 %||% x$exclude_from_workflow04 %||% FALSE)

screen_view <- function(r) {
  c <- r$canonical %||% list()
  list(
    title = first_nonempty(c$title,r$title),
    abstract = first_nonempty(c$abstract,r$abstract),
    authors = first_nonempty(c$authors,c$author,r$authors,r$author),
    year = first_nonempty(c$year,c$publication_year,c$cover_date,r$year,r$publication_year),
    journal = first_nonempty(c$source_title,c$journal,r$source_title,r$journal),
    volume = first_nonempty(c$volume,r$volume),
    pages = first_nonempty(c$pages,c$page_range,c$pagination,r$pages,r$page_range,r$pagination),
    doi = first_nonempty(c$doi,r$doi),
    keywords = first_nonempty(c$keywords,c$author_keywords,r$keywords,r$author_keywords)
  )
}

canonical <- read_jsonl(canonical_path)
w03 <- read_jsonl(w03_path)
cids <- vapply(canonical,record_id,character(1))
wids <- vapply(w03,w03_id,character(1))
if (any(!nzchar(cids)) || anyDuplicated(cids)) stop("Canonical record_id invariant failed",call.=FALSE)
if (any(!nzchar(wids)) || anyDuplicated(wids) || !setequal(cids,wids)) stop("W03 identity invariant failed",call.=FALSE)

cmap <- setNames(canonical,cids)
wmap <- setNames(w03,wids)
eligible <- sort(cids[!vapply(cids,function(id)w03_excluded(wmap[[id]]),logical(1))])
if (!length(eligible)) stop("No W04-eligible records available",call.=FALSE)

# Deterministic pseudo-random order: stable across R versions/platforms.
random_key <- vapply(
  eligible,
  function(id) digest(paste(seed,id,sep="|"),algo="sha256",serialize=FALSE),
  character(1)
)
ordered <- eligible[order(random_key,eligible)]
selected <- head(ordered,min(sample_size,length(ordered)))

rows <- lapply(seq_along(selected),function(i) {
  id <- selected[[i]]
  view <- screen_view(cmap[[id]])
  list(
    schema="living-evidence-map-workflow04-human-validation-case-v1",
    review_case_id=paste0("w04-val-",digest(paste(seed,id,sep="|"),algo="sha256",serialize=FALSE)),
    record_id=id,
    randomisation_seed=seed,
    random_order=i,
    bibliographic=view
  )
})

dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)
queue_path <- file.path(output_dir,"workflow04_validation_queue.jsonl")
write_jsonl(rows,queue_path)
queue_sha <- digest(file=queue_path,algo="sha256",serialize=FALSE)

manifest <- list(
  schema="living-evidence-map-workflow04-human-validation-queue-manifest-v1",
  workflow="04",
  purpose="independent_human_validation_screening",
  label_values=c("retain","exclude","uncertain"),
  llm_outputs_exposed=FALSE,
  randomisation_method="sha256(seed|record_id) ascending",
  randomisation_seed=seed,
  requested_sample_size=sample_size,
  eligible_records=length(eligible),
  sampled_records=length(rows),
  canonical_sha256=digest(file=canonical_path,algo="sha256",serialize=FALSE),
  workflow03_sha256=digest(file=w03_path,algo="sha256",serialize=FALSE),
  queue_sha256=queue_sha,
  created_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
writeLines(
  toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null"),
  file.path(output_dir,"workflow04_validation_queue_manifest.json"),
  useBytes=TRUE
)

cat(sprintf(
  "PASS: built W04 human validation queue: %d of %d eligible records; seed=%s; sha=%s\n",
  length(rows),length(eligible),seed,queue_sha
))
