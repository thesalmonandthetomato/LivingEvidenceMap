#!/usr/bin/env Rscript
# Isolated W01-Fast append-only pair decision ledger, local output only.
suppressPackageStartupMessages({library(data.table);library(digest);library(jsonlite)})
a<-commandArgs(trailingOnly=TRUE)
arg<-function(k,optional=FALSE){i<-match(k,a);if(is.na(i)){if(optional)return(NULL);stop(paste("Missing",k))};if(i==length(a))stop(paste("Missing value",k));a[[i+1L]]}
historic<-arg("--historical-ledger",TRUE);delta<-arg("--new-decisions")
identity_file<-arg("--manifestations");output<-arg("--output")
historical_identity_file<-arg("--historical-manifestations",TRUE)
if(file.exists(output))stop("Refusing to overwrite an existing ledger",call.=FALSE)
m<-fread(identity_file,na.strings=c("","NA"))
stopifnot(all(c("idx","source","source_record_id")%in%names(m)),
 identical(as.integer(m$idx),seq_len(nrow(m))),
 !anyNA(m$source),!anyNA(m$source_record_id),
 !anyDuplicated(paste(m$source,m$source_record_id,sep="::")))
cols<-c("record_i","record_j","rescored_classification")
fresh<-fread(delta,na.strings=c("","NA"))
if(!all(cols%in%names(fresh)))stop("Missing mandatory decision fields")
if(!is.null(historic)){
 if(is.null(historical_identity_file))stop("Historical ledger requires historical manifestation identity snapshot",call.=FALSE)
 hm<-fread(historical_identity_file,na.strings=c("","NA"))
 if(!all(c("idx","source","source_record_id")%in%names(hm)) ||
    nrow(hm)>nrow(m) ||
    !identical(as.integer(hm$idx),seq_len(nrow(hm))) ||
    !identical(as.character(hm$source),as.character(m$source[seq_len(nrow(hm))])) ||
    !identical(as.character(hm$source_record_id),as.character(m$source_record_id[seq_len(nrow(hm))])))
   stop("Historical manifestation identity/order mismatch",call.=FALSE)
}
if(is.null(historic)){
 old<-fresh[0]
}else{
 old<-fread(historic,na.strings=c("","NA"))
 if(!all(cols%in%names(old)))stop("Historical ledger schema mismatch")
}
for(d in list(old,fresh)){
 if(anyNA(d$record_i)||anyNA(d$record_j)||
    any(d$record_i<1L|d$record_j>nrow(m)|d$record_i>=d$record_j))
    stop("Invalid manifestation pair identity",call.=FALSE)
 if(anyNA(d$rescored_classification)|any(!nzchar(as.character(d$rescored_classification))))
    stop("Blank decision",call.=FALSE)
 if(anyDuplicated(d[,.(record_i,record_j)]))
    stop("Duplicate pair within decision ledger",call.=FALSE)
}
if(nrow(old)&&nrow(fresh)){
 keys<-function(x)paste(x$record_i,x$record_j,sep=":")
 if(any(keys(fresh)%in%keys(old)))stop("Attempt to replace historical pair decision",call.=FALSE)
}
# Preserve all historical rows and columns byte-for-byte after parsing.
if(!identical(names(old),names(fresh)))stop("Decision ledger columns differ",call.=FALSE)
merged<-rbindlist(list(old,fresh),use.names=TRUE)
dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
fwrite(merged,output)
writeLines(toJSON(list(schema="experimental-w01-fast-decision-ledger-v1",
 historical_decisions=nrow(old),appended_decisions=nrow(fresh),
 total_decisions=nrow(merged),manifestations=nrow(m),
 source_sha256=digest(file=identity_file,algo="sha256"),
 historical_ledger_sha256=if(is.null(historic))NULL else digest(file=historic,algo="sha256"),
 historical_identity_sha256=if(is.null(historic))NULL else digest(file=historical_identity_file,algo="sha256"),
 production_publication_allowed=FALSE),auto_unbox=TRUE,pretty=TRUE),
 paste0(output,".manifest.json"))
cat(sprintf("PASS: immutable ledger %d prior + %d new decisions\n",nrow(old),nrow(fresh)))
