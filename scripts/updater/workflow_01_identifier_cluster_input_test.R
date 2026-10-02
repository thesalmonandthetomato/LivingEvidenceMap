#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(data.table)
  library(jsonlite)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){
  i<-match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
meta_path<-arg("--metadata")
selected_path<-arg("--selected-rescore")
safe_path<-arg("--safe-pairs")
baseline_map_path<-arg("--baseline-map")
output_path<-arg("--output")
audit_path<-arg("--audit")
if(any(vapply(list(meta_path,selected_path,safe_path,baseline_map_path,output_path,audit_path),is.null,logical(1)))) {
  stop("Required: --metadata --selected-rescore --safe-pairs --baseline-map --output --audit",call.=FALSE)
}

meta<-fread(meta_path,na.strings=c("","NA"))
sel<-fread(selected_path,na.strings=c("","NA"))
safe<-fread(safe_path,na.strings=c("","NA"))
base<-fread(baseline_map_path,na.strings=c("","NA"))
stopifnot(all(c("idx","source","source_record_id") %in% names(meta)))
stopifnot(all(c("record_i","record_j","rescored_classification","rescored_rule") %in% names(sel)))
stopifnot(all(c("record_i","record_j") %in% names(safe)))
stopifnot(all(c("idx","cluster_id") %in% names(base)))

key<-function(a,b) paste(pmin(a,b),pmax(a,b),sep="::")
sel[,pair_key:=key(record_i,record_j)]
if("source_row_index" %in% names(sel)) setorder(sel,pair_key,source_row_index)
sel_rows_raw<-nrow(sel)
sel<-unique(sel,by="pair_key")
if(nrow(sel)!=272169L) stop(sprintf("Expected 272169 unique selected rescored pairs, got %d",nrow(sel)),call.=FALSE)

meta[,manifestation_key:=paste(source,source_record_id,sep="::")]
idx_map<-setNames(meta$idx,meta$manifestation_key)
safe[,record_i_idx:=as.integer(idx_map[record_i])]
safe[,record_j_idx:=as.integer(idx_map[record_j])]
if(anyNA(safe$record_i_idx)||anyNA(safe$record_j_idx)) stop("Safe pair failed metadata mapping",call.=FALSE)
safe[,pair_key:=key(record_i_idx,record_j_idx)]
safe<-unique(safe,by="pair_key")

# No selected pair should be internal to an identifier-safe provisional component,
# therefore selected and safe edge keys must be disjoint.
overlap<-intersect(sel$pair_key,safe$pair_key)
if(length(overlap)) stop(sprintf("%d selected pairs overlap safe identifier edges",length(overlap)),call.=FALSE)

# Create schema-compatible deterministic duplicate edges. These are test-only
# pair decisions; no production state is mutated.
safe_rows<-data.table(
  record_i=safe$record_i_idx,
  record_j=safe$record_j_idx,
  rescored_classification="duplicate",
  rescored_rule="identifier_safe_preresolve",
  review_route="resolved_identifier_assist",
  pair_key=safe$pair_key,
  source_row_index=seq_len(nrow(safe))
)
new<-rbindlist(list(sel,safe_rows),use.names=TRUE,fill=TRUE)
setorder(new,record_i,record_j)
fwrite(new[, !"pair_key"],output_path)

# Explain all intended cross-baseline-cluster safe merges.
setkey(base,idx)
safe_trace<-safe_rows[,.(record_i,record_j,pair_key)]
safe_trace[,baseline_cluster_i:=base[.(record_i),cluster_id]]
safe_trace[,baseline_cluster_j:=base[.(record_j),cluster_id]]
safe_trace[,cross_baseline_cluster:=baseline_cluster_i!=baseline_cluster_j]
cross<-safe_trace[cross_baseline_cluster==TRUE]

audit<-list(
  schema="living-evidence-map-w01-identifier-assisted-cluster-input-v1",
  status="success",
  test_only=TRUE,
  selected_rescore_rows_raw=sel_rows_raw,
  selected_unique_pairs=nrow(sel),
  safe_identifier_edges=nrow(safe_rows),
  combined_incremental_decisions=nrow(new),
  selected_safe_pair_key_overlap=length(overlap),
  safe_edges_crossing_frozen_w01_clusters=nrow(cross),
  safe_edges_already_within_frozen_w01_cluster=nrow(safe_trace)-nrow(cross),
  automatic_production_merges_performed=0L,
  production_w01_modified=FALSE
)
writeLines(toJSON(audit,auto_unbox=TRUE,pretty=TRUE,null="null"),audit_path)
fwrite(safe_trace,sub("\\.json$","_safe_edge_trace.csv",audit_path))
cat("PASS: built identifier-assisted incremental decision set\n")
cat(toJSON(audit,auto_unbox=TRUE,pretty=TRUE,null="null"),"\n")
