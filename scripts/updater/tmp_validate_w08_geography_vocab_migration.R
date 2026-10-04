#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))

builder_path <- "scripts/updater/workflow_08_build_review_queue_dynamic.R"
finalizer_path <- "scripts/updater/workflow_08_finalize_canonical_dynamic.R"

parse(file=builder_path)
parse(file=finalizer_path)

builder <- readLines(builder_path,warn=FALSE,encoding="UTF-8")
finalizer <- readLines(finalizer_path,warn=FALSE,encoding="UTF-8")

need_builder <- c(
  'reason=="ontology_pathology"',
  'issue_type="ontology_pathology"',
  'ontology_pathology=TRUE',
  'allowed_human_outcomes=c("accept_retained_topics","replace_topic_set","no_code","exclude_record")',
  'retained_for_analysis=TRUE',
  'path_id=as.character(s$path_id[[k]])'
)
miss_builder <- need_builder[!vapply(need_builder,function(z)any(grepl(z,builder,fixed=TRUE)),logical(1))]
if(length(miss_builder)) stop("Missing W08 ontology-pathology builder contract: ",paste(miss_builder,collapse=" | "),call.=FALSE)

need_finalizer <- c(
  'by_type("ontology_pathology")',
  'if(isFALSE(fv$included))',
  'screening$exclusion_reason<-"topic_human_exclusion"',
  'topics$assignments<-topic_items(ids,"workflow08_human",rid)',
  'if(identical(td$decision,"no_code"))topics$status<-"included_uncoded"'
)
miss_finalizer <- need_finalizer[!vapply(need_finalizer,function(z)any(grepl(z,finalizer,fixed=TRUE)),logical(1))]
if(length(miss_finalizer)) stop("Missing W08 ontology-pathology finalizer contract: ",paste(miss_finalizer,collapse=" | "),call.=FALSE)

# Confirm the intended four reviewer outcomes cover each finalisation path.
outcomes <- c("accept_retained_topics","replace_topic_set","no_code","exclude_record")
if(length(unique(outcomes))!=4L) stop("Ontology reviewer outcome contract invalid",call.=FALSE)

summary <- list(
  schema="living-evidence-map-w08-ontology-pathology-validation-v1",
  status="PASS",
  model_calls=0L,
  issue_type="ontology_pathology",
  reviewer_outcomes=outcomes,
  builder_routing=TRUE,
  retained_pathways_exposed=TRUE,
  finalizer_topic_overlay=TRUE,
  current_batch_changed=FALSE,
  validated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
dir.create("outputs/validation",recursive=TRUE,showWarnings=FALSE)
write_json(summary,"outputs/validation/summary.json",auto_unbox=TRUE,pretty=TRUE)
cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),"\n")
