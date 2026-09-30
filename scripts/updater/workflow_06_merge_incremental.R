#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(readr);library(dplyr);library(jsonlite);library(digest)})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
current_path<-arg("--current")
reuse_path<-arg("--reused")
fresh_path<-arg("--fresh","")
prepare_manifest_path<-arg("--prepare-manifest")
prompt_path<-arg("--prompt","config/workflow06_geography_semantic_prompt_v2.txt")
output_dir<-arg("--output-dir","outputs/workflow06_final")
if(any(vapply(c(current_path,reuse_path,prepare_manifest_path,prompt_path),function(p)is.null(p)||!file.exists(p),logical(1))))stop("Required W06 merge input missing",call.=FALSE)
if(nzchar(fresh_path)&&!file.exists(fresh_path))stop("Fresh W06 geography layer not found",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

current<-read_csv(current_path,show_col_types=FALSE,progress=FALSE)
reuse<-read_csv(reuse_path,show_col_types=FALSE,progress=FALSE)
fresh<-if(nzchar(fresh_path))read_csv(fresh_path,show_col_types=FALSE,progress=FALSE)else current[0,,drop=FALSE]
prep<-fromJSON(prepare_manifest_path,simplifyVector=FALSE)

if(any(!nzchar(current$record_id))||anyDuplicated(current$record_id)||anyDuplicated(current$record_sequence))stop("Current W06 identity/sequence invariant failed",call.=FALSE)
for(z in list(reuse,fresh))if(nrow(z)&&(any(!nzchar(z$record_id))||anyDuplicated(z$record_id)))stop("Reused/fresh W06 identity invariant failed",call.=FALSE)
if(length(intersect(reuse$record_id,fresh$record_id)))stop("Record appears in both reused and fresh W06 layers",call.=FALSE)
if(!setequal(c(reuse$record_id,fresh$record_id),current$record_id)){
  stop(sprintf("W06 complete-layer coverage mismatch: missing=%d extra=%d",
               length(setdiff(current$record_id,c(reuse$record_id,fresh$record_id))),
               length(setdiff(c(reuse$record_id,fresh$record_id),current$record_id))),call.=FALSE)
}
if(nrow(reuse)!=as.integer(prep$reusable_records)||nrow(fresh)!=as.integer(prep$screen_queue_records))stop("W06 prepared/merged count mismatch",call.=FALSE)

# Ensure every row uses current sequence/text/deterministic QC inputs.
current_core<-current |> select(record_id,record_sequence,title,abstract,geography_input_sha256,
                                deterministic_primary_countries,deterministic_primary_iso3c,
                                geography_review_required,geography_review_reason)
semantic_cols<-c("record_id","geography_status","luna_iso3c","luna_country_names","luna_evidence",
                 "luna_mapping_reason","evidence_all_grounded","geography_reason","llm_failed","llm_error")
ensure_cols<-function(x){
  for(nm in setdiff(semantic_cols,names(x))){
    x[[nm]]<-if(nm%in%c("evidence_all_grounded","llm_failed"))logical(nrow(x))else character(nrow(x))
  }
  x
}
reuse<-ensure_cols(reuse);fresh<-ensure_cols(fresh)
sem<-bind_rows(reuse |> select(all_of(semantic_cols)),fresh |> select(all_of(semantic_cols)))
x<-current_core |> left_join(sem,by="record_id") |> arrange(record_sequence)
if(nrow(x)!=nrow(current)||any(is.na(x$geography_status)))stop("W06 semantic merge failed to cover current records",call.=FALSE)

norm_set<-function(z){
  z<-as.character(z);z[is.na(z)]<-""
  vapply(strsplit(z,";",fixed=TRUE),function(v){
    v<-trimws(v);v<-v[nzchar(v)]
    if(!length(v))"" else paste(sort(unique(v)),collapse="; ")
  },character(1))
}
x<-x |> mutate(
  det_iso3c=norm_set(deterministic_primary_iso3c),
  luna_iso3c=norm_set(luna_iso3c),
  exact_agreement=det_iso3c==luna_iso3c,
  deterministic_none=!nzchar(det_iso3c),
  luna_none=geography_status=="NONE",
  discrepancy_type=case_when(
    llm_failed %in% TRUE ~ "llm_failure",
    !(evidence_all_grounded %in% TRUE) ~ "ungrounded_evidence",
    exact_agreement ~ "exact_agreement",
    deterministic_none & geography_status=="RESOLVED" ~ "luna_only_geography",
    !deterministic_none & luna_none ~ "deterministic_only_geography",
    TRUE ~ "different_country_set"
  )
)

allowed<-c("RESOLVED","NONE","UNRESOLVED")
if(any(!x$geography_status%in%allowed))stop("Invalid geography_status in complete W06 layer",call.=FALSE)

write_csv(x,file.path(output_dir,"geography_semantic_final.csv"),na="")
write_csv(x |> filter(geography_status=="UNRESOLVED"),file.path(output_dir,"geography_unresolved.csv"),na="")
write_csv(x |> filter(!(evidence_all_grounded %in% TRUE)),file.path(output_dir,"geography_ungrounded_evidence.csv"),na="")
write_csv(x |> filter(llm_failed %in% TRUE),file.path(output_dir,"geography_llm_failures.csv"),na="")
write_csv(x |> filter(discrepancy_type!="exact_agreement"),file.path(output_dir,"geography_deterministic_qc_discrepancies.csv"),na="")
write_csv(x |> count(discrepancy_type,name="n") |> mutate(pct=100*n/nrow(x)) |> arrange(desc(n)),
          file.path(output_dir,"discrepancy_patterns.csv"),na="")
write_csv(x |> count(geography_status,name="n") |> mutate(pct=100*n/nrow(x)),
          file.path(output_dir,"geography_status_counts.csv"),na="")

# Sparse durable layer used for downstream joins and future reuse.
keep<-c("record_id","record_sequence","geography_input_sha256",
        "deterministic_primary_countries","deterministic_primary_iso3c",
        "geography_review_required","geography_review_reason",
        "geography_status","luna_iso3c","luna_country_names","luna_evidence",
        "luna_mapping_reason","evidence_all_grounded","geography_reason",
        "llm_failed","llm_error","det_iso3c","exact_agreement",
        "deterministic_none","luna_none","discrepancy_type")
write_csv(x[,keep],file.path(output_dir,"workflow06_geography_layer.csv"),na="")

# New durable JSONL is generated from the complete current sparse state.
con<-file(file.path(output_dir,"geography_semantic_final.jsonl"),"wt",encoding="UTF-8")
on.exit(close(con),add=TRUE)
for(i in seq_len(nrow(x))){
  z<-as.list(x[i,keep,drop=FALSE])
  z<-lapply(z,function(v){if(length(v)==1L&&is.na(v))NULL else v})
  writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)
}
close(con);on.exit(NULL,add=FALSE)

prompt_sha<-digest(file=prompt_path,algo="sha256",serialize=FALSE)
summary<-list(
  schema="living-evidence-map-workflow06-final-v2",
  status="PASS",
  mode=as.character(prep$mode),
  records=nrow(x),
  reused_records=nrow(reuse),
  newly_screened_records=nrow(fresh),
  new_record_ids=as.integer(prep$new_record_ids),
  changed_title_abstract=as.integer(prep$changed_title_abstract),
  model="gpt-5.6-luna",reasoning="low",prompt_sha256=prompt_sha,
  resolved_n=sum(x$geography_status=="RESOLVED"),
  none_n=sum(x$geography_status=="NONE"),
  unresolved_n=sum(x$geography_status=="UNRESOLVED"),
  evidence_not_grounded_n=sum(!(x$evidence_all_grounded%in%TRUE)),
  llm_failures_n=sum(x$llm_failed%in%TRUE),
  exact_agreement_discrepancy_class_n=sum(x$discrepancy_type=="exact_agreement"),
  qc_discrepancies_n=sum(x$discrepancy_type!="exact_agreement"),
  current_input_sha256=digest(file=current_path,algo="sha256",serialize=FALSE),
  geography_layer_sha256=digest(file=file.path(output_dir,"workflow06_geography_layer.csv"),algo="sha256",serialize=FALSE),
  generated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
write_json(summary,file.path(output_dir,"workflow06_validated_summary.json"),auto_unbox=TRUE,pretty=TRUE)
file.copy(prompt_path,file.path(output_dir,"workflow06_geography_prompt.txt"),overwrite=TRUE)
cat(sprintf("PASS: complete W06 state records=%d reuse=%d screened=%d resolved=%d none=%d unresolved=%d failures=%d\n",
            nrow(x),nrow(reuse),nrow(fresh),summary$resolved_n,summary$none_n,summary$unresolved_n,summary$llm_failures_n))
