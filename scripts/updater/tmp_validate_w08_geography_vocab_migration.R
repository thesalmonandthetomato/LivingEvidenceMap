#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(digest)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop("Missing ",flag,call.=FALSE);args[[i+1L]]}
queue_path<-arg("--queue","")
reused_path<-arg("--reused","")
out_dir<-arg("--output-dir","outputs/validation")
dir.create(out_dir,recursive=TRUE,showWarnings=FALSE)

`%||%`<-function(x,y)if(is.null(x)||length(x)==0L)y else x
clean<-function(x){if(is.null(x)||!length(x))return("");z<-as.character(x[[1L]]);if(is.na(z))"" else z}
canon_hash<-function(x)digest(toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA,pretty=FALSE),algo="sha256",serialize=FALSE)
read_jsonl<-function(path){if(!nzchar(path)||!file.exists(path))return(list());x<-readLines(path,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))];lapply(x,fromJSON,simplifyVector=FALSE)}
write_jsonl<-function(rows,path){con<-file(path,"wt",encoding="UTF-8");on.exit(close(con),add=TRUE);for(z in rows)writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)}

files<-c(
  "scripts/reporting/workflow07_apply_retention_and_review_rules.R",
  "scripts/updater/workflow_08_build_review_queue_dynamic.R",
  "scripts/updater/workflow_08_reuse_decisions.R",
  "scripts/updater/workflow_08_export_shiny_decisions.R",
  "scripts/updater/workflow_08_finalize_canonical_dynamic.R"
)
invisible(lapply(files,parse))

w07<-readLines(files[[1]],warn=FALSE,encoding="UTF-8")
builder<-readLines(files[[2]],warn=FALSE,encoding="UTF-8")
reuse<-readLines(files[[3]],warn=FALSE,encoding="UTF-8")
exporter<-readLines(files[[4]],warn=FALSE,encoding="UTF-8")
finalizer<-readLines(files[[5]],warn=FALSE,encoding="UTF-8")

need<-list(
  w07=c('reason <- if(pathology) "topic_coding_review" else ""',
        'extreme_disagreement_metric_role="descriptive_qc_only_not_human_review_gate"'),
  builder=c('reason%in%c("topic_coding_review","ontology_pathology")',
            'issue_type="topic_coding_review"',
            'allowed_human_outcomes=c("accept_retained_topics","replace_topic_set","no_code","exclude_record")',
            'allowed_human_outcomes=c("assign_topic_set","include_uncoded","exclude_record")'),
  reuse=c('compatible_zero_topic_migration<-function',
          'basis="compatible_zero_topic_vocabulary_migration"'),
  exporter=c('validate_issue_decision <- function',
             'typ %in% c("topic_coding_review","ontology_pathology","topic_extreme_disagreement")',
             'if(dec=="assign_topic_set")'),
  finalizer=c('by_type("topic_coding_review")',
              'by_type("topic_extreme_disagreement")',
              'by_type("ontology_pathology")',
              'identical(clean(zd$decision),"assign_topic_set")',
              'validate_topic_decision<-function')
)
sources<-list(w07=w07,builder=builder,reuse=reuse,exporter=exporter,finalizer=finalizer)
for(nm in names(need)){
  miss<-need[[nm]][!vapply(need[[nm]],function(z)any(grepl(z,sources[[nm]],fixed=TRUE)),logical(1))]
  if(length(miss))stop("Missing ",nm," contract: ",paste(miss,collapse=" | "),call.=FALSE)
}

# Jaccard disagreement must not be emitted as a production issue.
if(any(grepl('issue_type="topic_extreme_disagreement"',builder,fixed=TRUE))){
  stop("Builder still emits topic_extreme_disagreement",call.=FALSE)
}

zero_issues<-0L
zero_prior_decisions<-0L
zero_migrations<-0L
if(nzchar(queue_path)){
  queue<-read_jsonl(queue_path)
  prior<-read_jsonl(reused_path)

  # Convert only the current zero-topic vocabulary to the new contract,
  # preserving all substantive issue state.
  for(i in seq_along(queue)){
    rec<-queue[[i]]
    rid<-clean(rec$record_id)
    for(j in seq_along(rec$issues%||%list())){
      issue<-rec$issues[[j]]
      typ<-clean(issue$issue_type)
      if(typ=="topic_extreme_disagreement")stop("Current queue unexpectedly contains a Jaccard-only topic issue",call.=FALSE)
      if(typ=="zero_topic_eligibility_uncertain"){
        zero_issues<-zero_issues+1L
        old<-as.character(issue$allowed_human_outcomes)
        if(!identical(old,c("include_uncoded","exclude_record")))stop("Unexpected old zero-topic vocabulary",call.=FALSE)
        issue$allowed_human_outcomes<-c("assign_topic_set","include_uncoded","exclude_record")
        state<-list(
          review_key=paste(rid,typ,sep="::"),record_id=rid,issue_type=typ,
          source_workflow=clean(issue$source_workflow),title=clean(rec$title),abstract=clean(rec$abstract),
          automated_value=issue$automated_value,allowed_human_outcomes=issue$allowed_human_outcomes
        )
        issue$issue_state_sha256<-canon_hash(state)
        rec$issues[[j]]<-issue
      }
    }
    queue[[i]]<-rec
  }

  qnew<-file.path(out_dir,"queue_new_topic_contract.jsonl")
  pold<-file.path(out_dir,"prior_reused.jsonl")
  write_jsonl(queue,qnew);write_jsonl(prior,pold)

  zero_prior_decisions<-sum(vapply(prior,function(z)clean(z$issue_type)=="zero_topic_eligibility_uncertain",logical(1)))
  prod<-file.path(out_dir,"production_reuse");dir.create(prod,recursive=TRUE,showWarnings=FALSE)
  rc<-system2("Rscript",c(
    "scripts/updater/workflow_08_reuse_decisions.R",
    "--queue",qnew,"--prior-ledger",pold,"--output-dir",prod
  ))
  if(rc!=0L)stop("Production reuse validation failed",call.=FALSE)
  m<-fromJSON(file.path(prod,"workflow08_reuse_manifest.json"),simplifyVector=FALSE)
  zero_migrations<-as.integer(m$compatible_zero_topic_vocabulary_migrations)
  if(zero_migrations!=zero_prior_decisions)stop(
    "Not all reusable zero-topic decisions survived vocabulary migration: expected ",
    zero_prior_decisions," got ",zero_migrations,call.=FALSE
  )
}

summary<-list(
  schema="living-evidence-map-w07-w08-topic-review-contract-validation-v1",
  status="PASS",
  model_calls=0L,
  production_existing_topics_issue_type="topic_coding_review",
  production_existing_topics_outcomes=c("accept_retained_topics","replace_topic_set","no_code","exclude_record"),
  zero_topic_issue_type="zero_topic_eligibility_uncertain",
  zero_topic_outcomes=c("assign_topic_set","include_uncoded","exclude_record"),
  jaccard_issue_emitted=FALSE,
  legacy_topic_issue_finalizer_compatibility=c("ontology_pathology","topic_extreme_disagreement"),
  zero_topic_issues_in_reference_queue=zero_issues,
  reusable_zero_topic_decisions_in_reference_state=zero_prior_decisions,
  compatible_zero_topic_migrations=zero_migrations,
  return_payload_validation=TRUE,
  finalizer_payload_validation=TRUE,
  validated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
write_json(summary,file.path(out_dir,"summary.json"),auto_unbox=TRUE,pretty=TRUE)
cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),"\n")
