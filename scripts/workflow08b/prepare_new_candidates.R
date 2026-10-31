#!/usr/bin/env Rscript
# Partition genuinely new citation IDs into provider-side search candidates,
# excluding already-indexed W01 native provider IDs without losing provenance.
# Usage: prepare_new_candidates.R delta_ids.csv delta_edges.csv w01_unmatched.csv out_dir
suppressPackageStartupMessages(library(jsonlite))
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=4L)stop("Usage: prepare_new_candidates.R new_ids.csv new_edges.csv not_in_w01.csv output_dir")
read<-function(path,cols){
 if(!file.exists(path))stop("Missing new-candidate input: ",path)
 z<-read.csv(path,stringsAsFactors=FALSE,na.strings=NULL)
 if(!all(cols%in%names(z)))stop("Wrong columns in ",path)
 if(nrow(z)&&anyNA(z[,cols,drop=FALSE]))stop("NA in ",path)
 z
}
keycols<-c("provider","related_provider_id")
edgecols<-c("seed_record_id","provider","related_provider_id","direction")
all_ids<-read(a[[1]],keycols)
edges<-read(a[[2]],edgecols)
unmatched<-read(a[[3]],keycols)
if(anyDuplicated(all_ids[,keycols])||anyDuplicated(unmatched[,keycols]))
 stop("Duplicate candidate provider IDs")
if(any(!all_ids$provider%in%c("lens","openalex"))||
 any(!unmatched$provider%in%c("lens","openalex")))stop("Invalid candidate provider")
key<-function(x)paste(x$provider,x$related_provider_id,sep="\037")
if(any(!key(unmatched)%in%key(all_ids)))stop("Unmatched W01 precheck added unknown IDs")
if(any(!key(edges)%in%key(all_ids)))stop("Citation edges contain provider IDs outside the novel candidate set")
if(any(!key(all_ids)%in%key(edges)))stop("Novel provider ID has no citation-edge provenance")
selected<-all_ids[key(all_ids)%in%key(unmatched),keycols,drop=FALSE]
selected_edges<-edges[key(edges)%in%key(selected),edgecols,drop=FALSE]
dir.create(a[[4]],recursive=TRUE,showWarnings=FALSE)
for(provider in c("lens","openalex")){
 ids<-selected[selected$provider==provider,keycols,drop=FALSE]
 e<-selected_edges[selected_edges$provider==provider,edgecols,drop=FALSE]
 ids<-ids[order(ids$related_provider_id),,drop=FALSE]
 e<-e[order(e$seed_record_id,e$related_provider_id,e$direction),,drop=FALSE]
 write.csv(ids,file.path(a[[4]],paste0(provider,"_new_candidate_ids.csv")),row.names=FALSE)
 write.csv(e,file.path(a[[4]],paste0(provider,"_new_citation_edges.csv")),row.names=FALSE)
}
summary<-list(schema="workflow08b-new-candidate-provider-handoff-v1",
 new_provider_candidate_ids=nrow(all_ids),
 already_present_in_w01=nrow(all_ids)-nrow(selected),
 require_provider_not_filter=nrow(selected),
 lens_candidates=sum(selected$provider=="lens"),
 openalex_candidates=sum(selected$provider=="openalex"),
 preserved_candidate_direction_edges=nrow(selected_edges),
 original_search_strategy_exclusion_not_yet_applied=TRUE,
 bibliography_retrieval_performed=FALSE,w01_handoff_authorised=FALSE)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),file.path(a[[4]],"summary.json"))
cat("PASS: novel provider IDs=",nrow(all_ids),
    "; require provider-side NOT=",nrow(selected),
    "; W01 existing=",summary$already_present_in_w01,"\n",sep="")
