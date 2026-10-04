#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(readr);library(dplyr);library(jsonlite);library(digest)})
source("R/geography_grounding.R")

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}

w05_path<-arg("--w05")
w06_path<-arg("--w06")
w06_grounding_residual_path<-arg("--w06-grounding-residual","")
w07_records_path<-arg("--w07-records")
w07_review_path<-arg("--w07-review")
w07_scores_path<-arg("--w07-scores")
w07_late_path<-arg("--w07-late-exclusions")
out_dir<-arg("--output-dir","outputs/workflow08_intake_current")

req<-c(w05_path,w06_path,w07_records_path,w07_review_path,w07_scores_path,w07_late_path)
if(any(vapply(req,function(p)is.null(p)||!file.exists(p),logical(1))))stop("Required W05-W07 input missing",call.=FALSE)
if(nzchar(w06_grounding_residual_path)&&!file.exists(w06_grounding_residual_path))stop("W06 grounding residual file missing",call.=FALSE)
dir.create(out_dir,recursive=TRUE,showWarnings=FALSE)

clean_chr<-function(x){z<-as.character(x);z[is.na(z)]<-"";z}
is_true<-function(x)toupper(clean_chr(x))=="TRUE"
norm_iso_set<-function(x){
  z<-trimws(unlist(strsplit(clean_chr(x),";",fixed=TRUE),use.names=FALSE))
  z<-z[nzchar(z)]
  paste(sort(unique(z)),collapse=";")
}
canon_hash<-function(x)digest(toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA,pretty=FALSE),algo="sha256",serialize=FALSE)
jac_set<-function(a,b){
  u<-union(a,b)
  if(!length(u)) return(1)
  length(intersect(a,b))/length(u)
}

w05<-read_csv(w05_path,show_col_types=FALSE,progress=FALSE)
w06<-read_csv(w06_path,show_col_types=FALSE,progress=FALSE)
ctx<-read_csv(w07_records_path,show_col_types=FALSE,progress=FALSE)
w07q<-read_csv(w07_review_path,show_col_types=FALSE,progress=FALSE)
w07s<-read_csv(w07_scores_path,show_col_types=FALSE,progress=FALSE)
w07x<-read_csv(w07_late_path,show_col_types=FALSE,progress=FALSE)
g_resid<-if(nzchar(w06_grounding_residual_path))read_csv(w06_grounding_residual_path,show_col_types=FALSE,progress=FALSE)else tibble(record_id=character())
gazetteer<-read_csv("config/global_country_gazetteer_v3.csv",show_col_types=FALSE,progress=FALSE)

for(z in list(w05,w06,ctx))if(!"record_id"%in%names(z)||any(!nzchar(as.character(z$record_id)))||anyDuplicated(z$record_id))stop("W05/W06/W07 context identity invariant failed",call.=FALSE)
if(!setequal(w05$record_id,ctx$record_id)||!setequal(w06$record_id,ctx$record_id))stop("W05/W06/W07 current populations do not match",call.=FALSE)
if(!all(c("record_id","title","abstract")%in%names(ctx)))stop("W07 records must provide record_id/title/abstract",call.=FALSE)

# Preserve current record order from W07 state.
context<-ctx |> transmute(
  record_sequence=if("record_sequence"%in%names(ctx))as.integer(record_sequence)else seq_len(n()),
  record_id=as.character(record_id),
  title=clean_chr(title),
  abstract=clean_chr(abstract)
)

issue_map<-setNames(vector("list",nrow(context)),context$record_id)
add_issue<-function(record_id,issue){
  rid<-as.character(record_id)
  if(!rid%in%names(issue_map))stop("Issue record absent from current context: ",rid,call.=FALSE)
  state<-list(
    review_key=paste(rid,as.character(issue$issue_type),sep="::"),
    record_id=rid,
    issue_type=as.character(issue$issue_type),
    source_workflow=as.character(issue$source_workflow),
    title=context$title[match(rid,context$record_id)],
    abstract=context$abstract[match(rid,context$record_id)],
    automated_value=issue$automated_value,
    allowed_human_outcomes=issue$allowed_human_outcomes
  )
  issue$issue_state_sha256<-canon_hash(state)
  issue_map[[rid]]<<-c(issue_map[[rid]],list(issue))
}

# W05 species NONE.
if(!all(c("farmed_species_codes","farmed_species")%in%names(w05)))stop("W05 layer lacks species columns",call.=FALSE)
w05_none<-w05 |> filter(farmed_species_codes=="NONE")
for(i in seq_len(nrow(w05_none))){
  z<-w05_none[i,,drop=FALSE]
  add_issue(z$record_id,list(
    source_workflow="05",issue_type="species_none",
    automated_value=list(farmed_species_codes="NONE",farmed_species="NONE"),
    allowed_human_outcomes=c("assign_named_species","assign_unspecified_species","exclude_record")
  ))
}

# W06 unresolved geography and terminal model failures.
req6<-c("geography_status","luna_iso3c","luna_country_names","luna_evidence","geography_reason",
        "llm_failed","llm_error","deterministic_primary_countries","deterministic_primary_iso3c")
if(length(setdiff(req6,names(w06))))stop("W06 layer lacks required geography columns",call.=FALSE)

w06_failures<-w06 |> filter(llm_failed %in% TRUE)
for(i in seq_len(nrow(w06_failures))){
  z<-w06_failures[i,,drop=FALSE]
  add_issue(z$record_id,list(
    source_workflow="06",issue_type="geography_model_failure",
    automated_value=list(
      geography_status=clean_chr(z$geography_status),
      llm_error=clean_chr(z$llm_error),
      deterministic_primary_countries=clean_chr(z$deterministic_primary_countries),
      deterministic_primary_iso3c=clean_chr(z$deterministic_primary_iso3c)
    ),
    allowed_human_outcomes=c("assign_country_set","assign_none")
  ))
}

w06_unresolved_all<-w06 |> filter(geography_status=="UNRESOLVED", !(llm_failed %in% TRUE))
w06_unresolved_auto_none<-w06_unresolved_all |>
  filter(!nzchar(vapply(luna_iso3c,norm_iso_set,character(1))))
w06_unresolved<-w06_unresolved_all |>
  filter(nzchar(vapply(luna_iso3c,norm_iso_set,character(1))))

for(i in seq_len(nrow(w06_unresolved))){
  z<-w06_unresolved[i,,drop=FALSE]
  add_issue(z$record_id,list(
    source_workflow="06",issue_type="geography_unresolved",
    automated_value=list(
      geography_status=clean_chr(z$geography_status),
      luna_iso3c=clean_chr(z$luna_iso3c),
      luna_country_names=clean_chr(z$luna_country_names),
      luna_evidence=clean_chr(z$luna_evidence),
      geography_reason=clean_chr(z$geography_reason)
    ),
    allowed_human_outcomes=c("assign_country_set","assign_none")
  ))
}

# W06 evidence-grounding residual after deterministic revalidation.
resid_ids<-unique(as.character(g_resid$record_id))
resid_ids<-resid_ids[nzchar(resid_ids)]
resid_ids<-setdiff(resid_ids,unique(c(
  as.character(w06_failures$record_id),
  as.character(w06_unresolved_all$record_id)
)))
if(length(setdiff(resid_ids,w06$record_id)))stop("Grounding residual contains ID outside W06",call.=FALSE)

# A grounding-format failure cannot change the substantive geography when
# deterministic and model country sets agree exactly on a resolved record.
# Accept these deterministically rather than sending them to human review.
resid_rows<-w06[match(resid_ids,w06$record_id),,drop=FALSE]
exact_grounding_accept_ids<-as.character(resid_rows$record_id[
  resid_rows$geography_status=="RESOLVED" &
  !(resid_rows$llm_failed %in% TRUE) &
  vapply(resid_rows$deterministic_primary_iso3c,norm_iso_set,character(1)) ==
    vapply(resid_rows$luna_iso3c,norm_iso_set,character(1)) &
  nzchar(vapply(resid_rows$luna_iso3c,norm_iso_set,character(1)))
])
resid_ids<-setdiff(resid_ids,exact_grounding_accept_ids)

# For legacy/current W06 states that predate geography_autovalidated, apply the
# same strict direct-country corroboration used by current W06: every Luna
# country must be explicitly present as a country name, standard abbreviation
# or unambiguous demonym in the title/abstract.
explicit_country_cue_accept_ids<-character()
for(rid in resid_ids){
  z<-w06[match(rid,w06$record_id),,drop=FALSE]
  cc<-context[match(rid,context$record_id),,drop=FALSE]
  if(z$geography_status=="RESOLVED" && !(z$llm_failed %in% TRUE) &&
     strict_country_cues_support_set(z$luna_iso3c,cc$title,cc$abstract,gazetteer)){
    explicit_country_cue_accept_ids<-c(explicit_country_cue_accept_ids,rid)
  }
}
resid_ids<-setdiff(resid_ids,explicit_country_cue_accept_ids)
for(rid in resid_ids){
  z<-w06[match(rid,w06$record_id),,drop=FALSE]
  add_issue(rid,list(
    source_workflow="06",issue_type="geography_evidence_unvalidated",
    automated_value=list(
      geography_status=clean_chr(z$geography_status),
      luna_iso3c=clean_chr(z$luna_iso3c),
      luna_country_names=clean_chr(z$luna_country_names),
      luna_evidence=clean_chr(z$luna_evidence),
      geography_reason=clean_chr(z$geography_reason)
    ),
    allowed_human_outcomes=c("accept_model","override_country_set","assign_none")
  ))
}

# W07 human-review cases.
if(nrow(w07q)&&(!all(c("record_id","workflow08_reason")%in%names(w07q))||anyDuplicated(w07q$record_id)))stop("Invalid W07 human-review layer",call.=FALSE)
score_index<-split(seq_len(nrow(w07s)),as.character(w07s$record_id))
w07_extreme_autoaccepted<-0L
for(i in seq_len(nrow(w07q))){
  q<-w07q[i,,drop=FALSE];rid<-as.character(q$record_id);reason<-as.character(q$workflow08_reason)
  if(reason=="extreme_three_pass_topic_disagreement"){
    # Legacy/current W07 states may contain a human-review route based solely
    # on mean pairwise Jaccard < 0.20. Jaccard is now descriptive QC only:
    # the retained union plus 1/2/3-pass support already represents model
    # uncertainty, so disagreement alone is not a human-adjudication trigger.
    idx<-score_index[[rid]]
    if(is.null(idx)||!length(idx))stop("Topic disagreement lacks pathway scores: ",rid,call.=FALSE)
    w07_extreme_autoaccepted<-w07_extreme_autoaccepted+1L
    next
  }else if(reason=="zero_topic_eligibility_uncertain"){
    add_issue(rid,list(
      source_workflow="07",issue_type="zero_topic_eligibility_uncertain",
      automated_value=list(
        zero_topic=TRUE,
        zero_topic_rescreen_decision=as.character(q$zero_topic_rescreen_decision),
        screening_action=as.character(q$screening_action)
      ),
      allowed_human_outcomes=c("include_uncoded","exclude_record")
    ))
  }else stop("Unexpected W07 review reason: ",reason,call.=FALSE)
}

pending_ids<-context$record_id[lengths(issue_map[context$record_id])>0L]
queue<-lapply(pending_ids,function(rid){
  z<-context[match(rid,context$record_id),,drop=FALSE]
  list(record_id=rid,record_sequence=as.integer(z$record_sequence),title=z$title,abstract=z$abstract,issues=issue_map[[rid]])
})

queue_path<-file.path(out_dir,"workflow08_review_queue_current.jsonl")
con<-file(queue_path,"wt",encoding="UTF-8");on.exit(close(con),add=TRUE)
for(x in queue)writeLines(toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)
close(con);on.exit(NULL,add=FALSE)

issue_rows<-bind_rows(lapply(pending_ids,function(rid)bind_rows(lapply(issue_map[[rid]],function(q)data.frame(
  review_key=paste(rid,q$issue_type,sep="::"),record_id=rid,source_workflow=q$source_workflow,
  issue_type=q$issue_type,issue_state_sha256=q$issue_state_sha256,stringsAsFactors=FALSE
)))))
write_csv(issue_rows,file.path(out_dir,"workflow08_issue_index_current.csv"),na="")
write_csv(w07x,file.path(out_dir,"workflow08_late_automatic_exclusions.csv"),na="")

manifest<-list(
  schema="living-evidence-map-workflow08-review-queue-v2",status="PASS",
  created_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ"),
  input_population=nrow(context),
  w05_species_none=nrow(w05_none),
  w06_unresolved=nrow(w06_unresolved),
  w06_unresolved_no_country_autoassigned_none=nrow(w06_unresolved_auto_none),
  w06_model_failures=nrow(w06_failures),
  w06_grounding_exact_agreement_autoaccepted=length(exact_grounding_accept_ids),
  w06_grounding_explicit_country_cue_autoaccepted=length(explicit_country_cue_accept_ids),
  w06_grounding_residual=length(resid_ids),
  w07_human_review_source=nrow(w07q),
  w07_extreme_disagreement_suppressed_descriptive_only=w07_extreme_autoaccepted,
  w07_human_review=nrow(w07q)-w07_extreme_autoaccepted,
  w07_late_automatic_exclusions=nrow(w07x),
  unique_records_with_review_issues=length(queue),
  total_review_issues=nrow(issue_rows),
  queue_sha256=digest(file=queue_path,algo="sha256",serialize=FALSE),
  issue_index_sha256=digest(file=file.path(out_dir,"workflow08_issue_index_current.csv"),algo="sha256",serialize=FALSE),
  source_sha256=list(
    workflow05=digest(file=w05_path,algo="sha256",serialize=FALSE),
    workflow06=digest(file=w06_path,algo="sha256",serialize=FALSE),
    workflow07_records=digest(file=w07_records_path,algo="sha256",serialize=FALSE),
    workflow07_review=digest(file=w07_review_path,algo="sha256",serialize=FALSE),
    workflow07_scores=digest(file=w07_scores_path,algo="sha256",serialize=FALSE),
    workflow07_late_exclusions=digest(file=w07_late_path,algo="sha256",serialize=FALSE)
  )
)
write_json(manifest,file.path(out_dir,"workflow08_review_queue_manifest.json"),auto_unbox=TRUE,pretty=TRUE,null="null")
writeLines("PASS",file.path(out_dir,"WORKFLOW08_INTAKE_PASS.ok"))
cat(sprintf("PASS: current W08 intake population=%d issues=%d records=%d\n",nrow(context),nrow(issue_rows),length(queue)))
