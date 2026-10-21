#!/usr/bin/env Rscript
# Read-only ZIP64 STORED member extraction with hard transfer/size caps.
# Never downloads or unpacks the complete 27 GB GitHub Actions archive.
artifact_id <- "12259032049"
repo <- "thesalmonandthetomato/LivingEvidenceMap"
selected <- c("previous_state/canonical/records.jsonl")
out <- "october_affected_manifestation_comparison"
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



suppressPackageStartupMessages({library(data.table);library(jsonlite)})
historic_path<-"october_historical_affected_source/historic_affected_canonical_records.jsonl"
scope_path<-"october_affected_scope/affected_cluster_map.csv"
if(!all(file.exists(c(historic_path,scope_path))))stop("Missing frozen historical affected works")
before<-lapply(readLines(historic_path,warn=FALSE),fromJSON,simplifyVector=FALSE)
scope<-fread(scope_path,colClasses=list(character=c("source","source_record_id","cluster_id")))
ids<-sort(unique(scope$cluster_id))
if(length(before)!=44L||length(ids)!=44L)stop("Expected 44 historical works")
if(!"outputs/canonical/records.jsonl"%in%names(entries))stop("Missing final canonical archive")
e<-entries[["outputs/canonical/records.jsonl"]]
if(e$method!=0||e$size!=e$uncompressed||e$size>700000000)stop("Unexpected final canonical member")
header<-tempfile();request(e$offset,e$offset+255,header,256)
x<-readBin(header,"raw",n=256);unlink(header)
if(!sig(x,0,c(0x50,0x4b,0x03,0x04)))stop("Invalid ZIP local header")
fname<-num(x,26,2);extra<-num(x,28,2)
data_offset<-e$offset+30+fname+extra
if(!identical(rawToChar(x[31:(30+fname)]),"outputs/canonical/records.jsonl"))
 stop("Mismatched final canonical member")
total_bytes<-0
read_mid_record<-function(position){
 for(span in c(32768,131072,262144)){
   start<-max(0,floor(position-span));end<-min(e$size-1,floor(position+span))
   bytes<-end-start+1
   total_bytes<<-total_bytes+bytes
   if(total_bytes>120000000)stop("Exceeded 120MB strict ranged-transfer budget")
   f<-tempfile();request(data_offset+start,data_offset+end,f,bytes)
   d<-readBin(f,"raw",n=bytes);unlink(f)
   newlines<-which(d==as.raw(10))
   relative<-position-start+1
   prev<-newlines[newlines<relative];nexts<-newlines[newlines>=relative]
   first<-if(start==0&&length(prev)==0L)0L else if(length(prev))tail(prev,1L)else NA_integer_
   stopat<-if(length(nexts))nexts[[1L]]else NA_integer_
   if(!is.na(first)&&!is.na(stopat)&&stopat>first+1L){
     value<-tryCatch(fromJSON(rawToChar(d[(first+1L):(stopat-1L)]),simplifyVector=FALSE),error=function(e)NULL)
     if(!is.null(value)&&is.list(value$deduplication)&&nzchar(value$deduplication$cluster_id))
       return(value)
   }
 }
 stop("Cannot locate bounded complete canonical JSONL record at target byte position")
}
find_work<-function(target){
 low<-0;high<-e$size-1;tries<-0L
 while(low<=high&&tries<43L){
  mid<-floor((low+high)/2)
  record<-read_mid_record(mid);tries<-tries+1L
  candidate<-as.character(record$deduplication$cluster_id)
  if(identical(candidate,target))return(record)
  if(candidate<target)low<-mid+1 else high<-mid-1
 }
 stop(sprintf("Cannot locate canonical work %s by ordered reference bytes",target))
}


key<-function(m)paste0(nchar(m$source,type="bytes"),":",m$source,nchar(m$source_record_id,type="bytes"),":",m$source_record_id)
old<-setNames(before,vapply(before,function(w)w$deduplication$cluster_id,character(1)))
if(!setequal(names(old),ids))stop("Historic work IDs not aligned with successor")
different<-list()
counts<-list()
for(i in seq_along(ids)){
 id<-ids[[i]];prev<-old[[id]];nextwork<-find_work(id)
 p<-prev$manifestations;n<-nextwork$manifestations
 oldkeys<-vapply(p,key,character(1));newkeys<-vapply(n,key,character(1))
 if(anyDuplicated(oldkeys)||anyDuplicated(newkeys)||
    length(setdiff(oldkeys,newkeys)))stop("Historic manifestation dropped or duplicated")
 appended<-setdiff(newkeys,oldkeys)
 expected<-scope[cluster_id==id]
 if(!setequal(newkeys,paste0(nchar(expected$source,type="bytes"),":",expected$source,
  nchar(expected$source_record_id,type="bytes"),":",expected$source_record_id)))
  stop("Final work does not match exact affected identity set: ",id)
 for(j in seq_along(oldkeys)){
   historic_m<-p[[j]];final_m<-n[[match(oldkeys[[j]],newkeys)]]
   if(!identical(historic_m,final_m)){
    differing<-union(names(historic_m),names(final_m))
    differing<-differing[!vapply(differing,function(field)identical(historic_m[[field]],final_m[[field]]),logical(1))]
    different[[length(different)+1L]]<-list(work_id=id,stable_identity=oldkeys[[j]],fields=as.list(differing))
   }
 }
 counts[[i]]<-list(work_id=id,historical=length(oldkeys),appended=length(appended))
 if(i%%10L==0L||i==44L)cat(sprintf("Compared affected work %d/44; historical manifestation differences=%d; transfer=%.1fMiB\\n",
 i,length(different),total_bytes/1048576))
}
dir.create(file.path(out,"audit"),recursive=TRUE)
write_json(list(schema="w01-fast-october-affected-manifestation-preservation-v1",
 affected_existing_works=length(counts),historical_manifestations=sum(vapply(counts,function(z)z$historical,integer(1))),
 appended_manifestations=sum(vapply(counts,function(z)z$appended,integer(1))),
 historical_manifestation_content_differences=length(different),
 compared_fields="complete historical manifestation JSON objects",
 scientific_field_parity_of_rebuilt_final_works_established=FALSE,
 actual_original_raw_input_parity_established=FALSE,
 transferred_bytes=total_bytes,details=different,counts=counts),
 file.path(out,"audit","report.json"),auto_unbox=TRUE,pretty=TRUE)
if(length(different))stop("Historical manifestation fields changed across October update; inspect audit")
if(sum(vapply(counts,function(z)z$appended,integer(1)))!=44L)stop("Wrong number of October additions")
cat("PASS: all 177 historical manifestation JSON objects preserved exactly within 44 updated works\\n")
