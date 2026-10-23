#!/usr/bin/env Rscript
# Fail-closed assembly of canonical output contract. NO publication or state writes.
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
argv<-commandArgs(trailingOnly=TRUE)
arg<-function(n){i<-match(n,argv);if(is.na(i)||i==length(argv))stop("Missing ",n);argv[[i+1L]]}
map_path<-arg("--cluster-map");canonical_path<-arg("--canonical")
output<-arg("--output-dir");run_id<-arg("--run-id")
strips_path<-arg("--strip-actions");repairs_path<-arg("--repair-ledger")
audit_path<-arg("--repair-audit")
previous_manifest_path<-arg("--previous-canonical-manifest")
previous_repairs_path<-arg("--previous-repairs")
required<-c(map_path,canonical_path,strips_path,repairs_path,audit_path,previous_manifest_path,previous_repairs_path)
if(any(!file.exists(required))||dir.exists(output)||file.exists(output))
 stop("Missing required inputs or output already exists")
m<-fread(map_path,colClasses=list(character=c("source","source_record_id","cluster_id")))
if(!all(c("source","source_record_id","cluster_id","cluster_size")%in%names(m))||
 anyNA(m[,.(source,source_record_id,cluster_id,cluster_size)])||
 anyDuplicated(m[,.(source,source_record_id)]))stop("Invalid canonical cluster map")
lines<-readLines(canonical_path,warn=FALSE,encoding="UTF-8")
lines<-lines[nzchar(trimws(lines))]
ids<-character(length(lines)); count<-integer(length(lines))
for(i in seq_along(lines)){
 z<-fromJSON(lines[[i]],simplifyVector=FALSE)
 ids[[i]]<-as.character(z$identity$record_id)
 count[[i]]<-length(z$manifestations)
 if(!identical(z$schema_version,"living-evidence-map-canonical-v1")||
 !identical(z$deduplication$cluster_id,ids[[i]])||
 !identical(as.integer(z$deduplication$member_count),as.integer(count[[i]])))
 stop("Malformed canonical JSONL record ",i)
}
if(anyDuplicated(ids)||!setequal(ids,unique(m$cluster_id))||
 sum(count)!=nrow(m))stop("Canonical record IDs or counts differ from cluster map")
sizes<-m[,.(n=.N),by=cluster_id]
if(any(sizes$n!=count[match(sizes$cluster_id,ids)])||
 any(m$cluster_size!=sizes$n[match(m$cluster_id,sizes$cluster_id)]))
 stop("Canonical cluster membership size mismatch")
if(anyDuplicated(m[,.(source,source_record_id)]))stop("Duplicate manifestation")
nstrips<-sum(nzchar(trimws(readLines(strips_path,warn=FALSE))))
nrepairs<-sum(nzchar(trimws(readLines(repairs_path,warn=FALSE))))
audit_lines<-readLines(audit_path,warn=FALSE)
audit_lines<-audit_lines[nzchar(trimws(audit_lines))]
prev_manifest<-fromJSON(previous_manifest_path)
# The previous canonical manifest attests the PREVIOUS repair ledger, not newly
# approved Shiny edits. Verify historic repair bytes are immutable and all new
# cumulative entries are independently applied to regenerated affected works.
nonempty<-function(p){z<-readLines(p,warn=FALSE,encoding="UTF-8");z[nzchar(trimws(z))]}
history<-nonempty(previous_repairs_path);current<-nonempty(repairs_path)
key_repair<-function(line){
 z<-fromJSON(line,simplifyVector=FALSE)
 paste(as.character(z$review_case_id %||% ""),as.character(z$source),
 as.character(z$source_record_id),as.character(z$action),sep="|")
}
`%||%`<-function(x,y)if(is.null(x))y else x
hk<-if(length(history))vapply(history,key_repair,character(1))else character()
ck<-if(length(current))vapply(current,key_repair,character(1))else character()
if(anyDuplicated(hk)||anyDuplicated(ck)||any(!hk%in%ck)||
 any(unname(setNames(current,ck)[hk])!=history))
 stop("Cumulative repairs altered or dropped previously approved actions")
if(!identical(as.integer(prev_manifest$approved_data_quality_repairs),as.integer(length(history)))||
 !identical(as.integer(prev_manifest$applied_data_quality_repairs),as.integer(length(history)))||
 nrepairs!=length(current))
 stop("Prior canonical manifest or current repair count is inconsistent")
if(length(setdiff(ck,hk))){
 audits_all<-if(length(audit_lines))lapply(audit_lines,fromJSON,simplifyVector=FALSE)else list()
 ak<-if(length(audits_all))vapply(audits_all,function(z)paste(
 as.character(z$review_case_id %||% ""),as.character(z$source),
 as.character(z$source_record_id),as.character(z$action),sep="|"),character(1))else character()
 if(!all(setdiff(ck,hk)%in%ak))
  stop("Newly approved repairs are missing from the canonical application audit")
}
if(length(audit_lines)>nrepairs)stop("Changed-work repair audit exceeds cumulative repairs")
if(length(audit_lines)){
  audits<-lapply(audit_lines,fromJSON,simplifyVector=FALSE)
  if(!all(vapply(audits,function(x)identical(x$status,"applied"),logical(1))))
   stop("Not all approved repairs verified as applied")
}
sc<-m[,.(N=.N),by=source][order(source)]
sources<-setNames(as.list(sc$N),sc$source)
dir.create(output,recursive=TRUE)
file.copy(canonical_path,file.path(output,"records.jsonl"))
file.copy(audit_path,file.path(output,"data_quality_repair_application.jsonl"))
manifest<-list(schema="living-evidence-map-canonical-manifest-v1",
 canonical_schema_version="living-evidence-map-canonical-v1",
 workflow="01",github_run_id=run_id,records=length(ids),
 source_manifestations=nrow(m),duplicate_clusters=sum(count>1L),
 singleton_clusters=sum(count==1L),abstract_strip_actions=nstrips,
 approved_data_quality_repairs=nrepairs,
 applied_data_quality_repairs=nrepairs,
 repair_application_audit="data_quality_repair_application.jsonl",
 manifestations_missing_abstract=sum(vapply(lines,function(line){
 z<-fromJSON(line,simplifyVector=FALSE)
 sum(vapply(z$manifestations,function(q)is.null(q$abstract),logical(1)))
 },integer(1))),
 source_counts=sources,
 cluster_map_sha256=digest(file=map_path,algo="sha256",serialize=FALSE),
 canonical_jsonl_sha256=digest(file=file.path(output,"records.jsonl"),algo="sha256",serialize=FALSE),
 canonical_jsonl_bytes=unname(file.info(file.path(output,"records.jsonl"))$size),
 generated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ"))
write_json(manifest,file.path(output,"canonical_manifest.json"),auto_unbox=TRUE,pretty=TRUE)
cat(sprintf("PASS: staged %d canonical records from %d manifestations with verified work IDs and sizes; NO publication\\n",length(ids),nrow(m)))
