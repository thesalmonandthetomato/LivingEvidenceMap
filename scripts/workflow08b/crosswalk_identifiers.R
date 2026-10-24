#!/usr/bin/env Rscript
# W08b: join checksum-verified W01 source identities to included W08 IDs.
# No provider API requests and no mutation of canonical records.
suppressPackageStartupMessages(library(jsonlite))
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=3L) stop("Usage: crosswalk_identifiers.R <w08.jsonl> <w01.jsonl> <output-dir>")
w08<-a[[1]];w01<-a[[2]];out<-a[[3]]
if(!file.exists(w08)||!file.exists(w01)) stop("Missing canonical input")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
scalar<-function(x){z<-unlist(x,use.names=FALSE);if(!length(z))return("");v<-trimws(as.character(z[[1]]));if(is.na(v))"" else v}
normdoi<-function(x){v<-tolower(scalar(x));v<-sub("^https?://(dx\\.)?doi[.]org/","",v);sub("^doi:[[:space:]]*","",v)}
normoa<-function(x){v<-toupper(sub("^https?://openalex[.]org/","",scalar(x),ignore.case=TRUE));if(grepl("^W[0-9]+$",v))v else ""}
distinct<-function(z){z<-unique(z[nzchar(z)&!is.na(z)]);if(length(z)==1L)z else if(!length(z))"" else paste(z,collapse="|")}
read_w08<-function(path){
 ids<-character();doi<-character();con<-file(path,"rt");on.exit(close(con))
 repeat{lines<-readLines(con,n=1000L,warn=FALSE);if(!length(lines))break
   for(line in lines){if(!nzchar(trimws(line)))next
     rec<-fromJSON(line,simplifyVector=FALSE)
     id<-scalar(rec$identity$record_id);if(!nzchar(id))stop("W08 ID missing")
     ids<-c(ids,id);doi<-c(doi,normdoi(rec$canonical$doi))
   }}
 if(anyDuplicated(ids))stop("Duplicate W08 record IDs")
 setNames(doi,ids)
}
seeds<-read_w08(w08);found<-new.env(hash=TRUE,parent=emptyenv());seen<-new.env(hash=TRUE,parent=emptyenv())
con<-file(w01,"rt");on.exit(close(con),add=TRUE)
repeat {lines<-readLines(con,n=500L,warn=FALSE);if(!length(lines))break
  for(line in lines){if(!nzchar(trimws(line)))next
    rec<-fromJSON(line,simplifyVector=FALSE);id<-scalar(rec$identity$record_id)
    if(!nzchar(id))stop("Missing W01 identity")
    if(exists(id,envir=seen,inherits=FALSE))stop("Duplicate W01 canonical ID: ",id)
    assign(id,TRUE,envir=seen)
    if(!(id %in% names(seeds)))next
    mans<-rec$manifestations
    if(is.null(mans)||!length(mans))stop("W01 included record lacks manifestations: ",id)
    lens<-character();oa<-character();dois<-c(seeds[[id]])
    for(m in mans){
      src<-scalar(m$source);mid<-m$manifestation_metadata
      if(src=="lens")lens<-c(lens,scalar(mid$source_identity$lens_id),scalar(m$source_record_id))
      if(src=="openalex")oa<-c(oa,normoa(mid$source_identity$openalex_id),normoa(m$source_record_id))
      oa<-c(oa,normoa(mid$identifiers$openalex_id));dois<-c(dois,normdoi(m$doi))
    }
    lens<-distinct(lens);oa<-distinct(oa);doi<-distinct(dois)
    conflict<-any(grepl("|",c(lens,oa,doi),fixed=TRUE))
    route<-if(conflict)"identity_conflict" else if(nzchar(lens))"lens" else if(nzchar(oa))"openalex" else if(nzchar(doi))"lens_doi_lookup" else "unresolved"
    assign(id,list(record_id=id,lens_id=lens,openalex_id=oa,doi=doi,preferred_route=route,
                   identifier_conflict=conflict,manifestation_count=length(mans)),envir=found)
  }}
missing<-setdiff(names(seeds),ls(found,all.names=TRUE))
if(length(missing))stop(length(missing)," W08 included IDs absent from W01 canonical; first ",missing[[1]])
rows<-lapply(names(seeds),function(id)as.data.frame(get(id,envir=found,inherits=FALSE),stringsAsFactors=FALSE))
df<-do.call(rbind,rows)
write.csv(df,file.path(out,"seed_identifier_crosswalk.csv"),row.names=FALSE,quote=TRUE)
routes<-as.list(table(factor(df$preferred_route,levels=c("lens","openalex","lens_doi_lookup","unresolved","identity_conflict"))))
names(routes)<-c("lens","openalex","lens_doi_lookup","unresolved","identity_conflict")
summary<-list(schema="workflow08b-w01-w08-crosswalk-v1",w08_records=length(seeds),w01_matches=nrow(df),
              routes=routes,has_lens=sum(nzchar(df$lens_id)),has_openalex=sum(nzchar(df$openalex_id)),
              has_doi=sum(nzchar(df$doi)),identifier_conflicts=sum(df$identifier_conflict))
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),file.path(out,"summary.json"))
cat("PASS: matched",nrow(df),"included W08 IDs to W01 manifestations\n")
