#!/usr/bin/env Rscript
# Append-only monthly W08b edge reconciliation. Deduplicate provider-specific
# edges after discovery, never discard previous-month citation relationships.
# Usage: merge_monthly_edges.R prior_edges.csv current_edges.csv out_dir
suppressPackageStartupMessages(library(jsonlite))
args<-commandArgs(trailingOnly=TRUE)
if(length(args)!=3L)stop("Usage: merge_monthly_edges.R previous_edges.csv current_edges.csv out_dir")
prev<-args[[1]];next_path<-args[[2]];out<-args[[3]]
fields<-c("seed_record_id","provider","related_provider_id","direction")
read_edges<-function(path) {
 if(!file.exists(path))stop("Missing edge register: ",path)
 x<-read.csv(path,stringsAsFactors=FALSE,na.strings=NULL)
 if(!all(fields%in%names(x)))stop("Incomplete edge register: ",path)
 x<-x[,fields,drop=FALSE]
 if(nrow(x)){
   for(k in fields)x[[k]]<-trimws(x[[k]])
   if(any(!nzchar(as.matrix(x))))stop("Missing edge fields: ",path)
   if(any(!x$provider%in%c("lens","openalex"))||
      any(!x$direction%in%c("backward","forward","both")))stop("Unknown provider/direction: ",path)
 }
 unique(x)
}
prior<-read_edges(prev);new<-read_edges(next_path)
# Canonicalised 'both' records represent both directional edges.
expand_both<-function(x) {
 if(!nrow(x)||!any(x$direction=="both"))return(x)
 both<-x[x$direction=="both",,drop=FALSE]
 both$direction<-"backward"
 forward<-both;forward$direction<-"forward"
 unique(rbind(x[x$direction!="both",,drop=FALSE],both,forward))
}
prior<-expand_both(prior);new<-expand_both(new)
combined<-unique(rbind(prior,new))
combined<-combined[order(combined$seed_record_id,combined$provider,
                         combined$related_provider_id,combined$direction),,drop=FALSE]
new_only<-new[!(paste(new$seed_record_id,new$provider,new$related_provider_id,new$direction,sep="\037")%in%
                   paste(prior$seed_record_id,prior$provider,prior$related_provider_id,prior$direction,sep="\037")),,drop=FALSE]
keys<-unique(combined[,c("provider","related_provider_id"),drop=FALSE])
keys<-keys[order(keys$provider,keys$related_provider_id),,drop=FALSE]
dir.create(out,recursive=TRUE,showWarnings=FALSE)
write.csv(combined,file.path(out,"citation_edges.csv"),row.names=FALSE)
write.csv(new_only,file.path(out,"new_citation_edges.csv"),row.names=FALSE)
write.csv(keys,file.path(out,"provider_candidate_ids.csv"),row.names=FALSE)
if(nrow(combined)){
  pairs<-aggregate(combined$direction,
    by=combined[,c("seed_record_id","provider","related_provider_id"),drop=FALSE],
    FUN=function(v)if(length(unique(v))>1L)"both" else unique(v))
  names(pairs)[4]<-"direction"
} else pairs<-data.frame(seed_record_id=character(),provider=character(),
   related_provider_id=character(),direction=character())
write.csv(pairs,file.path(out,"seed_candidate_direction.csv"),row.names=FALSE)
# Retain observed query-identifier provenance in addition to the deduplicated
# canonical seed/provider/direction edges. Older archives may lack this file;
# never invent a source identifier for such historical relationships.
prov_fields<-c("seed_record_id","provider","queried_seed_identifier",
               "related_provider_id","direction")
read_provenance<-function(path){
 if(!file.exists(path))return(as.data.frame(setNames(
    replicate(length(prov_fields),character(),simplify=FALSE),prov_fields)))
 z<-read.csv(path,stringsAsFactors=FALSE,na.strings=NULL)
 if(!all(prov_fields%in%names(z)))stop("Incomplete query provenance: ",path)
 z<-z[,prov_fields,drop=FALSE]
 if(nrow(z)&&any(!nzchar(as.matrix(z))))stop("Missing query provenance: ",path)
 unique(z)
}
prior_prov<-read_provenance(file.path(dirname(prev),"citation_edge_query_provenance.csv"))
new_prov<-read_provenance(file.path(dirname(next_path),"citation_edge_query_provenance.csv"))
provenance<-unique(rbind(prior_prov,new_prov))
provenance<-provenance[order(provenance$seed_record_id,provenance$provider,
  provenance$queried_seed_identifier,provenance$related_provider_id,
  provenance$direction),,drop=FALSE]
write.csv(provenance,file.path(out,"citation_edge_query_provenance.csv"),row.names=FALSE)

summary<-list(schema="workflow08b-monthly-edge-union-v1",
 prior_direction_edges=nrow(prior),current_direction_edges=nrow(new),
 new_direction_edges=nrow(new_only),cumulative_direction_edges=nrow(combined),
 cumulative_provider_candidate_ids=nrow(keys),
 historical_query_provenance=nrow(prior_prov),
 current_query_provenance=nrow(new_prov),
 cumulative_query_provenance=nrow(provenance),
 no_historical_edges_dropped=all(paste(prior$seed_record_id,prior$provider,prior$related_provider_id,prior$direction,sep="\037")%in%
                               paste(combined$seed_record_id,combined$provider,combined$related_provider_id,combined$direction,sep="\037")),
 candidate_bibliographies_not_downloaded=TRUE)
if(!summary$no_historical_edges_dropped)stop("Historical citation edge loss")
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),file.path(out,"summary.json"))
cat("PASS: preserved ",nrow(prior)," historical edges; ",nrow(new_only),
    " genuinely new edges; ",nrow(keys)," candidate provider IDs\n",sep="")
