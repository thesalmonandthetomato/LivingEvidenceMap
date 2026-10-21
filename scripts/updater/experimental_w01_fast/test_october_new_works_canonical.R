#!/usr/bin/env Rscript
# Real October scientific builder smoke test on all 16 newly created singleton works.
# Input is independently preserved reference maps and tail slices from existing Actions.
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})\n`%||%`<-function(a,b)if(is.null(a))b else a
mapz<-"reference/outputs/final/manifestation_cluster_map.csv"
priorz<-"reference/previous_state/workflow01_full_five_source/manifestation_cluster_map.csv"
tails<-"tails/outputs/workflow01_union"
new<-fread(mapz,colClasses=list(character=c("source","source_record_id","cluster_id")))
old<-fread(priorz,colClasses=list(character=c("source","source_record_id","cluster_id")))
identity<-function(d)paste0(nchar(d$source,type="bytes"),":",d$source,nchar(d$source_record_id,type="bytes"),":",d$source_record_id)
new[,key:=identity(new)];old[,key:=identity(old)]
stopifnot(!anyDuplicated(new$key),!anyDuplicated(old$key),all(old$key%in%new$key))
appended<-new[!key%in%old$key]
newworks<-appended[!cluster_id%in%old$cluster_id]
if(nrow(appended)!=60L||nrow(newworks)!=16L||uniqueN(newworks$cluster_id)!=16L)
 stop("Unexpected October appended/new-work counts")
if(any(new[,.(N=.N),by=cluster_id][cluster_id%in%newworks$cluster_id,N]!=1L))
 stop("New works are not all singleton")
dir.create("real_new_work_fixture")
sources<-list()
found<-character()
for(src in c("cab","proquest")){
 p<-file.path(tails,paste0(src,"_records_for_deduplication.jsonl"))
 if(!file.exists(p))stop(paste("Missing source tail",src))
 # Tail begins inside a JSONL record, so explicitly drop the truncated first line.
 lines<-readLines(p,warn=FALSE,encoding="UTF-8")
 if(length(lines)<2L)stop("Missing complete source lines")
 out<-character()
 for(line in lines[-1L]){
  z<-tryCatch(fromJSON(line,simplifyVector=FALSE),error=function(e)NULL)
  if(is.null(z))next
  id<-as.character(z$sidecar_identity$sidecar_record_id %||% "")
  k<-paste0(nchar(src,type="bytes"),":",src,nchar(id,type="bytes"),":",id)
  if(k%in%newworks$key){out<-c(out,line);found<-c(found,k)}
 }
 f<-file.path("real_new_work_fixture",paste0(src,".jsonl"))
 writeLines(out,f,useBytes=TRUE)
 sources[[src]]<-list(f)
}
if(length(found)!=16L||anyDuplicated(found)||!setequal(found,newworks$key))
 stop("New works missing or duplicated in preserved source tails")
fwrite(newworks[,.(source,source_record_id,cluster_id,cluster_size)],"real_new_work_fixture/new_works.csv")
manifest<-list(schema="living-evidence-map-workflow01-source-inputs-v1",sources=sources)
write_json(manifest,"real_new_work_fixture/source_inputs.json",auto_unbox=TRUE,pretty=TRUE)
file.create("real_new_work_fixture/empty_strips.jsonl")
file.create("real_new_work_fixture/empty_repairs.jsonl")
args<-c("scripts/updater/workflow_01_build_canonical_jsonl.R",
 "--cluster-map","real_new_work_fixture/new_works.csv",
 "--input-manifest","real_new_work_fixture/source_inputs.json",
 "--run-id","october-w01-fast-real-fixture",
 "--strip-actions","real_new_work_fixture/empty_strips.jsonl",
 "--data-quality-repairs","real_new_work_fixture/empty_repairs.jsonl",
 "--output","real_new_work_fixture/canonical.jsonl",
 "--manifest","real_new_work_fixture/canonical_manifest.json",
 "--repair-audit","real_new_work_fixture/repair_audit.jsonl")
z<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),args,stdout=TRUE,stderr=TRUE))
code<-attr(z,"status");if(is.null(code))code<-0L
if(code!=0L)stop(paste("Unmodified builder failed:",paste(z,collapse=" | ")))
results<-readLines("real_new_work_fixture/canonical.jsonl",warn=FALSE)
if(length(results)!=16L)stop("Expected 16 canonical singleton work records")
ids<-vapply(results,function(line)as.character(fromJSON(line,simplifyVector=FALSE)$deduplication$cluster_id),character(1))
if(anyDuplicated(ids)||!setequal(ids,newworks$cluster_id))stop("Canonical new work IDs differ from reference")
write_json(list(schema="w01-fast-october-16-real-new-canonical-fixture-v1",
 appended_manifestations=nrow(appended),new_singleton_works=nrow(newworks),
 generated_canonical_works=length(results),
 canonical_content_sha256=digest(file="real_new_work_fixture/canonical.jsonl",algo="sha256"),
 compared_to_production_canonical_records=FALSE,
 production_publication_allowed=FALSE),
 "real_new_work_fixture/report.json",pretty=TRUE,auto_unbox=TRUE)
cat("PASS: unmodified W01 canonical builder materialised all 16 actual October new singleton works\n")
`%||%`<-function(a,b)if(is.null(a))b else a
