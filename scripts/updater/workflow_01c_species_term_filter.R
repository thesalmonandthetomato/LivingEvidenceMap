#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s", flag), call.=FALSE)
  args[[i + 1L]]
}
or_else <- function(x,y) if (is.null(x)) y else x

input_path <- arg("--input")
manifest_path <- arg("--manifest")
out_dir <- arg("--outdir", "outputs/workflow01c_species_term_filter")
mode <- tolower(arg("--mode", "audit"))
if (is.null(input_path) || is.null(manifest_path)) stop("ERROR: --input and --manifest are required", call.=FALSE)
if (!mode %in% c("audit","apply")) stop("ERROR: --mode must be audit or apply", call.=FALSE)

dir.create(out_dir, recursive=TRUE, showWarnings=FALSE)

now_utc <- function() format(Sys.time(), tz="UTC", format="%Y-%m-%dT%H:%M:%SZ")

read_jsonl <- function(path) {
  con <- file(path, "rt", encoding="UTF-8"); on.exit(close(con))
  out <- list(); i <- 0L
  repeat {
    z <- readLines(con,n=1L,warn=FALSE)
    if (!length(z)) break
    if (!nzchar(trimws(z))) next
    i <- i+1L
    out[[i]] <- tryCatch(fromJSON(z,simplifyVector=FALSE),
                         error=function(e) stop(sprintf("Invalid JSONL at record %d: %s",i,conditionMessage(e)),call.=FALSE))
  }
  out
}

write_jsonl <- function(xs,path) {
  con <- file(path,"wt",encoding="UTF-8"); on.exit(close(con))
  for (x in xs) writeLines(toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA),con)
}

flatten_text <- function(x) {
  if (is.null(x) || !length(x)) return("")
  vals <- character()
  walk <- function(v) {
    if (is.null(v)) return()
    if (is.atomic(v)) {
      vals <<- c(vals, as.character(v))
    } else if (is.list(v)) {
      for (z in v) walk(z)
    }
  }
  walk(x)
  vals <- vals[nzchar(trimws(vals))]
  trimws(paste(vals, collapse=" ; "))
}

payload <- function(r) {
  lens <- or_else(r$lens,list())
  or_else(lens$raw_payload,list())
}
get_title <- function(r) {
  can <- or_else(r$canonical,list())
  as.character(or_else(can$title,or_else(payload(r)$title,"")))
}
get_abstract <- function(r) {
  can <- or_else(r$canonical,list())
  as.character(or_else(can$abstract,or_else(payload(r)$abstract,"")))
}
get_keywords <- function(r) {
  can <- or_else(r$canonical,list())
  k <- can$keywords
  if (is.null(k)) k <- payload(r)$keywords
  flatten_text(k)
}
get_lens_id <- function(r) {
  ident <- or_else(r$identity,list())
  as.character(or_else(ident$lens_id,or_else(payload(r)$lens_id,"")))
}

# IMPORTANT: 'salmon' is standalone and therefore does not match salmonid/salmonidae.
patterns <- list(
  salmon = "(?i)\\bsalmon\\b",
  salmo = "(?i)\\bsalmo\\b",
  oncorhynchus = "(?i)\\boncorhynchus\\b",
  rainbow_trout = "(?i)\\brainbow[[:space:]-]+trout\\b"
)

field_hits <- function(text) {
  hit <- vapply(patterns, function(p) grepl(p, or_else(text,""), perl=TRUE), logical(1))
  names(hit)[hit]
}

records <- read_jsonl(input_path)
manifest <- fromJSON(manifest_path,simplifyVector=FALSE)
if (!identical(manifest$pipeline_stage, "abstract_enriched_deduplication_ready")) {
  stop(sprintf("ERROR: expected pipeline_stage=abstract_enriched_deduplication_ready, found %s",
               or_else(manifest$pipeline_stage,"<missing>")), call.=FALSE)
}
if (!length(records)) stop("ERROR: input contains zero records",call.=FALSE)

ids <- vapply(records,get_lens_id,character(1))
if (any(!nzchar(ids))) stop("ERROR: at least one input record lacks Lens ID",call.=FALSE)
if (anyDuplicated(ids)) stop(sprintf("ERROR: duplicate Lens ID in input: %s",ids[duplicated(ids)][1]),call.=FALSE)

retained <- list(); removed <- list(); audit_rows <- list()

for (i in seq_along(records)) {
  r <- records[[i]]
  lid <- ids[[i]]
  title <- get_title(r)
  abstract <- get_abstract(r)
  keywords <- get_keywords(r)

  th <- field_hits(title)
  ah <- field_hits(abstract)
  kh <- field_hits(keywords)
  keep <- length(th) + length(ah) + length(kh) > 0L

  row <- list(
    lens_id=lid,
    retained=keep,
    title_hits=unname(th),
    abstract_hits=unname(ah),
    keyword_hits=unname(kh),
    matched_fields=c(
      if(length(th)) "title" else NULL,
      if(length(ah)) "abstract" else NULL,
      if(length(kh)) "keywords" else NULL
    ),
    title=title,
    abstract=abstract,
    keywords=keywords,
    abstract_present=nzchar(trimws(abstract)),
    reason=if (keep) "relevant_species_term_present" else "no_relevant_species_term_after_abstract_enrichment"
  )
  audit_rows[[length(audit_rows)+1L]] <- row

  if (keep) retained[[length(retained)+1L]] <- r else removed[[length(removed)+1L]] <- r
}

audit_path <- file.path(out_dir,"species_term_filter_audit.jsonl")
retained_path <- file.path(out_dir,"retained_records.jsonl")
removed_path <- file.path(out_dir,"removed_records.jsonl")
csv_path <- file.path(out_dir,"species_term_filter_audit.csv")
summary_path <- file.path(out_dir,"summary.json")

write_jsonl(audit_rows,audit_path)
write_jsonl(retained,retained_path)
write_jsonl(removed,removed_path)

csv <- data.frame(
  lens_id=vapply(audit_rows,function(x)x$lens_id,character(1)),
  retained=vapply(audit_rows,function(x)isTRUE(x$retained),logical(1)),
  abstract_present=vapply(audit_rows,function(x)isTRUE(x$abstract_present),logical(1)),
  title_hits=vapply(audit_rows,function(x)paste(unlist(x$title_hits),collapse="; "),character(1)),
  abstract_hits=vapply(audit_rows,function(x)paste(unlist(x$abstract_hits),collapse="; "),character(1)),
  keyword_hits=vapply(audit_rows,function(x)paste(unlist(x$keyword_hits),collapse="; "),character(1)),
  matched_fields=vapply(audit_rows,function(x)paste(unlist(x$matched_fields),collapse="; "),character(1)),
  reason=vapply(audit_rows,function(x)x$reason,character(1)),
  title=vapply(audit_rows,function(x)x$title,character(1)),
  keywords=vapply(audit_rows,function(x)x$keywords,character(1)),
  stringsAsFactors=FALSE
)
write.csv(csv,csv_path,row.names=FALSE,na="")

summary <- list(
  workflow="workflow_01c_species_term_filter",
  implementation_language="R",
  mode=mode,
  audit_only=identical(mode,"audit"),
  canonical_modified=FALSE,
  created_at=now_utc(),
  rule='retain iff title OR enriched abstract OR keywords contains standalone "salmon", "Salmo", "Oncorhynchus", or phrase "rainbow trout"',
  salmon_is_standalone=TRUE,
  input_records=length(records),
  retained_records=length(retained),
  removed_records=length(removed),
  removed_with_no_abstract=sum(!csv$retained & !csv$abstract_present),
  retained_by_title=sum(csv$retained & nzchar(csv$title_hits)),
  retained_by_abstract=sum(csv$retained & nzchar(csv$abstract_hits)),
  retained_by_keywords=sum(csv$retained & nzchar(csv$keyword_hits)),
  outputs=list(
    audit_jsonl=audit_path,
    audit_csv=csv_path,
    retained_records=retained_path,
    removed_records=removed_path
  )
)

if (identical(mode,"apply")) {
  summary$apply_ready <- TRUE
}

writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null"),summary_path)

if (length(retained)+length(removed) != length(records)) stop("ERROR: partition cardinality failure",call.=FALSE)
if (any(vapply(removed,function(r){
  length(field_hits(get_title(r)))+length(field_hits(get_abstract(r)))+length(field_hits(get_keywords(r))) > 0L
},logical(1)))) stop("ERROR: removed set contains a record with a relevant species term",call.=FALSE)
if (any(!vapply(retained,function(r){
  length(field_hits(get_title(r)))+length(field_hits(get_abstract(r)))+length(field_hits(get_keywords(r))) > 0L
},logical(1)))) stop("ERROR: retained set contains a record with no relevant species term",call.=FALSE)

cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null"),"\n")
cat("PASS: Workflow 01C species-term filter audit complete.\n")
