#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(data.table)
  library(jsonlite)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
pairs_path <- arg("--pairs")
map_path <- arg("--manifestation-map")
source_files_path <- arg("--source-files")
output_path <- arg("--output")
if(any(vapply(list(pairs_path,map_path,source_files_path,output_path),is.null,logical(1)))) {
  stop("Required: --pairs --manifestation-map --source-files --output",call.=FALSE)
}
`%||%` <- function(x,y) if(is.null(x)) y else x
scalar <- function(x){
  if(is.null(x)||!length(x)) return(NA_character_)
  z <- suppressWarnings(as.character(unlist(x,use.names=FALSE)))
  z <- trimws(z[!is.na(z)])
  z <- z[nzchar(z)]
  if(!length(z)) NA_character_ else z[[1L]]
}
collapse_text <- function(x){
  if(is.null(x)||!length(x)) return(NA_character_)
  z <- as.character(unlist(x,use.names=FALSE))
  z <- trimws(z[!is.na(z)])
  z <- unique(z[nzchar(z)])
  if(!length(z)) NA_character_ else paste(z,collapse="; ")
}
authors_text <- function(x){
  if(is.null(x)||!length(x)) return(NA_character_)
  if(is.character(x)) return(collapse_text(x))
  vals <- vapply(x,function(a){
    if(is.character(a)&&length(a)==1L) return(a)
    if(!is.list(a)) return(NA_character_)
    for(n in c("display_name","fullName","full_name","name")){
      z <- scalar(a[[n]]); if(!is.na(z)) return(z)
    }
    first <- scalar(a$first_name %||% a$given_name)
    last <- scalar(a$last_name %||% a$surname)
    nm <- trimws(paste(ifelse(is.na(first),"",first),ifelse(is.na(last),"",last)))
    if(nzchar(nm)) nm else NA_character_
  },character(1))
  collapse_text(vals)
}
source_kind <- function(r){
  if(is.list(r$lens)) return("lens")
  p <- scalar((r$source %||% list())$provider)
  if(identical(p,"scopus")) return("scopus")
  if(identical(p,"openalex")) return("openalex")
  if(identical(p,"agricola_via_europe_pmc")) return("agricola")
  if(identical(p,"wos_starter")) return("wos")
  NA_character_
}
source_record_id <- function(r,src){
  if(src=="lens") return(scalar((r$identity %||% list())$lens_id %||% (r$canonical %||% list())$record_id))
  scalar((r$sidecar_identity %||% list())$sidecar_record_id)
}
extract_record <- function(r,src,idx,rid){
  mapped <- if(src=="lens") (r$canonical %||% list()) else (r$mapped_fields %||% list())
  raw <- if(src=="lens") ((r$lens %||% list())$raw_payload %||% list()) else ((r[[src]] %||% list())$raw_payload %||% list())
  enrich <- r$abstract_enrichment %||% list()
  abstract_candidates <- c(
    scalar(mapped$abstract),scalar(enrich$abstract),scalar(enrich$recovered_abstract),
    scalar(enrich$abstract_text),scalar(enrich$replacement_abstract),
    scalar(raw$abstract),scalar(raw$abstractText),scalar(raw$description)
  )
  abstract_candidates <- abstract_candidates[!is.na(abstract_candidates)&nzchar(abstract_candidates)]
  keywords <- mapped$keywords
  if(is.null(keywords)&&src=="lens") keywords <- raw$keywords
  list(
    index=as.integer(idx),
    source=src,
    source_record_id=as.character(rid),
    title=scalar(mapped$title %||% raw$title),
    abstract=if(length(abstract_candidates)) abstract_candidates[[1L]] else NA_character_,
    keywords=collapse_text(keywords),
    journal=scalar(mapped$source %||% mapped$journal %||% raw$source),
    year=scalar(mapped$year %||% mapped$publication_date %||% raw$year_published %||% raw$date_published),
    authors=authors_text(mapped$authors %||% raw$authors),
    volume=scalar(mapped$volume %||% raw$volume),
    issue=scalar(mapped$issue %||% raw$issue),
    pages=scalar(mapped$pages %||% mapped$article_number %||% raw$pages),
    doi=scalar(mapped$doi %||% (r$sidecar_identity %||% list())$doi)
  )
}

legacy_pairs <- fread(pairs_path,na.strings=c("","NA"))
pairs <- legacy_pairs[rescored_classification=="review"]
map <- fread(map_path,na.strings=c("","NA"))
required_pairs <- c("record_i","record_j","pair_key","review_route","rescored_classification","rescored_rule",
                    "title_similarity","blocks")
required_map <- c("idx","source","source_record_id")
if(length(setdiff(required_pairs,names(pairs)))) stop("Recovered pair file missing required columns",call.=FALSE)
if(length(setdiff(required_map,names(map)))) stop("Manifestation map missing required columns",call.=FALSE)
if(nrow(legacy_pairs)!=3004L) stop(sprintf("Expected 3004 rows in immutable legacy routed file, found %d",nrow(legacy_pairs)),call.=FALSE)
if(nrow(pairs)!=730L) stop(sprintf("Expected exactly 730 review-class diverted pairs, found %d",nrow(pairs)),call.=FALSE)
if(any(legacy_pairs$review_route!="workflow04_exclusion_candidate")) stop("Legacy recovery file contains rows outside the old diverted route",call.=FALSE)
if(any(pairs$review_route!="workflow04_exclusion_candidate")) stop("Recovered review set contains rows outside the old diverted route",call.=FALSE)
if(anyDuplicated(pairs$pair_key)) stop("Recovered pair set contains duplicate pair keys",call.=FALSE)
if(any(!c(pairs$record_i,pairs$record_j) %in% map$idx)) stop("Recovered pairs reference missing manifestation indices",call.=FALSE)
setkey(map,idx)

sf <- fromJSON(source_files_path,simplifyVector=FALSE)
files <- sf$files
expected_sources <- c("lens","scopus","openalex","agricola","wos")
if(any(!expected_sources %in% names(files))) stop("source-files manifest does not contain all five sources",call.=FALSE)

wanted_idx <- sort(unique(c(pairs$record_i,pairs$record_j)))
wanted_map <- map[.(wanted_idx)]
wanted_keys <- paste(wanted_map$source,wanted_map$source_record_id,sep="::")
names(wanted_keys) <- as.character(wanted_map$idx)
records <- new.env(parent=emptyenv())

for(src in expected_sources){
  need <- wanted_map[source==src]
  if(!nrow(need)) next
  need_ids <- setNames(rep(TRUE,nrow(need)),as.character(need$source_record_id))
  p <- as.character(files[[src]])
  if(!file.exists(p)) stop(sprintf("Source JSONL missing for %s: %s",src,p),call.=FALSE)
  con <- file(p,"rt",encoding="UTF-8")
  repeat{
    lines <- readLines(con,n=1000L,warn=FALSE)
    if(!length(lines)) break
    for(line in lines){
      if(!nzchar(trimws(line))) next
      r <- fromJSON(line,simplifyVector=FALSE)
      detected <- source_kind(r)
      if(is.na(detected)||detected!=src) next
      rid <- source_record_id(r,src)
      if(is.na(rid)||!(rid %in% names(need_ids))) next
      mm <- need[source_record_id==rid]
      if(nrow(mm)!=1L) stop(sprintf("Non-unique manifestation mapping for %s::%s",src,rid),call.=FALSE)
      assign(paste(src,rid,sep="::"),extract_record(r,src,mm$idx[[1L]],rid),envir=records)
    }
  }
  close(con)
}
missing <- wanted_keys[!vapply(wanted_keys,exists,logical(1),envir=records,inherits=FALSE)]
if(length(missing)) stop(sprintf("Could not recover %d required source records",length(missing)),call.=FALSE)

dir.create(dirname(output_path),recursive=TRUE,showWarnings=FALSE)
out <- file(output_path,"wt",encoding="UTF-8")
for(i in seq_len(nrow(pairs))){
  q <- pairs[i]
  mi <- map[.(q$record_i)]
  mj <- map[.(q$record_j)]
  ri <- get(paste(mi$source,mi$source_record_id,sep="::"),envir=records,inherits=FALSE)
  rj <- get(paste(mj$source,mj$source_record_id,sep="::"),envir=records,inherits=FALSE)
  stable <- paste(sort(c(paste(mi$source,mi$source_record_id,sep=":"),
                         paste(mj$source,mj$source_record_id,sep=":"))),collapse="|")
  case_id <- paste0("hr-",substr(digest(stable,algo="sha256",serialize=FALSE),1,20))
  z <- list(
    schema="living-evidence-map-workflow01-duplicate-adjudication-case-v1",
    review_case_id=case_id,
    pair_key=as.character(q$pair_key),
    record_i=ri,
    record_j=rj,
    deterministic_evidence=list(
      blocks=as.character(q$blocks),
      title_similarity=as.numeric(q$title_similarity),
      title_containment=if("title_containment"%in%names(q)) as.logical(q$title_containment) else NULL,
      exact_title=if("exact_title"%in%names(q)) as.logical(q$exact_title) else NULL,
      exact_abstract=if("exact_abstract"%in%names(q)) as.logical(q$exact_abstract) else NULL,
      ordered_coverage=if("ordered_coverage"%in%names(q)) as.numeric(q$ordered_coverage) else NULL,
      shingle_containment=if("shingle_containment"%in%names(q)) as.numeric(q$shingle_containment) else NULL,
      classifier_decision=as.character(q$rescored_classification),
      classifier_rule=as.character(q$rescored_rule),
      identifier_conflict=if("identifier_conflict"%in%names(q)) as.logical(q$identifier_conflict) else NULL,
      identifier_conflict_reason=if("identifier_conflict_reason"%in%names(q)) scalar(q$identifier_conflict_reason) else NULL,
      preprint_pair=if("preprint_pair"%in%names(q)) as.logical(q$preprint_pair) else NULL,
      recovery_provenance="legacy_workflow04_exclusion_candidate_route_removed"
    )
  )
  writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null"),out,useBytes=TRUE)
}
close(out)

manifest <- list(
  schema="living-evidence-map-workflow01-recovered-diverted-adjudication-input-v1",
  legacy_routed_rows=nrow(legacy_pairs),
  legacy_candidate_only_rows=sum(legacy_pairs$rescored_classification=="unresolved"),
  cases=nrow(pairs),
  unique_bibliographic_records=length(wanted_keys),
  source_counts=as.list(table(wanted_map$source)),
  legacy_route="workflow04_exclusion_candidate",
  legacy_route_is_invalid=TRUE,
  recovery_action="ordinary_workflow01_duplicate_adjudication",
  pairs_sha256=digest(file=pairs_path,algo="sha256",serialize=FALSE),
  manifestation_map_sha256=digest(file=map_path,algo="sha256",serialize=FALSE),
  output_sha256=digest(file=output_path,algo="sha256",serialize=FALSE)
)
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null"),paste0(output_path,".manifest.json"),useBytes=TRUE)
cat(sprintf("PASS: recovered %d diverted Workflow 01 deduplication cases from %d source records\n",nrow(pairs),length(wanted_keys)))
