#!/usr/bin/env Rscript
# W08b: deterministic, offline citation-edge merge. Input JSONL records are
# {seed_record_id, provider, backward_ids:[...], forward_ids:[...]}.
# Does not retrieve citations or modify W01.
suppressPackageStartupMessages(library(jsonlite))
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=2L)stop("Usage: merge_edges.R <edges_input.jsonl> <output_dir>")
input<-a[[1L]];out<-a[[2L]]
if(!file.exists(input))stop("Input missing")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
scalar<-function(x){v<-unlist(x,use.names=FALSE);if(!length(v))return("");trimws(as.character(v[[1L]]))}
valid_ids<-function(x){z<-trimws(as.character(unlist(x,use.names=FALSE)));unique(z[!is.na(z)&nzchar(z)])}
con<-file(input,"rt");on.exit(close(con))
rows<-list(); n<-0L
repeat{
 ls<-readLines(con,n=500L,warn=FALSE);if(!length(ls))break
 for(line in ls){
  if(!nzchar(trimws(line)))next
  z<-fromJSON(line,simplifyVector=FALSE)
  seed<-scalar(z$seed_record_id);provider<-scalar(z$provider)
  if(!nzchar(seed)||!(provider%in%c("lens","openalex")))stop("Invalid seed/provider")
  for(direction in c("backward","forward")){
   ids<-valid_ids(z[[paste0(direction,"_ids")]])
   for(id in ids){n<-n+1L;rows[[n]]<-data.frame(seed_record_id=seed,provider=provider,
      related_provider_id=id,direction=direction,stringsAsFactors=FALSE)}
  }
 }
}
if(!length(rows)){
  # A fully checked seed with zero citations is valid, not an error.
  write.csv(data.frame(seed_record_id=character(),provider=character(),
    related_provider_id=character(),direction=character()),
    file.path(out,"citation_edges.csv"),row.names=FALSE)
  write.csv(data.frame(provider=character(),related_provider_id=character()),
    file.path(out,"provider_candidate_ids.csv"),row.names=FALSE)
  write.csv(data.frame(seed_record_id=character(),provider=character(),
    related_provider_id=character(),direction=character()),
    file.path(out,"seed_candidate_direction.csv"),row.names=FALSE)
  writeLines(toJSON(list(schema="workflow08b-edges-v1",raw_edges=0L,
    distinct_direction_edges=0L,distinct_seed_candidate_pairs=0L,
    distinct_provider_candidate_ids=0L,pairs_both_directions=0L,
    candidate_bibliography_downloaded=FALSE),auto_unbox=TRUE,pretty=TRUE),
    file.path(out,"summary.json"))
  cat("PASS: zero citation edges retained as a valid empty register\\n")
  quit(save="no",status=0L)
}
d<-unique(do.call(rbind,rows))
d<-d[order(d$seed_record_id,d$provider,d$related_provider_id,d$direction),,drop=FALSE]
write.csv(d,file.path(out,"citation_edges.csv"),row.names=FALSE)
# A provider-specific related identifier is not automatically an identity
# across providers; keep separate until DOI/identifier reconciliation.
keys<-unique(d[,c("provider","related_provider_id")])
keys<-keys[order(keys$provider,keys$related_provider_id),,drop=FALSE]
write.csv(keys,file.path(out,"provider_candidate_ids.csv"),row.names=FALSE)
pairs<-unique(d[,c("seed_record_id","provider","related_provider_id")])
direction_by_pair<-aggregate(d$direction,
  by=d[,c("seed_record_id","provider","related_provider_id")],
  FUN=function(x)if(length(unique(x))>1L)"both" else unique(x))
names(direction_by_pair)[4]<-"direction"
direction_by_pair<-direction_by_pair[order(direction_by_pair$seed_record_id,direction_by_pair$provider,direction_by_pair$related_provider_id),]
write.csv(direction_by_pair,file.path(out,"seed_candidate_direction.csv"),row.names=FALSE)
summary<-list(schema="workflow08b-edges-v1",raw_edges=n,distinct_direction_edges=nrow(d),
  distinct_seed_candidate_pairs=nrow(pairs),distinct_provider_candidate_ids=nrow(keys),
  pairs_both_directions=sum(direction_by_pair$direction=="both"),
  candidate_bibliography_downloaded=FALSE)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),file.path(out,"summary.json"))
cat("PASS: offline citation ID deduplication and direction provenance\n")
