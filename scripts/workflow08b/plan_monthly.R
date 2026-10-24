#!/usr/bin/env Rscript
# W08b monthly seed plan. Offline, deterministic, no network or W01 mutation.
# Usage: plan_monthly.R crosswalk.csv previous/lens_seed_status.jsonl update_id output_dir
suppressPackageStartupMessages(library(jsonlite))
`%||%`<-function(x,y)if(is.null(x))y else x
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=4L)stop("Usage: plan_monthly.R crosswalk.csv previous_status.jsonl update_id output_dir")
input<-a[[1]];history<-a[[2]];update<-a[[3]];out<-a[[4]]
if(!nzchar(update)||!grepl("^[A-Za-z0-9._-]+$",update))stop("Invalid update_id")
d<-read.csv(input,stringsAsFactors=FALSE,na.strings=NULL)
required<-c("record_id","lens_id","openalex_id","doi","preferred_route","identifier_conflict")
if(!all(required%in%names(d))||anyDuplicated(d$record_id))stop("Invalid W08b crosswalk")
prior<-list()
if(file.exists(history)){
  for(line in readLines(history,warn=FALSE)){
    if(!nzchar(trimws(line)))next
    rec<-fromJSON(line,simplifyVector=FALSE)
    id<-as.character(rec$record_id)
    if(!nzchar(id))stop("Invalid historical seed entry")
    prior[[id]]<-rec
  }
}
routes<-c("lens","lens_doi_lookup","openalex","identity_conflict","unresolved")
if(any(!d$preferred_route%in%routes))stop("Unknown provider route")
if(any(d$identifier_conflict & d$preferred_route!="identity_conflict"))stop("Conflicting seed routed to API")
d<-d[order(d$record_id),,drop=FALSE]
plan<-lapply(seq_len(nrow(d)),function(i){
  z<-d[i,,drop=FALSE];id<-z$record_id[[1]]
  old<-prior[[id]]
  new<-is.null(old)
  old_status<-if(new)"never_checked" else as.character(old$status %||% "unknown")
  # Every eligible seed needs a fresh forward lookup, including old papers
  # retrospectively indexed by the provider. The backward direction needs a
  # count refresh, but not redownloading if that count has not increased.
  route<-z$preferred_route[[1]]
  can_lens<-route=="lens" && nzchar(z$lens_id[[1]]) && !grepl("|",z$lens_id[[1]],fixed=TRUE)
  can_doi<-route=="lens_doi_lookup" && nzchar(z$doi[[1]]) && !grepl("|",z$doi[[1]],fixed=TRUE)
  can_openalex<-route=="openalex" && nzchar(z$openalex_id[[1]]) && !grepl("|",z$openalex_id[[1]],fixed=TRUE)
  actionable<-can_lens || can_doi || can_openalex
  data.frame(record_id=id,update_id=update,preferred_route=route,
    lens_id=z$lens_id[[1]],openalex_id=z$openalex_id[[1]],doi=z$doi[[1]],
    previous_status=old_status,new_seed=new,
    provider_check_required=actionable,
    forward_refresh_required=actionable,
    backward_count_refresh_required=actionable,
    backward_retrieval_policy=if(new || old_status!="complete")"retry_or_initial" else "if_reference_count_increases",
    provider_fallback=if(can_lens||can_doi) "openalex_only_if_lens_unresolved_and_openalex_id_known" else if(can_openalex) "openalex_only" else "none",
    stringsAsFactors=FALSE)
})
dir.create(out,recursive=TRUE,showWarnings=FALSE)
df<-do.call(rbind,plan)
write.csv(df,file.path(out,"monthly_seed_plan.csv"),row.names=FALSE,quote=TRUE)
summary<-list(schema="workflow08b-monthly-seed-plan-v1",update_id=update,
  seeds=nrow(df),new_seeds=sum(df$new_seed),previously_complete=sum(df$previous_status=="complete"),
  lens_id_queries=sum(df$preferred_route=="lens" & df$provider_check_required),
  lens_doi_queries=sum(df$preferred_route=="lens_doi_lookup" & df$provider_check_required),
  openalex_id_queries=sum(df$preferred_route=="openalex" & df$provider_check_required),
  identity_conflicts=sum(df$preferred_route=="identity_conflict"),
  unresolved=sum(!df$provider_check_required),
  forward_refresh_required=sum(df$forward_refresh_required),
  backward_reference_count_refresh_required=sum(df$backward_count_refresh_required),
  automatic_downloads_authorised=FALSE)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),file.path(out,"summary.json"))
cat("PASS: planned ",nrow(df)," W08b seeds for update ",update,"; no provider queries authorised\n",sep="")
