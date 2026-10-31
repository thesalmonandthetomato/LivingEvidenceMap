#!/usr/bin/env Rscript
# Query-level W08b monthly planning. Completion/retries use distinct provider
# identifiers, never canonical seed IDs. Read-only, no provider calls.
suppressPackageStartupMessages(library(jsonlite))
`%||%`<-function(x,y)if(is.null(x))y else x
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=4L)stop("Usage: plan_identifier_checks.R expanded_queries.csv historical_checkpoint_dir update_month output_dir")
query_path<-a[[1]];state<-a[[2]];month<-a[[3]];out<-a[[4]]
if(!grepl("^[0-9]{4}-(0[1-9]|1[0-2])$",month))stop("Invalid update month")
q<-read.csv(query_path,stringsAsFactors=FALSE,na.strings=NULL)
needed<-c("seed_record_id","provider","identifier_type","query_identifier")
if(!all(needed%in%names(q))||any(!nzchar(q$seed_record_id))||
  any(!nzchar(q$query_identifier))||anyDuplicated(q[,needed]))stop("Invalid query association manifest")
if(!dir.exists(state))stop("Previous month state is required")
files<-c(lens="lens_seed_status.jsonl",openalex="openalex_seed_status.jsonl",
         doi="lens_doi_resolution.jsonl")
if(!all(file.exists(file.path(state,files[c("lens","openalex")]))))
  stop("Missing historical Lens/OpenAlex checkpoint; fail closed")
history<-list()
keys<-function(provider,typ,value)paste(provider,typ,value,sep="\037")
read_entries<-function(file,provider,typ,field){
 if(!file.exists(file))return(invisible(NULL))
 for(line in readLines(file,warn=FALSE)){
   if(!nzchar(trimws(line)))next
   z<-fromJSON(line,simplifyVector=FALSE)
   v<-as.character(z[[field]] %||% "")
   if(length(v)!=1L||!nzchar(v))next
   history[[keys(provider,typ,v)]]<<-z
 }
}
read_entries(file.path(state,files[["lens"]]),"lens","lens","lens_id")
read_entries(file.path(state,files[["openalex"]]),"openalex","openalex","openalex_id")
read_entries(file.path(state,files[["doi"]]),"lens","doi","doi")
unique_queries<-unique(q[,c("provider","identifier_type","query_identifier"),drop=FALSE])
unique_queries<-unique_queries[order(unique_queries$provider,
                       unique_queries$identifier_type,unique_queries$query_identifier),,drop=FALSE]
if(any(!unique_queries$provider%in%c("lens","openalex"))||
   any(!unique_queries$identifier_type%in%c("lens","openalex","doi"))||
   any(unique_queries$provider=="openalex" & unique_queries$identifier_type!="openalex")||
   any(unique_queries$provider=="lens" & unique_queries$identifier_type=="openalex"))
   stop("Provider/type mismatch")
row<-lapply(seq_len(nrow(unique_queries)),function(i){
 z<-unique_queries[i,,drop=FALSE]
 key<-keys(z$provider,z$identifier_type,z$query_identifier)
 prior<-history[[key]]
 status<-if(is.null(prior))"never_checked" else as.character(prior$status %||% "unknown")
 old_month<-if(is.null(prior))"" else as.character(prior$update_id %||% "")
 completed<-identical(old_month,month) &&
   (if(z$identifier_type=="doi")status%in%c("complete","resolved","not_found")
    else status%in%c("complete","not_found"))
 # Prior month complete seeds refresh forward citation lists every month.
 previous_count<-if(is.null(prior))NA_integer_ else
   suppressWarnings(as.integer(prior$reference_count %||% NA_integer_))
 data.frame(provider=z$provider,identifier_type=z$identifier_type,
   query_identifier=z$query_identifier,update_id=month,
   prior_status=status,prior_update_id=old_month,
   prior_reference_count=previous_count,
   check_required=!completed,
   forward_refresh_required=!completed && z$identifier_type!="doi",
   backward_count_refresh_required=!completed && z$identifier_type!="doi",
   backward_retrieval_policy=if(completed)"already_complete_this_month" else
     if(z$identifier_type=="doi")"resolve_all_lens_matches" else
     if(status=="complete"&&!is.na(previous_count))"if_count_increases" else "initial_or_retry",
   associated_canonical_seeds=sum(q$provider==z$provider &
      q$identifier_type==z$identifier_type & q$query_identifier==z$query_identifier),
   stringsAsFactors=FALSE)
})
df<-if(length(row))do.call(rbind,row)else
  data.frame(provider=character(),identifier_type=character(),
     query_identifier=character(),update_id=character(),
     prior_status=character(),prior_update_id=character(),
     prior_reference_count=integer(),check_required=logical(),
     forward_refresh_required=logical(),backward_count_refresh_required=logical(),
     backward_retrieval_policy=character(),associated_canonical_seeds=integer())
dir.create(out,recursive=TRUE,showWarnings=FALSE)
write.csv(df,file.path(out,"identifier_query_plan.csv"),row.names=FALSE,na="")
summary<-list(schema="workflow08b-identifier-query-plan-v1",
 update_month=month,canonical_seeds=length(unique(q$seed_record_id)),
 seed_identifier_associations=nrow(q),distinct_provider_queries=nrow(df),
 planned_lens_id_queries=sum(df$identifier_type=="lens" & df$check_required),
 planned_openalex_id_queries=sum(df$identifier_type=="openalex" & df$check_required),
 planned_doi_lookups=sum(df$identifier_type=="doi" & df$check_required),
 already_checked_this_month=sum(!df$check_required),
 forward_checks=sum(df$forward_refresh_required),
 backward_count_checks=sum(df$backward_count_refresh_required),
 query_history_key="provider+identifier_type+identifier",
 previous_checkpoint_required=TRUE,provider_calls_performed=FALSE)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),file.path(out,"summary.json"))
cat("PASS: planned ",nrow(df)," distinct provider identifier checks, ",sum(df$check_required),
    " still due; no provider calls\n",sep="")
