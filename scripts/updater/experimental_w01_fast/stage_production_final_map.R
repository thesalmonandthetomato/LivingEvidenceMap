#!/usr/bin/env Rscript
# Produce the existing W01 cluster-map and summary schema, without external writes.
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
a<-commandArgs(trailingOnly=TRUE)
arg<-function(k){i<-match(k,a);if(is.na(i)||i==length(a))stop("Missing ",k);a[[i+1L]]}
metadata<-arg("--metadata");cluster_path<-arg("--clusters")
decisions<-arg("--final-decisions");prior<-arg("--prior-map");out<-arg("--output-dir")
if(any(!file.exists(c(metadata,cluster_path,decisions,prior)))||
 file.exists(out)||dir.exists(out))stop("Required data unavailable or destination exists")
m<-fread(metadata,colClasses=list(character=c("source","source_record_id")))
x<-fread(cluster_path,colClasses=list(character=c("source","source_record_id","cluster_id")))
p<-fread(prior,colClasses=list(character=c("source","source_record_id","cluster_id")))
d<-fread(decisions)
if(!all(c("idx","source","source_record_id")%in%names(m))||
 !all(c("source","source_record_id","cluster_id","cluster_size")%in%names(x))||
 !all(c("record_i","record_j","rescored_classification","review_route","pair_key")%in%names(d))||
 anyDuplicated(m[,.(source,source_record_id)])||
 anyDuplicated(x[,.(source,source_record_id)])||
 anyDuplicated(p[,.(source,source_record_id)])||
 !identical(as.integer(m$idx),seq_len(nrow(m))))stop("Unexpected identity/schema")
key<-function(z)paste0(nchar(z$source,type="bytes"),":",z$source,
 nchar(z$source_record_id,type="bytes"),":",z$source_record_id)
mk<-key(m);xk<-key(x);pk<-key(p)
if(!setequal(mk,xk)||any(!pk%in%mk))stop("Missing historic or final manifestation")
map<-x[match(mk,xk)]
map[,idx:=m$idx]
# The unchanged production replay retains every previous map column.
# Carry historical descriptive columns forward by stable identity so that
# target and replay schemas, as well as values, remain identical.
historic_extra <- setdiff(names(p),c("idx","source","source_record_id","cluster_id","cluster_size"))
if(length(historic_extra)){
  prev_rows <- match(mk,pk)
  for(nm in historic_extra){
    if(nm %in% names(map)) stop(sprintf("Unexpected existing map column: %s",nm))
    map[[nm]] <- p[[nm]][prev_rows]
  }
}
setcolorder(map,c("idx","source","source_record_id","cluster_id","cluster_size",historic_extra))
setorder(map,idx)
sizes<-map[,.(count=.N),by=cluster_id]
if(any(map$cluster_size!=sizes$count[match(map$cluster_id,sizes$cluster_id)]))
 stop("Incorrect final cluster sizes")
if(anyNA(d[,.(record_i,record_j,rescored_classification,review_route,pair_key)])||
 any(d$review_route=="manual_review")||
 any(d$rescored_classification=="review"))
 stop("Human adjudication remains pending; never finalise")
old_count<-uniqueN(p$cluster_id)
ninc<-nrow(map)-nrow(p)
if(ninc<0L)stop("Historic manifestations were removed")
counts<-list(workflow="01_final_adjudicated_deduplication",
 status="final",source_manifestations=nrow(map),
 total_pair_decisions=nrow(d),adjudicated_cases=0L,llm_final_decisions=0L,
 human_final_decisions=0L,abstract_strip_actions=0L,
 abstract_strip_actions_file="abstract_strip_actions.jsonl",
 workflow02_discovers_stripped_abstracts_via_normal_missing_abstract_scan=TRUE,
 unresolved_pair_decisions=0L,previous_cluster_map_supplied=TRUE,
 preserved_work_ids=sum(unique(p$cluster_id)%in%unique(map$cluster_id)),
 merged_existing_work_ids=sum(!unique(p$cluster_id)%in%unique(map$cluster_id)),
 new_work_ids=sum(!unique(map$cluster_id)%in%unique(p$cluster_id)),
 preserved_pair_decisions=NA_integer_, incremental_candidate_rows=NA_integer_,
 incremental_pair_decisions=NA_integer_,exact_duplicate_candidate_rows_removed=0L,
 total_candidate_pair_decisions=nrow(d),
 automatic_duplicate_edges=sum(d$rescored_classification=="duplicate"),
 manual_review_pairs=0L,workflow04_exclusion_candidate_pairs=sum(d$review_route=="workflow04_exclusion_candidate"),
 clusters=nrow(sizes),duplicate_clusters=sum(sizes$count>1L),
 singleton_clusters=sum(sizes$count==1L),
 manifestations_in_duplicate_clusters=sum(sizes$count[sizes$count>1L]))
# Values required for reporting must be authoritative, not fabricated.
# Callers supply the exact historical count through the original ledger audit.
audit_file<-paste0(decisions,".audit.json")
if(!file.exists(audit_file))stop("Verified cumulative decision audit missing")
aud<-fromJSON(audit_file)
if(aud$final_decisions!=nrow(d))stop("Decision audit count mismatch")
counts$preserved_pair_decisions<-as.integer(aud$historical_decisions)
counts$incremental_candidate_rows<-as.integer(aud$incremental_decisions)
counts$incremental_pair_decisions<-as.integer(aud$incremental_decisions)
dir.create(out,recursive=TRUE)
fwrite(map,file.path(out,"manifestation_cluster_map.csv"))
fwrite(data.table(retired_cluster_id=character(),surviving_cluster_id=character(),reason=character()),
 file.path(out,"cluster_id_aliases.csv"))
file.copy(decisions,file.path(out,"final_pair_decisions.csv"))
write_json(counts,file.path(out,"summary.json"),pretty=TRUE,auto_unbox=TRUE,na="null")
cat(sprintf("PASS: staged production final map: %d manifestations, %d works, %d decisions; no publication\\n",
 nrow(map),nrow(sizes),nrow(d)))
