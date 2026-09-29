#!/usr/bin/env Rscript

suppressPackageStartupMessages(library(jsonlite))

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
baseline_path <- arg("--baseline")
candidate_path <- arg("--candidate")
report_path <- arg("--report",NULL)
if(is.null(baseline_path)||is.null(candidate_path)){
  stop("Required: --baseline BASELINE.jsonl --candidate CANDIDATE.jsonl [--report report.json]",call.=FALSE)
}

`%||%` <- function(x,y) if(is.null(x)) y else x

read_jsonl_by_id <- function(path){
  if(!file.exists(path)) stop(sprintf("Missing JSONL: %s",path),call.=FALSE)
  con <- file(path,"rt",encoding="UTF-8"); on.exit(close(con))
  out <- new.env(hash=TRUE,parent=emptyenv())
  n <- 0L
  repeat{
    lines <- readLines(con,n=500L,warn=FALSE)
    if(!length(lines)) break
    for(line in lines){
      if(!nzchar(trimws(line))) next
      r <- fromJSON(line,simplifyVector=FALSE)
      rid <- as.character((r$identity %||% list())$record_id %||% "")
      if(!nzchar(rid)) stop(sprintf("Record without identity.record_id in %s",path),call.=FALSE)
      if(exists(rid,envir=out,inherits=FALSE)) stop(sprintf("Duplicate record_id %s in %s",rid,path),call.=FALSE)
      assign(rid,r,envir=out)
      n <- n+1L
    }
  }
  list(records=out,ids=sort(ls(out,all.names=TRUE)),n=n)
}

normalise_null <- function(x){
  if(is.null(x)) return(NULL)
  x
}
same_json <- function(a,b){
  identical(
    toJSON(normalise_null(a),auto_unbox=TRUE,null="null",na="null",digits=NA),
    toJSON(normalise_null(b),auto_unbox=TRUE,null="null",na="null",digits=NA)
  )
}

base <- read_jsonl_by_id(baseline_path)
cand <- read_jsonl_by_id(candidate_path)

issues <- list()
add_issue <- function(record_id,field,baseline,candidate){
  issues[[length(issues)+1L]] <<- list(
    record_id=record_id,
    field=field,
    baseline=baseline,
    candidate=candidate
  )
}

if(!identical(base$ids,cand$ids)){
  missing <- setdiff(base$ids,cand$ids)
  extra <- setdiff(cand$ids,base$ids)
  if(length(missing)) for(id in missing) add_issue(id,"record_presence","present","missing")
  if(length(extra)) for(id in extra) add_issue(id,"record_presence","missing","present")
}

existing_canonical_fields <- c(
  "title","abstract","doi","authors","year","journal","volume","issue","pages"
)

common <- intersect(base$ids,cand$ids)
for(rid in common){
  a <- get(rid,envir=base$records,inherits=FALSE)
  b <- get(rid,envir=cand$records,inherits=FALSE)

  if(!same_json(a$identity,b$identity)){
    add_issue(rid,"identity",a$identity,b$identity)
  }

  ad <- a$deduplication %||% list()
  bd <- b$deduplication %||% list()
  for(f in c("cluster_id","member_count","status","final")){
    if(!same_json(ad[[f]],bd[[f]])) add_issue(rid,paste0("deduplication.",f),ad[[f]],bd[[f]])
  }

  am <- a$manifestations %||% list()
  bm <- b$manifestations %||% list()
  akeys <- vapply(am,function(m)paste(as.character(m$source %||% ""),as.character(m$source_record_id %||% ""),sep="::"),character(1))
  bkeys <- vapply(bm,function(m)paste(as.character(m$source %||% ""),as.character(m$source_record_id %||% ""),sep="::"),character(1))
  if(!identical(sort(akeys),sort(bkeys))){
    add_issue(rid,"manifestation_identity_set",sort(akeys),sort(bkeys))
  } else {
    existing_manifestation_fields <- c(
      "source","source_record_id","title","abstract","doi","authors","year",
      "journal","volume","issue","pages","abstract_stripped","abstract_strip_provenance"
    )
    amap <- setNames(am,akeys)
    bmap <- setNames(bm,bkeys)
    for(mkey in sort(akeys)){
      ma <- amap[[mkey]]
      mb <- bmap[[mkey]]
      for(f in existing_manifestation_fields){
        if(!same_json(ma[[f]],mb[[f]])){
          add_issue(rid,paste0("manifestation[",mkey,"].",f),ma[[f]],mb[[f]])
        }
      }
    }
  }

  ac <- a$canonical %||% list()
  bc <- b$canonical %||% list()
  for(f in existing_canonical_fields){
    if(!same_json(ac[[f]],bc[[f]])) add_issue(rid,paste0("canonical.",f),ac[[f]],bc[[f]])
  }
  if(!same_json(ac$field_provenance,bc$field_provenance)){
    add_issue(rid,"canonical.field_provenance",ac$field_provenance,bc$field_provenance)
  }
}

report <- list(
  schema="living-evidence-map-workflow01-additive-schema-regression-v1",
  status=if(length(issues))"FAIL" else "PASS",
  baseline_records=base$n,
  candidate_records=cand$n,
  invariant_record_ids=identical(base$ids,cand$ids),
  checked_existing_canonical_fields=existing_canonical_fields,
  issues_n=length(issues),
  issues=issues
)

if(!is.null(report_path)){
  dir.create(dirname(report_path),recursive=TRUE,showWarnings=FALSE)
  writeLines(toJSON(report,auto_unbox=TRUE,pretty=TRUE,null="null",na="null",digits=NA),report_path,useBytes=TRUE)
}

if(length(issues)){
  ex <- head(issues,20L)
  for(z in ex) message(sprintf("DIFF %s %s",z$record_id,z$field))
  stop(sprintf("Additive-schema regression failed: %d invariant differences",length(issues)),call.=FALSE)
}

cat(sprintf("PASS: additive schema regression preserved %d records and all identity/deduplication/existing-canonical invariants\n",base$n))
