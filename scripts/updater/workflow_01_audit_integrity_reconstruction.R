#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}

current_map_path<-arg("--current-map")
repaired_map_path<-arg("--repaired-map")
current_canonical_path<-arg("--current-canonical")
repaired_canonical_path<-arg("--repaired-canonical")
output_dir<-arg("--output-dir")
expected_clusters<-as.integer(arg("--expected-clusters","50430"))
expected_affected_ids<-as.integer(arg("--expected-affected-current-ids","9922"))
expected_retired_ids<-as.integer(arg("--expected-retired-ids","503"))
if(any(vapply(list(current_map_path,repaired_map_path,current_canonical_path,repaired_canonical_path,output_dir),is.null,logical(1))))stop("Required arguments missing",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

read_map<-function(p,label){
 x<-fread(p,na.strings=c("","NA"))
 req<-c("source","source_record_id","cluster_id");if(length(setdiff(req,names(x))))stop(sprintf("%s map missing columns",label),call.=FALSE)
 x[,key:=paste(source,source_record_id,sep="::")]
 if(anyDuplicated(x$key))stop(sprintf("%s map has duplicate manifestation identities",label),call.=FALSE)
 x
}
cur<-read_map(current_map_path,"current");rep<-read_map(repaired_map_path,"repaired")
if(!setequal(cur$key,rep$key))stop("Current/repaired manifestation populations differ",call.=FALSE)
setkey(cur,key);setkey(rep,key)
keys<-sort(cur$key)
a<-cur[J(keys)];b<-rep[J(keys)]
chg<-data.table(
 key=keys,
 source=a$source,source_record_id=a$source_record_id,
 current_cluster_id=a$cluster_id,repaired_cluster_id=b$cluster_id,
 changed=as.character(a$cluster_id)!=as.character(b$cluster_id)
)
fwrite(chg[changed==TRUE],file.path(output_dir,"changed_manifestation_cluster_assignments.csv"))
affected_current_ids<-sort(unique(chg[changed==TRUE,current_cluster_id]))
writeLines(affected_current_ids,file.path(output_dir,"affected_current_work_ids.txt"),useBytes=TRUE)

read_can<-function(p){
 lines<-readLines(p,warn=FALSE,encoding="UTF-8");lines<-lines[nzchar(trimws(lines))]
 rows<-lapply(lines,function(z){
   x<-fromJSON(z,simplifyVector=FALSE);c<-x$canonical
   data.table(
    record_id=as.character(x$identity$record_id),
    title=if(is.null(c$title))"" else as.character(c$title[[1L]]),
    abstract=if(is.null(c$abstract))"" else as.character(c$abstract[[1L]]),
    doi=if(is.null(c$doi))"" else as.character(c$doi[[1L]]),
    journal=if(is.null(c$journal))"" else as.character(c$journal[[1L]])
   )
 })
 z<-rbindlist(rows,fill=TRUE)
 if(any(!nzchar(z$record_id))||anyDuplicated(z$record_id))stop("Canonical record_id invariant failed",call.=FALSE)
 z
}
cc<-read_can(current_canonical_path);rr<-read_can(repaired_canonical_path)
current_ids<-cc$record_id;repaired_ids<-rr$record_id
retired<-sort(setdiff(current_ids,repaired_ids));new<-sort(setdiff(repaired_ids,current_ids))
writeLines(retired,file.path(output_dir,"retired_corrupt_work_ids.txt"),useBytes=TRUE)
writeLines(new,file.path(output_dir,"new_corrected_work_ids.txt"),useBytes=TRUE)

setkey(cc,record_id);setkey(rr,record_id)
common<-sort(intersect(current_ids,repaired_ids))
ca<-cc[J(common)];rb<-rr[J(common)]
field_changes<-data.table(
 record_id=common,
 title_changed=ca$title!=rb$title,
 abstract_changed=ca$abstract!=rb$abstract,
 doi_changed=ca$doi!=rb$doi,
 journal_changed=ca$journal!=rb$journal
)
field_changes[,any_changed:=title_changed|abstract_changed|doi_changed|journal_changed]
fwrite(field_changes[any_changed==TRUE],file.path(output_dir,"canonical_field_changes_common_ids.csv"))

summary<-list(
 schema="living-evidence-map-w01-integrity-repair-audit-v1",
 status="PASS",
 manifestations=nrow(cur),
 current_clusters=uniqueN(cur$cluster_id),
 repaired_clusters=uniqueN(rep$cluster_id),
 changed_manifestation_cluster_assignments=sum(chg$changed),
 affected_current_work_ids=length(affected_current_ids),
 current_canonical_records=nrow(cc),
 repaired_canonical_records=nrow(rr),
 retired_current_work_ids=length(retired),
 new_corrected_work_ids=length(new),
 common_ids_with_title_change=sum(field_changes$title_changed),
 common_ids_with_abstract_change=sum(field_changes$abstract_changed),
 common_ids_with_doi_change=sum(field_changes$doi_changed),
 common_ids_with_journal_change=sum(field_changes$journal_changed),
 common_ids_with_any_core_field_change=sum(field_changes$any_changed),
 current_canonical_sha256=digest(file=current_canonical_path,algo="sha256",serialize=FALSE),
 repaired_canonical_sha256=digest(file=repaired_canonical_path,algo="sha256",serialize=FALSE)
)
if(summary$repaired_clusters!=expected_clusters||summary$repaired_canonical_records!=expected_clusters)stop(sprintf("Repaired W01 count mismatch: clusters=%d canonical=%d expected=%d",summary$repaired_clusters,summary$repaired_canonical_records,expected_clusters),call.=FALSE)
if(summary$affected_current_work_ids!=expected_affected_ids)stop(sprintf("Affected current work-id count mismatch: %d expected %d",summary$affected_current_work_ids,expected_affected_ids),call.=FALSE)
if(summary$retired_current_work_ids!=expected_retired_ids||summary$new_corrected_work_ids!=expected_retired_ids)stop(sprintf("Retired/new work-id mismatch: retired=%d new=%d expected=%d",summary$retired_current_work_ids,summary$new_corrected_work_ids,expected_retired_ids),call.=FALSE)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null"),file.path(output_dir,"audit_summary.json"),useBytes=TRUE)
cat(sprintf("PASS: repaired W01 clusters=%d; affected current IDs=%d; retired/new=%d/%d\n",summary$repaired_clusters,summary$affected_current_work_ids,summary$retired_current_work_ids,summary$new_corrected_work_ids))
