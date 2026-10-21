#!/usr/bin/env Rscript
# Read-only ZIP64 STORED member extraction with hard transfer/size caps.
# Never downloads or unpacks the complete 27 GB GitHub Actions archive.
artifact_id <- "12259032049"
repo <- "thesalmonandthetomato/LivingEvidenceMap"
selected <- c("outputs/canonical/records.jsonl")
out <- "october_abstract_archive_index"
if (file.exists(out) || dir.exists(out)) stop("Refuse to overwrite extraction")
token <- Sys.getenv("GH_TOKEN")
if (!nzchar(token)) stop("Missing read-only Actions token")
dir.create(out)
dir.create(file.path(out,"metadata"))
curl <- function(args, result=NULL) {
 code <- suppressWarnings(system(paste("curl",paste(args,collapse=" "),"1>/dev/null"),intern=FALSE,ignore.stderr=FALSE))
 if (!identical(as.integer(code),0L)) stop("Bounded remote request failed: curl exit ",code)
}
endpoint <- paste0("https://api.github.com/repos/",repo,"/actions/artifacts/",artifact_id,"/zip")
redirect <- tempfile()
curl(c("--silent","--show-error","--head","--fail","--max-time","30",
 "-H",shQuote(paste("Authorization: Bearer",token)),
 "-H",shQuote("Accept: application/vnd.github+json"),
 "--dump-header",shQuote(redirect),"--output","/dev/null",shQuote(endpoint)))
h<-readLines(redirect,warn=FALSE);unlink(redirect)
loc<-grep("^location: ",h,value=TRUE,ignore.case=TRUE)
if(length(loc)!=1L)stop("Expected one signed storage URL")
signed<-trimws(sub("^[^:]+: ","",loc))
if(!startsWith(signed,"https://productionresult")||
 !grepl(".blob.core.windows.net/",signed,fixed=TRUE))stop("Unexpected storage host")
request<-function(start,end,path,cap){
 if(start<0||end<start||(end-start+1)>cap)stop("Unsafe byte range")
 curl(c("--silent","--show-error","--fail","--max-time","120",
 "-H",shQuote(sprintf("x-ms-range: bytes=%.0f-%.0f",start,end)),
 "--output",shQuote(path),shQuote(signed)))
 if (!file.exists(path)||file.info(path)$size != (end-start+1))
  stop("Storage did not honour exact range")
}
total<-27460488363
tail_path<-tempfile();request(total-65536,total-1,tail_path,65536)
b<-readBin(tail_path,"raw",n=65536);unlink(tail_path)
num<-function(x,p,n){
 if(p<0||p+n>length(x))stop("Truncated ZIP directory")
 sum(as.numeric(x[(p+1):(p+n)])*256^(seq_len(n)-1))
}
sig<-function(x,p,bytes) p>=0&&p+length(bytes)<=length(x)&&
 identical(x[(p+1):(p+length(bytes))],as.raw(bytes))
found<-which(b==as.raw(0x50))
found<-found[vapply(found,function(p)sig(b,p-1,c(0x50,0x4b,0x01,0x02)),logical(1))]
if(!length(found))stop("No ZIP central directory")
entries<-list();p<-min(found)-1
while(sig(b,p,c(0x50,0x4b,0x01,0x02))){
 namelen<-num(b,p+28,2);extralen<-num(b,p+30,2);commentlen<-num(b,p+32,2)
 name<-rawToChar(b[(p+47):(p+46+namelen)])
 compressed<-num(b,p+20,4);uncompressed<-num(b,p+24,4)
 offset<-num(b,p+42,4);method<-num(b,p+10,2)
 q<-p+46+namelen;stopat<-q+extralen
 while(q<stopat){
  type<-num(b,q,2);len<-num(b,q+2,2)
  if(type==1){
   v<-q+4
   if(uncompressed==4294967295){uncompressed<-num(b,v,8);v<-v+8}
   if(compressed==4294967295){compressed<-num(b,v,8);v<-v+8}
   if(offset==4294967295)offset<-num(b,v,8)
  }
  q<-q+4+len
 }
 entries[[name]]<-list(offset=offset,size=compressed,uncompressed=uncompressed,method=method)
 p<-p+46+namelen+extralen+commentlen
}

# Bounded read-only archive scan. Original W01 canonical records retain per-manifestation abstracts.
# This recovers what is actually present; it does NOT claim unmodified raw source equivalence.
suppressPackageStartupMessages({library(data.table);library(jsonlite)})
target_path <- "reference/outputs/workflow01_candidates/all_candidate_pairs.csv"
meta_path <- "reference/outputs/workflow01_candidates/normalised_metadata.csv"
if(!all(file.exists(c(target_path,meta_path))))stop("Missing frozen October candidate inputs")
meta <- fread(meta_path,colClasses=list(character=c("source","source_record_id")))
cand <- fread(target_path)
if(nrow(cand)!=1719L)stop("Unexpected October candidate count")
if(anyDuplicated(meta$idx)||anyDuplicated(meta[,.(source,source_record_id)]))stop("Duplicate frozen identities")
indexes <- unique(c(cand$record_i,cand$record_j))
targets <- meta[match(indexes,idx)]
if(anyNA(targets$source)||anyNA(targets$source_record_id))stop("Unmapped candidate identity")
key <- function(s,id)paste0(nchar(s,type="bytes"),":",s,nchar(id,type="bytes"),":",id)
needed <- key(targets$source,targets$source_record_id)
if(anyDuplicated(needed))stop("Duplicate target identities")
for(name in c("previous_state/canonical/records.jsonl","outputs/canonical/records.jsonl"))
 if(!name%in%names(entries))stop("Missing archived canonical member: ",name)
# Archived manifests are ZIP method 0 (STORED); require exact ranged reads.
selected <- "outputs/canonical/records.jsonl"
e <- entries[[selected]]
if(e$method!=0||e$size!=e$uncompressed||e$size>700000000)stop("Canonical member exceeds bounded 700MB limit")
header <- tempfile();request(e$offset,e$offset+255,header,256)
x<-readBin(header,"raw",n=256);unlink(header)
if(!sig(x,0,c(0x50,0x4b,0x03,0x04)))stop("Invalid local member header")
fn<-num(x,26,2);ex<-num(x,28,2)
if(!identical(rawToChar(x[31:(30+fn)]),selected))stop("Member identity mismatch")
data_offset<-e$offset+30+fn+ex
chunk_size<-2097152
if(e$size>700000000)stop("Transfer budget exceeded")
result<-new.env(hash=TRUE,parent=emptyenv())
target_env<-new.env(hash=TRUE,parent=emptyenv())
for(k in needed)assign(k,TRUE,envir=target_env)
carry<-raw()
process_line<-function(b){
 if(!length(b))return(invisible(NULL))
 obj<-tryCatch(fromJSON(rawToChar(b),simplifyVector=FALSE),error=function(err)stop("Malformed canonical JSONL"))
 if(is.null(obj$manifestations))stop("Missing per-manifestation records")
 for(m in obj$manifestations){
  s<-as.character(m$source %||% "");id<-as.character(m$source_record_id %||% "")
  k<-key(s,id)
  if(exists(k,envir=target_env,inherits=FALSE)){
   if(exists(k,envir=result,inherits=FALSE))stop("Repeated manifestation in canonical archive")
   assign(k,list(source=s,source_record_id=id,abstract=m$abstract %||% NULL,
    abstract_stripped=isTRUE(m$abstract_stripped),work_id=obj$deduplication$cluster_id),envir=result)
  }
 }
}
`%||%`<-function(a,b)if(is.null(a))b else a
for(start in seq(0,e$size-1,by=chunk_size)){
 finish<-min(e$size-1,start+chunk_size-1)
 f<-tempfile();request(data_offset+start,data_offset+finish,f,chunk_size)
 b<-readBin(f,"raw",n=chunk_size);unlink(f)
 b<-c(carry,b)
 ends<-which(b==as.raw(10))
 if(length(ends)){
  prev<-0L
  for(pos in ends){
   if(pos>prev+1L)process_line(b[(prev+1L):(pos-1L)])
   prev<-pos
  }
  carry<-if(prev<length(b))b[(prev+1L):length(b)]else raw()
 }else carry<-b
 if(length(carry)>2097152)stop("Single canonical record exceeds 2 MiB")
}
if(length(carry))process_line(carry)
retrieved<-ls(result,all.names=TRUE)
missing<-setdiff(needed,retrieved)
records<-lapply(needed,function(k)if(exists(k,envir=result,inherits=FALSE))get(k,envir=result)else NULL)
dir.create("october_abstract_recovery",showWarnings=FALSE)
write_json(Filter(Negate(is.null),records),"october_abstract_recovery/candidate_manifestation_abstracts.json",
 auto_unbox=TRUE,pretty=FALSE,null="null")
write_json(list(schema="w01-fast-october-canonical-abstract-recovery-v1",
 candidate_pairs=nrow(cand),required_manifestations=length(needed),
 recovered_manifestations=length(retrieved),missing_manifestations=length(missing),
 missing_stable_ids=as.list(missing),
 stripped_abstracts=sum(vapply(Filter(Negate(is.null),records),function(z)isTRUE(z$abstract_stripped),logical(1))),
 missing_abstract_text=sum(vapply(Filter(Negate(is.null),records),function(z)is.null(z$abstract),logical(1))),
 original_raw_source_text_parity_established=FALSE,independent_scoring_parity_established=FALSE),
 "october_abstract_recovery/report.json",auto_unbox=TRUE,pretty=TRUE)
if(length(missing))stop("Some candidate manifestations absent from canonical archive: ",length(missing))
cat(sprintf("PASS: located %d of %d candidate manifestations in archived canonical records\\n",length(retrieved),length(needed)))
