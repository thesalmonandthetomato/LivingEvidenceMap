#!/usr/bin/env Rscript
# Strict scientific comparison; requires independent Fast output with immutable identities.
suppressPackageStartupMessages({library(data.table);library(jsonlite)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(k){i<-match(k,args);if(is.na(i)||i==length(args))stop(paste("Missing",k));args[[i+1L]]}
reference<-arg("--reference");fast<-arg("--fast");out<-arg("--output-dir")
if(file.exists(out)||dir.exists(out))stop("Refusing overwrite")
identity_cols<-c("source_i","source_record_id_i","source_j","source_record_id_j")
checks<-c("rescored_classification","rescored_rule","review_route")
key<-function(s,id)paste0(nchar(s,type="bytes"),":",s,nchar(id,type="bytes"),":",id)
load<-function(path){
 x<-fread(path,colClasses="character")
 if(!all(c(identity_cols,checks)%in%names(x)))stop("Missing stable identities or decision fields")
 if(any(c("record_i","record_j","idx","row_index")%in%names(x)))stop("Positional decision fields forbidden")
 if(anyNA(x[,..identity_cols])||any(!nzchar(unlist(x[,..identity_cols],use.names=FALSE))))
  stop("Missing source identities")
 left<-key(x$source_i,x$source_record_id_i);right<-key(x$source_j,x$source_record_id_j)
 if(any(left==right))stop("Self-pairs")
 lo<-pmin(left,right);hi<-pmax(left,right)
 x[,stable_pair:=paste0(nchar(lo,type="bytes"),":",lo,nchar(hi,type="bytes"),":",hi)]
 if(anyDuplicated(x$stable_pair))stop("Duplicate pair")
 x[,c("stable_pair",checks),with=FALSE]
}
a<-load(reference);b<-load(fast)
missing<-fsetdiff(a[,.(stable_pair)],b[,.(stable_pair)])
extra<-fsetdiff(b[,.(stable_pair)],a[,.(stable_pair)])
both<-merge(a,b,by="stable_pair",suffixes=c("_ref","_fast"))
changed<-both[Reduce(`|`,lapply(checks,function(col){
 x<-get(paste0(col,"_ref"));y<-get(paste0(col,"_fast"))
 !((is.na(x)&is.na(y))|(!is.na(x)&!is.na(y)&x==y))
}))]
dir.create(out,recursive=TRUE)
fwrite(missing,file.path(out,"missing.csv"))
fwrite(extra,file.path(out,"extra.csv"))
fwrite(changed,file.path(out,"classification_differences.csv"))
passed<-!nrow(missing)&&!nrow(extra)&&!nrow(changed)
write_json(list(schema="w01-fast-independent-decision-parity-v1",reference_pairs=nrow(a),
 fast_pairs=nrow(b),missing=nrow(missing),extra=nrow(extra),
 differences=nrow(changed),independent_parity_passed=passed,
 production_publication_allowed=FALSE),file.path(out,"report.json"),auto_unbox=TRUE,pretty=TRUE)
if(!passed)stop("Independent decision parity failed")
cat(sprintf("PASS: %d immutable-identity decision classifications and routes identical\n",nrow(a)))
