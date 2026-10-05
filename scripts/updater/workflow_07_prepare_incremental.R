#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(readr);library(dplyr);library(jsonlite);library(digest)})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}

current_path<-arg("--current")
prior_records_path<-arg("--prior-records","")
prior_scores_path<-arg("--prior-scores","")
prior_manifest_path<-arg("--prior-manifest","")
ontology_path<-arg("--ontology","user_input/workflow07_topic_ontology.csv")
prompt_path<-arg("--prompt","data/reference/topic_system_prompt_v3_6.txt")
output_dir<-arg("--output-dir","outputs/workflow07_prepare")

if(is.null(current_path)||!file.exists(current_path))stop("--current is required",call.=FALSE)
if(!file.exists(ontology_path)||!file.exists(prompt_path))stop("Ontology/prompt missing",call.=FALSE)
for(p in c(prior_records_path,prior_scores_path,prior_manifest_path))if(nzchar(p)&&!file.exists(p))stop(sprintf("Prior W07 input missing: %s",p),call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

current<-read_csv(current_path,show_col_types=FALSE,progress=FALSE)
req<-c("record_id","title","abstract");miss<-setdiff(req,names(current));if(length(miss))stop("Current W07 input missing columns: ",paste(miss,collapse=", "),call.=FALSE)
current<-current |> mutate(record_id=as.character(record_id),title=coalesce(as.character(title),""),abstract=coalesce(as.character(abstract),""))
if(any(!nzchar(current$record_id))||anyDuplicated(current$record_id))stop("Current W07 identity invariant failed",call.=FALSE)
if(any(!nzchar(current$title)&!nzchar(current$abstract)))stop("Current W07 input contains record with neither title nor abstract",call.=FALSE)

fp<-function(t,a)digest(toJSON(list(title=t,abstract=a),auto_unbox=TRUE,null="null",na="null"),algo="sha256",serialize=FALSE)
current$topic_input_sha256<-mapply(fp,current$title,current$abstract,USE.NAMES=FALSE)
ontology_sha<-digest(file=ontology_path,algo="sha256",serialize=FALSE)
prompt_sha<-digest(file=prompt_path,algo="sha256",serialize=FALSE)

mode<-"first_run";prior_records<-tibble();prior_scores<-tibble();reuse_allowed<-FALSE
if(nzchar(prior_records_path)||nzchar(prior_scores_path)||nzchar(prior_manifest_path)){
  if(!all(nzchar(c(prior_records_path,prior_scores_path,prior_manifest_path))))stop("Prior W07 update mode requires --prior-records, --prior-scores and --prior-manifest",call.=FALSE)
  mode<-"update"
  prior_records<-read_csv(prior_records_path,show_col_types=FALSE,progress=FALSE)
  prior_scores<-read_csv(prior_scores_path,show_col_types=FALSE,progress=FALSE)
  if(!all(c("record_id","title","abstract","topic_input_sha256")%in%names(prior_records)))stop("Prior W07 records lack title/abstract/fingerprint columns",call.=FALSE)
  prior_records<-prior_records |> mutate(
    record_id=as.character(record_id),
    title=coalesce(as.character(title),""),
    abstract=coalesce(as.character(abstract),""),
    topic_input_sha256=coalesce(as.character(topic_input_sha256),"")
  )
  pm<-fromJSON(prior_manifest_path,simplifyVector=FALSE)
  if(any(!nzchar(prior_records$record_id))||anyDuplicated(prior_records$record_id))stop("Prior W07 record identity invariant failed",call.=FALSE)
  if(!all(c("record_id","path_id")%in%names(prior_scores)))stop("Prior W07 scores missing record_id/path_id",call.=FALSE)
  if(anyDuplicated(prior_scores[,c("record_id","path_id")]))stop("Prior W07 scores contain duplicate record/path pairs",call.=FALSE)
  reuse_allowed<-identical(tolower(as.character(pm$ontology_sha256)),tolower(ontology_sha)) &&
                 identical(tolower(as.character(pm$prompt_sha256)),tolower(prompt_sha))
}

prior_ids<-if(nrow(prior_records))as.character(prior_records$record_id)else character()
current_fp<-setNames(current$topic_input_sha256,current$record_id)
prior_fp<-if(nrow(prior_records))setNames(as.character(prior_records$topic_input_sha256),prior_records$record_id)else character()

if(mode=="update"&&!reuse_allowed){
  stop("Prior W07 state uses a different ontology or prompt; existing topic assessments must not be silently reclassified",call.=FALSE)
}else{
  known<-intersect(current$record_id,prior_ids)
  changed_ids<-known[current_fp[known]!=prior_fp[known]]
  new_ids<-setdiff(current$record_id,prior_ids)

  current_map<-setNames(seq_len(nrow(current)),current$record_id)
  prior_map<-setNames(seq_len(nrow(prior_records)),prior_records$record_id)
  prior_title_present<-setNames(nzchar(trimws(prior_records$title)),prior_records$record_id)
  prior_abstract_present<-setNames(nzchar(trimws(prior_records$abstract)),prior_records$record_id)
  current_title_present<-setNames(nzchar(trimws(current$title)),current$record_id)
  current_abstract_present<-setNames(nzchar(trimws(current$abstract)),current$record_id)

  title_gained_ids<-known[!prior_title_present[known] & current_title_present[known]]
  abstract_gained_ids<-known[!prior_abstract_present[known] & current_abstract_present[known]]
  refresh_ids<-sort(unique(c(title_gained_ids,abstract_gained_ids)))

  reuse_ids<-setdiff(known,refresh_ids)
  queue_ids<-c(new_ids,refresh_ids)
  reuse_reason<-"existing_record_id_reused_unless_title_or_abstract_changed_from_missing_to_present"
}

if(length(setdiff(intersect(queue_ids,prior_ids),refresh_ids)))stop("W07 invariant failed: prior record queued without an authorised missing-to-present refresh",call.=FALSE)
queue<-current |> filter(record_id%in%queue_ids)
reused_records<-current |> filter(record_id%in%reuse_ids)
reused_scores<-if(length(reuse_ids))prior_scores |> filter(record_id%in%reuse_ids) else prior_scores[0,,drop=FALSE]

write_csv(queue |> select(record_id,title,abstract),file.path(output_dir,"topic_screen_queue.csv"),na="")
write_csv(reused_records,file.path(output_dir,"reused_topic_records.csv"),na="")
write_csv(reused_scores,file.path(output_dir,"reused_topic_pathway_scores.csv"),na="")
write_csv(current,file.path(output_dir,"current_topic_records.csv"),na="")
queue_reason<-function(id){
  tg<-id%in%title_gained_ids
  ag<-id%in%abstract_gained_ids
  if(tg&&ag)return("missing_title_and_abstract_now_present")
  if(tg)return("missing_title_now_present")
  if(ag)return("missing_abstract_now_present")
  "new_record_id"
}
write_csv(tibble(record_id=queue$record_id,
                 queue_reason=vapply(queue$record_id,queue_reason,character(1)),
                 title_gained=queue$record_id%in%title_gained_ids,
                 abstract_gained=queue$record_id%in%abstract_gained_ids,
                 topic_input_sha256=queue$topic_input_sha256),
          file.path(output_dir,"topic_screen_queue_manifest.csv"),na="")
write_csv(tibble(
  record_id=refresh_ids,
  prior_title_present=unname(prior_title_present[refresh_ids]),
  current_title_present=unname(current_title_present[refresh_ids]),
  prior_abstract_present=unname(prior_abstract_present[refresh_ids]),
  current_abstract_present=unname(current_abstract_present[refresh_ids]),
  refresh_reason=vapply(refresh_ids,queue_reason,character(1))
),file.path(output_dir,"scientific_input_refresh_records.csv"),na="")

manifest<-list(
  schema="living-evidence-map-workflow07-incremental-prepare-v1",status="PASS",mode=mode,
  current_records=nrow(current),prior_records=length(prior_ids),
  reusable_records=length(reuse_ids),screen_queue_records=nrow(queue),
  new_record_ids=length(new_ids),changed_title_abstract=length(changed_ids),
  existing_records_title_gained=length(title_gained_ids),
  existing_records_abstract_gained=length(abstract_gained_ids),
  existing_records_title_and_abstract_gained=length(intersect(title_gained_ids,abstract_gained_ids)),
  existing_records_refreshed=length(refresh_ids),
  scientific_input_refresh_rule="missing_to_present_title_or_abstract_only",
  prior_records_no_longer_current=length(setdiff(prior_ids,current$record_id)),
  reuse_allowed=reuse_allowed,reuse_basis=reuse_reason,
  previously_assessed_records_requeued_only_for_missing_to_present_text=TRUE,
  changed_title_abstract_reused=length(setdiff(changed_ids,refresh_ids)),
  fingerprint_fields=c("title","abstract"),
  ontology_sha256=ontology_sha,prompt_sha256=prompt_sha,
  current_input_sha256=digest(file=current_path,algo="sha256",serialize=FALSE),
  generated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
write_json(manifest,file.path(output_dir,"prepare_manifest.json"),auto_unbox=TRUE,pretty=TRUE,null="null")
cat(sprintf("PASS: W07 %s preparation current=%d reuse=%d screen=%d new=%d missing-to-present=%d changed=%d\n",mode,nrow(current),length(reuse_ids),nrow(queue),length(new_ids),length(refresh_ids),length(changed_ids)))
