#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(data.table)
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

combined_path <- arg("--combined-decisions")
manifestation_map_path <- arg("--manifestation-map")
llm_path <- arg("--llm-adjudications")
human_path <- arg("--human-decisions",NULL)
output_dir <- arg("--output-dir")
if (any(vapply(list(combined_path,manifestation_map_path,llm_path,output_dir),is.null,logical(1)))) {
  stop("Required: --combined-decisions --manifestation-map --llm-adjudications --output-dir",call.=FALSE)
}
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

pairs <- fread(combined_path,na.strings=c("","NA"))
meta <- fread(manifestation_map_path,na.strings=c("","NA"))
stopifnot(all(c("pair_key","rescored_classification","rescored_rule") %in% names(pairs)))
stopifnot(all(c("idx","source","source_record_id") %in% names(meta)))
if (anyDuplicated(pairs$pair_key)) stop("Combined pair decisions contain duplicate pair keys",call.=FALSE)
setkey(pairs,pair_key)
setorder(meta,idx)
if (!identical(meta$idx,seq_len(nrow(meta)))) stop("Manifestation map idx is not contiguous",call.=FALSE)

read_jsonl <- function(path) {
  x <- readLines(path,warn=FALSE,encoding="UTF-8")
  x <- x[nzchar(trimws(x))]
  lapply(x,fromJSON,simplifyVector=FALSE)
}
llm <- read_jsonl(llm_path)
human <- if (!is.null(human_path) && file.exists(human_path)) read_jsonl(human_path) else list()
human_by_id <- if(length(human)) setNames(human,vapply(human,function(x)as.character(x$review_case_id),character(1))) else list()

audit <- vector("list",length(llm))
for (i in seq_along(llm)) {
  a <- llm[[i]]
  key <- as.character(a$pair_key)
  if (!(key %in% pairs$pair_key)) stop(sprintf("Adjudication pair not found in combined state: %s",key),call.=FALSE)

  final_decision <- NULL
  provenance <- NULL
  if (identical(a$promotion,"duplicate") || identical(a$promotion,"not_duplicate")) {
    final_decision <- a$promotion
    provenance <- "llm"
  } else if (identical(a$promotion,"human_review")) {
    h <- human_by_id[[as.character(a$review_case_id)]]
    if (is.null(h)) stop(sprintf("Missing human decision for %s",a$review_case_id),call.=FALSE)
    if (is.null(h$decision) || !(h$decision %in% c("duplicate","not_duplicate"))) {
      stop(sprintf("Human decision for %s is not final",a$review_case_id),call.=FALSE)
    }
    final_decision <- h$decision
    provenance <- "human"
  } else stop(sprintf("Invalid promotion for %s",a$review_case_id),call.=FALSE)

  before <- pairs[.(key),rescored_classification]
  pairs[.(key),`:=`(
    rescored_classification=final_decision,
    rescored_rule=paste0("workflow01_",provenance,"_adjudication")
  )]
  audit[[i]] <- list(
    review_case_id=a$review_case_id,
    pair_key=key,
    before=before,
    after=final_decision,
    decision_source=provenance,
    model_decision=a$model_decision,
    model_confidence=a$model_confidence,
    model_rationale=a$model_rationale,
    human_decision=if(provenance=="human") human_by_id[[a$review_case_id]]$decision else NULL,
    human_rationale=if(provenance=="human") human_by_id[[a$review_case_id]]$rationale else NULL
  )
}

fwrite(pairs,file.path(output_dir,"final_pair_decisions.csv"))
audit_con <- file(file.path(output_dir,"adjudication_application_audit.jsonl"),"wt",encoding="UTF-8")
for (z in audit) writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null"),audit_con,useBytes=TRUE)
close(audit_con)

parent <- seq_len(nrow(meta))
rank <- integer(nrow(meta))
find_root <- function(x) {
  while(parent[[x]]!=x) {
    parent[[x]] <<- parent[[parent[[x]]]]
    x <- parent[[x]]
  }
  x
}
union_nodes <- function(a,b) {
  ra <- find_root(a); rb <- find_root(b)
  if (ra==rb) return(invisible(NULL))
  if (rank[[ra]]<rank[[rb]]) parent[[ra]] <<- rb
  else if (rank[[ra]]>rank[[rb]]) parent[[rb]] <<- ra
  else {parent[[rb]] <<- ra; rank[[ra]] <<- rank[[ra]]+1L}
}
dup <- pairs[rescored_classification=="duplicate"]
if(nrow(dup)) for(i in seq_len(nrow(dup))) union_nodes(dup$record_i[[i]],dup$record_j[[i]])
roots <- vapply(seq_len(nrow(meta)),find_root,integer(1))
groups <- split(seq_len(nrow(meta)),roots)

cluster_rows <- vector("list",length(groups))
map_rows <- vector("list",length(groups))
k <- 0L
for(g in groups) {
  k <- k+1L
  keys <- paste(meta$source[g],meta$source_record_id[g],sep=":")
  cid <- paste0("work-",substr(digest(paste(sort(keys),collapse="|"),algo="sha256",serialize=FALSE),1,16))
  cluster_rows[[k]] <- list(
    cluster_id=cid,
    status=if(length(g)>1L)"reconciled" else "singleton",
    member_count=length(g),
    members=lapply(g,function(i)list(idx=meta$idx[[i]],source=meta$source[[i]],source_record_id=meta$source_record_id[[i]]))
  )
  map_rows[[k]] <- data.table(idx=g,source=meta$source[g],source_record_id=meta$source_record_id[g],
                              cluster_id=cid,cluster_size=length(g))
}
map <- rbindlist(map_rows)
setorder(map,idx)
fwrite(map,file.path(output_dir,"manifestation_cluster_map.csv"))
con <- file(file.path(output_dir,"clusters.jsonl"),"wt",encoding="UTF-8")
for(z in cluster_rows) writeLines(toJSON(z,auto_unbox=TRUE,null="null"),con,useBytes=TRUE)
close(con)

remaining <- pairs[rescored_classification=="review" | review_route=="manual_review"]
sizes <- map[,.(cluster_size=.N),by=cluster_id]
summary <- list(
  workflow="01_final_adjudicated_deduplication",
  status=if(nrow(remaining)==0L)"final" else "incomplete",
  source_manifestations=nrow(meta),
  total_pair_decisions=nrow(pairs),
  adjudicated_cases=length(llm),
  llm_final_decisions=sum(vapply(audit,function(x)identical(x$decision_source,"llm"),logical(1))),
  human_final_decisions=sum(vapply(audit,function(x)identical(x$decision_source,"human"),logical(1))),
  unresolved_pair_decisions=nrow(remaining),
  automatic_duplicate_edges=nrow(dup),
  clusters=nrow(sizes),
  duplicate_clusters=sum(sizes$cluster_size>1L),
  singleton_clusters=sum(sizes$cluster_size==1L),
  manifestations_in_duplicate_clusters=sum(sizes$cluster_size[sizes$cluster_size>1L])
)
if (nrow(remaining)) {
  fwrite(remaining,file.path(output_dir,"unresolved_pairs.csv"))
  stop(sprintf("Finalisation blocked: %d unresolved pair decisions remain",nrow(remaining)),call.=FALSE)
}
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null"),
           file.path(output_dir,"summary.json"))
cat(sprintf("PASS: Workflow 01 finalised after adjudication: %d manifestations, %d clusters, %d adjudicated cases\n",
            nrow(meta),nrow(sizes),length(llm)))
