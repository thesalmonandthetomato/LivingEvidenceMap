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
workflow04_layer_path <- arg("--workflow04-layer")
output_dir <- arg("--output-dir")
sample_size <- as.integer(arg("--sample-size","500"))
seed <- arg("--seed","w04-validation-v1")

if (any(vapply(list(canonical_path,w03_path,workflow04_layer_path,output_dir),is.null,logical(1)))) {
  stop("Required: --canonical --workflow03-status --workflow04-layer --output-dir",call.=FALSE)
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
    abstract = first_nonempty(c$abstract,r[["abstract"]]),
    authors = first_nonempty(c$authors,c$author,r$authors,r$author),
    year = first_nonempty(c$year,c$publication_year,c$cover_date,r$year,r$publication_year),
    journal = first_nonempty(c$source_title,c$journal,r$source_title,r$journal),
    volume = first_nonempty(c$volume,r$volume),
    pages = first_nonempty(c$pages,c$page_range,c$pagination,r$pages,r$page_range,r$pagination),
    doi = first_nonempty(c$doi,r$doi),
    keywords = first_nonempty(c$keywords,c$author_keywords,r$keywords,r$author_keywords)
  )
}

model_reference_from_layer <- function(r) {
  s <- r$screening %||% list()
  origin <- first_nonempty(s$decision_origin)
  explicit <- first_nonempty(s$model_decision_before_human)
  luna <- s$luna_consensus %||% list()
  luna_decision <- first_nonempty(luna$decision)
  top_decision <- first_nonempty(s$decision)

  if (explicit %in% c("retain","exclude","uncertain")) {
    decision <- explicit
    source <- "screening.model_decision_before_human"
  } else if (luna_decision %in% c("retain","exclude","uncertain")) {
    decision <- luna_decision
    source <- "screening.luna_consensus.decision"
  } else if (grepl("after_luna_(uncertain|unresolved)",origin,ignore.case=TRUE)) {
    decision <- "uncertain"
    source <- "decision_origin_implies_luna_uncertain"
  } else if (identical(origin,"luna_consensus") && top_decision %in% c("retain","exclude","uncertain")) {
    decision <- top_decision
    source <- "screening.decision_luna_consensus"
  } else if (grepl("human|historical",origin,ignore.case=TRUE)) {
    stop(sprintf(
      "W04 record %s has human/historical final decision but no recoverable pre-human model decision",
      first_nonempty(r$record_id)
    ),call.=FALSE)
  } else if (top_decision %in% c("retain","exclude","uncertain")) {
    decision <- top_decision
    source <- "screening.decision_fallback"
  } else {
    stop(sprintf(
      "W04 record %s has no recoverable model decision",
      first_nonempty(r$record_id)
    ),call.=FALSE)
  }

  list(
    decision=decision,
    source=source,
    final_decision=top_decision,
    final_decision_origin=origin,
    screening_input_sha256=first_nonempty(
      s$model_screening_input_sha256,
      luna$screening_input_sha256,
      s$screening_input_sha256
    )
  )
}

canonical <- read_jsonl(canonical_path)
w03 <- read_jsonl(w03_path)
w04 <- read_jsonl(workflow04_layer_path)
cids <- vapply(canonical,record_id,character(1))
wids <- vapply(w03,w03_id,character(1))
w04ids <- vapply(w04,function(x)first_nonempty(x$record_id),character(1))
if (any(!nzchar(cids)) || anyDuplicated(cids)) stop("Canonical record_id invariant failed",call.=FALSE)
if (any(!nzchar(wids)) || anyDuplicated(wids) || !setequal(cids,wids)) stop("W03 identity invariant failed",call.=FALSE)
if (any(!nzchar(w04ids)) || anyDuplicated(w04ids)) stop("W04 layer identity invariant failed",call.=FALSE)

cmap <- setNames(canonical,cids)
wmap <- setNames(w03,wids)
w04map <- setNames(w04,w04ids)
eligible <- sort(cids[!vapply(cids,function(id)w03_excluded(wmap[[id]]),logical(1))])
if (!setequal(eligible,w04ids)) stop("W04 validation source layer does not exactly cover current W04-eligible records",call.=FALSE)
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

model_ref <- lapply(selected,function(id)model_reference_from_layer(w04map[[id]]))
model_reference <- data.frame(
  review_case_id=vapply(rows,function(x)as.character(x$review_case_id),character(1)),
  record_id=selected,
  model_decision=vapply(model_ref,function(x)x$decision,character(1)),
  model_decision_source=vapply(model_ref,function(x)x$source,character(1)),
  final_decision=vapply(model_ref,function(x)x$final_decision,character(1)),
  final_decision_origin=vapply(model_ref,function(x)x$final_decision_origin,character(1)),
  screening_input_sha256=vapply(model_ref,function(x)x$screening_input_sha256,character(1)),
  stringsAsFactors=FALSE
)
if(any(!model_reference$model_decision %in% c("retain","exclude","uncertain"))) {
  stop("W04 validation model reference contains invalid decisions",call.=FALSE)
}

dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)
queue_path <- file.path(output_dir,"workflow04_validation_queue.jsonl")
model_reference_path <- file.path(output_dir,"workflow04_validation_model_reference.csv")
write_jsonl(rows,queue_path)
write.csv(model_reference,model_reference_path,row.names=FALSE,na="")
queue_sha <- digest(file=queue_path,algo="sha256",serialize=FALSE)
model_reference_sha <- digest(file=model_reference_path,algo="sha256",serialize=FALSE)

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
  workflow04_layer_sha256=digest(file=workflow04_layer_path,algo="sha256",serialize=FALSE),
  queue_sha256=queue_sha,
  model_reference_sha256=model_reference_sha,
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
