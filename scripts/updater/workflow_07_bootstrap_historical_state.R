#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(readr);library(jsonlite);library(digest)})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}

w06_path<-arg("--w06")
scores_path<-arg("--scores")
summary_path<-arg("--record-summary")
zero_path<-arg("--zero-rescreen")
qc_dir<-arg("--qc-dir")
ontology_path<-arg("--ontology")
prompt_path<-arg("--prompt")
output_dir<-arg("--output-dir")
source_runs<-arg("--source-runs","36264955447,36304758204,36305907080")

req<-c(w06_path,scores_path,summary_path,zero_path,qc_dir,ontology_path,prompt_path,output_dir)
if(any(vapply(req,function(x)is.null(x)||!nzchar(x),logical(1))))stop("Missing required bootstrap argument",call.=FALSE)
for(p in c(w06_path,scores_path,summary_path,zero_path,ontology_path,prompt_path))if(!file.exists(p))stop("Missing input: ",p,call.=FALSE)
if(!dir.exists(qc_dir))stop("Missing QC directory: ",qc_dir,call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

clean<-function(x){x<-as.character(x);x[is.na(x)]<-"";x}
fp<-function(t,a)digest(toJSON(list(title=t,abstract=a),auto_unbox=TRUE,null="null",na="null"),algo="sha256",serialize=FALSE)

w06<-read_csv(w06_path,show_col_types=FALSE,progress=FALSE)
if(!all(c("record_id","title","abstract")%in%names(w06)))stop("Historical W06 lacks record_id/title/abstract",call.=FALSE)
w06<-w06[,c("record_id","title","abstract")]
w06$record_id<-clean(w06$record_id);w06$title<-clean(w06$title);w06$abstract<-clean(w06$abstract)
if(any(!nzchar(w06$record_id))||anyDuplicated(w06$record_id))stop("Historical W06 identity invariant failed",call.=FALSE)
if(any(!nzchar(w06$title)&!nzchar(w06$abstract)))stop("Historical W06 contains record with neither title nor abstract",call.=FALSE)
w06$topic_input_sha256<-mapply(fp,w06$title,w06$abstract,USE.NAMES=FALSE)

scores<-read_csv(scores_path,show_col_types=FALSE,progress=FALSE)
rs<-read_csv(summary_path,show_col_types=FALSE,progress=FALSE)
if(!all(c("record_id","path_id")%in%names(scores)))stop("Historical W07 scores missing record_id/path_id",call.=FALSE)
if(anyDuplicated(scores[,c("record_id","path_id")]))stop("Historical W07 scores contain duplicate record/path pairs",call.=FALSE)
if(!"record_id"%in%names(rs)||anyDuplicated(rs$record_id))stop("Historical W07 record summary identity invariant failed",call.=FALSE)
if(!setequal(w06$record_id,as.character(rs$record_id)))stop("Historical W06 and W07 record populations differ",call.=FALSE)
if(length(setdiff(unique(as.character(scores$record_id)),w06$record_id)))stop("Historical W07 score IDs outside W06 population",call.=FALSE)

qc_files<-c(
 retained="workflow07_topic_pathway_scores_retained.csv",
 qc="workflow07_topic_record_qc.csv",
 human="workflow07_workflow08_human_review_queue.csv",
 late="workflow07_late_automatic_exclusions.csv",
 uncoded="workflow07_included_uncoded.csv",
 high="workflow07_high_topic_automated_qc.csv",
 qc_summary="workflow07_qc_summary.json"
)
qc_paths<-file.path(qc_dir,qc_files)
names(qc_paths)<-names(qc_files)
for(p in qc_paths)if(!file.exists(p))stop("Missing final W07 QC file: ",p,call.=FALSE)
qcs<-fromJSON(qc_paths[["qc_summary"]],simplifyVector=FALSE)
if(as.integer(qcs$records)!=nrow(w06))stop("Final W07 QC population does not match W06/W07 population",call.=FALSE)

zero_lines<-readLines(zero_path,warn=FALSE,encoding="UTF-8");zero_lines<-zero_lines[nzchar(trimws(zero_lines))]
if(length(zero_lines)){
  zero_ids<-vapply(zero_lines,function(z)as.character(fromJSON(z,simplifyVector=FALSE)$record_id),character(1))
  if(any(!nzchar(zero_ids))||anyDuplicated(zero_ids)||length(setdiff(zero_ids,w06$record_id)))stop("Historical zero-topic state identity invariant failed",call.=FALSE)
}

ontology_sha<-digest(file=ontology_path,algo="sha256",serialize=FALSE)
prompt_sha<-digest(file=prompt_path,algo="sha256",serialize=FALSE)

write_csv(w06,file.path(output_dir,"workflow07_records.csv"),na="")
file.copy(scores_path,file.path(output_dir,"workflow07_topic_pathway_scores.csv"),overwrite=TRUE)
file.copy(summary_path,file.path(output_dir,"workflow07_topic_record_summary.csv"),overwrite=TRUE)
file.copy(zero_path,file.path(output_dir,"workflow07_zero_topic_targeted_rescreen.jsonl"),overwrite=TRUE)
for(nm in names(qc_paths))file.copy(qc_paths[[nm]],file.path(output_dir,basename(qc_paths[[nm]])),overwrite=TRUE)
file.copy(ontology_path,file.path(output_dir,"topic_ontology_v3_6.csv"),overwrite=TRUE)
file.copy(prompt_path,file.path(output_dir,"topic_system_prompt_v3_6.txt"),overwrite=TRUE)

manifest<-list(
 schema="living-evidence-map-workflow07-topic-complete-v1",
 status="PASS",
 mode="historical_validated_state_migration",
 records=nrow(w06),
 reused_records=nrow(w06),
 fresh_records=0L,
 record_pathway_assignments=nrow(scores),
 one_star=sum(as.integer(scores$confidence_n)==1L,na.rm=TRUE),
 two_star=sum(as.integer(scores$confidence_n)==2L,na.rm=TRUE),
 three_star=sum(as.integer(scores$confidence_n)==3L,na.rm=TRUE),
 zero_code_records=as.integer(qcs$zero_topic_records),
 ontology_sha256=ontology_sha,
 prompt_sha256=prompt_sha,
 current_records_sha256=digest(file=file.path(output_dir,"workflow07_records.csv"),algo="sha256",serialize=FALSE),
 pathway_scores_sha256=digest(file=file.path(output_dir,"workflow07_topic_pathway_scores.csv"),algo="sha256",serialize=FALSE),
 migration_source_runs=strsplit(source_runs,",",fixed=TRUE)[[1]],
 migration_note="Reconstructed durable baseline from validated historical W06 population, W07 topic handoff, zero-topic rescreen and final QC artifacts; no model calls were made.",
 generated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
write_json(manifest,file.path(output_dir,"workflow07_topic_complete_manifest.json"),auto_unbox=TRUE,pretty=TRUE,null="null")

audit<-list(
 schema="living-evidence-map-workflow07-historical-bootstrap-v1",
 status="PASS",
 records=nrow(w06),
 score_rows=nrow(scores),
 zero_topic_state_rows=length(zero_lines),
 source_runs=strsplit(source_runs,",",fixed=TRUE)[[1]],
 output_records_sha256=digest(file=file.path(output_dir,"workflow07_records.csv"),algo="sha256",serialize=FALSE),
 output_scores_sha256=digest(file=file.path(output_dir,"workflow07_topic_pathway_scores.csv"),algo="sha256",serialize=FALSE),
 ontology_sha256=ontology_sha,
 prompt_sha256=prompt_sha,
 generated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
write_json(audit,file.path(output_dir,"workflow07_historical_bootstrap_audit.json"),auto_unbox=TRUE,pretty=TRUE,null="null")
writeLines("PASS",file.path(output_dir,"WORKFLOW07_HISTORICAL_BOOTSTRAP_PASS.ok"))
cat(sprintf("PASS: bootstrapped durable historical W07 state; records=%d scores=%d zero_state=%d\n",nrow(w06),nrow(scores),length(zero_lines)))
