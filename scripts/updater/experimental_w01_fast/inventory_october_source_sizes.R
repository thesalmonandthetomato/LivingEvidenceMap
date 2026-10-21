#!/usr/bin/env Rscript
# Read-only ZIP64 STORED member extraction with hard transfer/size caps.
# Never downloads or unpacks the complete 27 GB GitHub Actions archive.
artifact_id <- "12259032049"
repo <- "thesalmonandthetomato/LivingEvidenceMap"
selected <- c(
 "previous_state/workflow01_full_five_source/manifestation_cluster_map.csv",
 "previous_state/workflow01_full_five_source/summary.json",
 "outputs/final/manifestation_cluster_map.csv",
 "outputs/final/summary.json",
 "outputs/final/cluster_id_aliases.csv",
 "outputs/final/explicit_cluster_split_audit.jsonl",
 "outputs/canonical/canonical_manifest.json",
 "outputs/workflow01_union/union_manifest.json"
)
out <- "w01_fast_archive_inventory"
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
rows<-lapply(names(entries),function(name){
 e<-entries[[name]]
 list(path=name,stored_bytes=e$size,uncompressed_bytes=e$uncompressed,method=e$method)
})
jsonlite::write_json(rows,file.path(out,"archive_inventory.json"),auto_unbox=TRUE,pretty=TRUE)
interesting<-grep("records\\\\.jsonl|source_inputs\\\\.json|canonical/records|incremental|repair|strip|summary",names(entries),value=TRUE)
for(name in interesting){
 e<-entries[[name]]
 cat(sprintf("INVENTORY: %s | %.0f bytes\\n",name,e$size))
}
cat(sprintf("PASS: inventoried %d members without extracting corpus\\n",length(entries)))
