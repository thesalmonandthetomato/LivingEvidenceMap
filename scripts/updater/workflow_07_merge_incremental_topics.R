#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(readr);library(dplyr);library(jsonlite);library(digest)})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}

current_records_path<-arg("--current-records")
reused_scores_path<-arg("--reused-scores")
fresh_scores_path<-arg("--fresh-scores","")
fresh_record_results_path<-arg("--fresh-record-results","")
prepare_manifest_path<-arg("--prepare-manifest")
ontology_path<-arg("--ontology","data/reference/topic_ontology_v3_6.csv")
output_dir<-arg("--output-dir","outputs/workflow07_topic_complete")

req<-c(current_records_path,reused_scores_path,prepare_manifest_path,ontology_path)
if(any(vapply(req,function(p)is.null(p)||!file.exists(p),logical(1))))stop("Required Workflow 07 merge input missing",call.=FALSE)
if(nzchar(fresh_scores_path)&&!file.exists(fresh_scores_path))stop("Fresh W07 scores missing",call.=FALSE)
if(nzchar(fresh_record_results_path)&&!file.exists(fresh_record_results_path))stop("Fresh W07 record results missing",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

current<-read_csv(current_records_path,show_col_types=FALSE,progress=FALSE)
reuse<-read_csv(reused_scores_path,show_col_types=FALSE,progress=FALSE)
fresh<-if(nzchar(fresh_scores_path))read_csv(fresh_scores_path,show_col_types=FALSE,progress=FALSE)else reuse[0,,drop=FALSE]
fresh_results<-if(nzchar(fresh_record_results_path))read_csv(fresh_record_results_path,show_col_types=FALSE,progress=FALSE)else tibble()
prep<-fromJSON(prepare_manifest_path,simplifyVector=FALSE)
ontology<-read_csv(ontology_path,show_col_types=FALSE,progress=FALSE)

if(any(!nzchar(current$record_id))||anyDuplicated(current$record_id))stop("Current W07 record identity invariant failed",call.=FALSE)

score_cols<-c("record_id","path_id","hierarchy_path","confidence_n","confidence_label","stars",
              "role_a","role_b","role_c","reason_a","reason_b","reason_c")
for(nm in setdiff(score_cols,names(reuse)))reuse[[nm]]<-if(nm=="confidence_n")integer(nrow(reuse))else character(nrow(reuse))
for(nm in setdiff(score_cols,names(fresh)))fresh[[nm]]<-if(nm=="confidence_n")integer(nrow(fresh))else character(nrow(fresh))
reuse<-reuse |> select(all_of(score_cols))
fresh<-fresh |> select(all_of(score_cols))

if(nrow(reuse)&&anyDuplicated(reuse[,c("record_id","path_id")]))stop("Reused W07 scores contain duplicate record/path pairs",call.=FALSE)
if(nrow(fresh)&&anyDuplicated(fresh[,c("record_id","path_id")]))stop("Fresh W07 scores contain duplicate record/path pairs",call.=FALSE)
if(length(intersect(unique(reuse$record_id),unique(fresh$record_id))))stop("Record appears in both reused and fresh W07 score sets",call.=FALSE)

fresh_expected<-as.integer(prep$screen_queue_records)
if(fresh_expected>0L){
  if(!nrow(fresh_results))stop("Fresh W07 queue is non-empty but pass-level record results are missing",call.=FALSE)
  req_fr<-c("record_id","pass");miss<-setdiff(req_fr,names(fresh_results));if(length(miss))stop("Fresh record results missing columns: ",paste(miss,collapse=", "),call.=FALSE)
  pc<-fresh_results |> transmute(record_id=as.character(record_id),pass=as.character(pass)) |> distinct() |> count(record_id,name="passes")
  if(nrow(pc)!=fresh_expected||any(pc$passes!=3L))stop("Not every freshly coded W07 record has exactly three pass-level results",call.=FALSE)
}else{
  if(nrow(fresh))stop("Fresh W07 scores supplied for zero-size screen queue",call.=FALSE)
}

all_scores<-bind_rows(reuse,fresh) |>
  mutate(record_id=as.character(record_id),path_id=as.character(path_id),
         confidence_n=as.integer(confidence_n)) |>
  arrange(record_id,path_id)

if(nrow(all_scores)){
  if(anyDuplicated(all_scores[,c("record_id","path_id")]))stop("Combined W07 scores contain duplicate record/path pairs",call.=FALSE)
  if(any(!all_scores$path_id%in%ontology$path_id))stop("Combined W07 scores contain unknown ontology IDs",call.=FALSE)
  if(any(!all_scores$confidence_n%in%1:3))stop("Combined W07 confidence_n outside 1:3",call.=FALSE)
  if(any(nchar(all_scores$stars)!=all_scores$confidence_n))stop("Combined W07 star labels do not match confidence_n",call.=FALSE)
}

known_score_ids<-unique(as.character(all_scores$record_id))
if(length(setdiff(known_score_ids,current$record_id)))stop("W07 score set contains IDs outside current population",call.=FALSE)

counts<-if(nrow(all_scores)){
  all_scores |> group_by(record_id) |> summarise(
    retained_pathways=n(),
    one_star=sum(confidence_n==1L),
    two_star=sum(confidence_n==2L),
    three_star=sum(confidence_n==3L),
    .groups="drop")
}else tibble(record_id=character(),retained_pathways=integer(),one_star=integer(),two_star=integer(),three_star=integer())

reuse_ids<-unique(as.character(reuse$record_id))
fresh_ids_from_results<-if(nrow(fresh_results))unique(as.character(fresh_results$record_id))else character()
source_map<-current |> transmute(
  record_id=as.character(record_id),
  topic_source=case_when(
    record_id%in%reuse_ids ~ "reused_workflow07",
    record_id%in%fresh_ids_from_results ~ "fresh_workflow07",
    TRUE ~ "fresh_workflow07_zero_topic"
  )
)

record_summary<-source_map |> left_join(counts,by="record_id") |>
  mutate(across(c(retained_pathways,one_star,two_star,three_star),~coalesce(as.integer(.x),0L))) |>
  arrange(record_id)

if(nrow(record_summary)!=nrow(current)||anyDuplicated(record_summary$record_id)||!setequal(record_summary$record_id,current$record_id))stop("W07 complete record summary identity/cardinality invariant failed",call.=FALSE)
if(sum(record_summary$topic_source=="reused_workflow07")!=as.integer(prep$reusable_records))stop("W07 reused record count mismatch",call.=FALSE)
if(sum(record_summary$topic_source!="reused_workflow07")!=fresh_expected)stop("W07 freshly processed record count mismatch",call.=FALSE)

write_csv(all_scores,file.path(output_dir,"workflow07_topic_pathway_scores.csv"),na="")
write_csv(record_summary,file.path(output_dir,"workflow07_topic_record_summary.csv"),na="")
write_csv(record_summary |> filter(retained_pathways==0L),file.path(output_dir,"workflow07_zero_code_records.csv"),na="")
write_csv(all_scores |> count(confidence_n,stars,name="n") |> arrange(confidence_n),
          file.path(output_dir,"workflow07_star_counts.csv"),na="")
write_csv(current,file.path(output_dir,"workflow07_records.csv"),na="")

summary<-list(
  schema="living-evidence-map-workflow07-topic-complete-v1",
  status="PASS",mode=as.character(prep$mode),
  records=nrow(record_summary),
  reused_records=as.integer(prep$reusable_records),
  fresh_records=fresh_expected,
  record_pathway_assignments=nrow(all_scores),
  one_star=sum(all_scores$confidence_n==1L),
  two_star=sum(all_scores$confidence_n==2L),
  three_star=sum(all_scores$confidence_n==3L),
  zero_code_records=sum(record_summary$retained_pathways==0L),
  ontology_sha256=digest(file=ontology_path,algo="sha256",serialize=FALSE),
  prompt_sha256=as.character(prep$prompt_sha256),
  current_records_sha256=digest(file=current_records_path,algo="sha256",serialize=FALSE),
  pathway_scores_sha256=digest(file=file.path(output_dir,"workflow07_topic_pathway_scores.csv"),algo="sha256",serialize=FALSE),
  generated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
write_json(summary,file.path(output_dir,"workflow07_topic_complete_manifest.json"),auto_unbox=TRUE,pretty=TRUE,null="null")
writeLines("PASS",file.path(output_dir,"WORKFLOW07_TOPIC_COMPLETE_PASS.ok"))
cat(sprintf("PASS: complete W07 topic state records=%d reuse=%d fresh=%d zero=%d assignments=%d\n",
            summary$records,summary$reused_records,summary$fresh_records,summary$zero_code_records,summary$record_pathway_assignments))
