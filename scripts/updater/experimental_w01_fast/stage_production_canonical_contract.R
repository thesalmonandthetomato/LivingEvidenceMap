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
required<-c(map_path,canonical_path,strips_path,repairs_path,audit_path,previous_manifest_path)
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
if(!identical(as.integer(prev_manifest$approved_data_quality_repairs),as.integer(nrepairs))||
 !identical(as.integer(prev_manifest$applied_data_quality_repairs),as.integer(nrepairs)))
 stop("Cumulative repair ledger differs from the verified prior canonical manifest; full W01 handling required")
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
