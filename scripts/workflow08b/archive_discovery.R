#!/usr/bin/env Rscript
# Archive an isolated W08b discovery checkpoint as restricted Zenodo data.
suppressPackageStartupMessages({library(jsonlite);library(httr2);library(digest)})
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=3L)stop("Usage: archive_discovery.R <discovery-dir> <run-id> <receipt.json>")
root<-normalizePath(a[[1]],mustWork=TRUE);run<-a[[2]];receipt<-a[[3]]
token<-Sys.getenv("ZENODO_ACCESS_TOKEN","")
if(!nzchar(token))stop("ZENODO_ACCESS_TOKEN absent")
state<-file.path(root,"discovery_summary.json")
ledger<-file.path(root,"lens_seed_status.jsonl")
if(!file.exists(state)||!file.exists(ledger))stop("Incomplete checkpoint directory")
info<-fromJSON(state,simplifyVector=FALSE)
if(!identical(info$schema,"workflow08b-lens-discovery-dev-v1"))stop("Unrecognised W08b state")
if(isTRUE(info$test_fixture_mode))stop("Refusing to archive fixture-based Lens discovery")
for(p in c("openalex_summary.json","doi_resolution_summary.json")){
 q<-file.path(root,p)
 if(file.exists(q)&&isTRUE(fromJSON(q,simplifyVector=FALSE)$test_fixture_mode))
   stop("Refusing to archive fixture-based provider discovery: ",p)
}
archive<-file.path(tempdir(),paste0("w08b-discovery-run-",run,".tar.gz"))
files<-list.files(root,recursive=TRUE,all.files=TRUE,no..=TRUE)
if(!length(files))stop("Empty checkpoint")
# Use a real function scope for cleanup, including when sourced in tests.
create_archive<-function(){
 old<-setwd(root)
 on.exit(setwd(old),add=TRUE)
 utils::tar(archive,files=files,compression="gzip",tar="internal")
 members<-utils::untar(archive,list=TRUE)
 if(!setequal(sub("^\\./","",members),files))stop("Checkpoint tar inventory differs from source files")
}
create_archive()
sha<-digest(file=archive,algo="sha256",serialize=FALSE)
api<-"https://zenodo.org/api/deposit/depositions"
auth<-function(r)req_headers(r,Authorization=paste("Bearer",token))
call<-function(r,allowed,label,timeout=120,retries=1L){
 for(attempt in seq_len(retries)){
   x<-tryCatch(req_perform(req_error(req_timeout(r,timeout),is_error=function(resp)FALSE)),error=identity)
   if(!inherits(x,"error")&&resp_status(x)%in%allowed)return(x)
   retryable<-inherits(x,"error")||resp_status(x)%in%c(408L,429L,500L,502L,503L,504L)
   if(!retryable||attempt==retries){
     if(inherits(x,"error"))stop("Zenodo ",label,": ",conditionMessage(x))
     stop("Zenodo ",label," HTTP ",resp_status(x),": ",substr(resp_body_string(x),1,600))
   }
   message("Zenodo ",label," retry ",attempt,"/",retries)
   Sys.sleep(min(60,5*2^(attempt-1L)))
 }
}
monthly<-identical(Sys.getenv("W08B_MONTHLY_DRAFT"),"1")
final<-identical(Sys.getenv("W08B_FINAL_PUBLISH"),"1")
readdep<-function(id)resp_body_json(call(auth(request(paste0(api,"/",id))),200L,"read deposition",retries=3L),simplifyVector=FALSE)
file_md5<-function(x)sub("^md5:","",tolower(as.character(if(is.null(x$checksum))x$checksum_md5 else x$checksum)))
file_name<-function(x)as.character(x$filename)
metadata<-list(metadata=list(
 title=paste("Living Evidence Map W08b citation-discovery checkpoint | run",run),
 upload_type="dataset",publication_date=format(Sys.Date(),"%Y-%m-%d"),
 description="<p>Restricted W08b incremental citation-discovery checkpoint with seed statuses and provider-specific citation edges. Incomplete seeds remain retryable. Not a released evidence map.</p>",
 creators=list(list(name="Haddaway, Neal")),access_right="restricted",
 access_conditions="Derived citation edges and record identifiers from licensed scholarly metadata sources.",
 keywords=list("Living Evidence Map","citation chasing","W08b","checkpoint")))
pointer<-NULL
if(monthly){
 s<-fromJSON(file.path(root,"monthly_discovery_status.json"),simplifyVector=FALSE)
 month<-as.character(s$update_month);canonical<-tolower(as.character(s$w08_canonical_sha256))
 stopifnot(grepl("^[0-9]{4}-(0[1-9]|1[0-2])$",month),grepl("^[a-f0-9]{64}$",canonical))
 if(final&&!isTRUE(s$provider_discovery_complete))stop("Refusing to publish incomplete discovery")
 title<-paste("Living Evidence Map W08b monthly discovery",month)
 identity<-paste0("W08b release identity: ",month," / ",canonical)
 metadata$metadata$title<-title
 metadata$metadata$description<-paste0(metadata$metadata$description,"<p>",identity,"</p>")
 pointer<-Sys.getenv("W08B_DRAFT_POINTER","")
 if(!nzchar(pointer))stop("Monthly draft pointer required")
 if(file.exists(pointer)){
   p<-fromJSON(pointer,simplifyVector=FALSE)
   stopifnot(identical(p$update_month,month),identical(p$w08_canonical_sha256,canonical),
      grepl("^[0-9]+$",p$zenodo_record_id))
   created<-readdep(p$zenodo_record_id)
 }else{
   # Atomic creation with identifying metadata; recover a named draft after
   # a lost response rather than knowingly create a second deposition.
   found<-list()
   for(page in seq_len(100L)){
     rr<-auth(request(api))|>req_url_query(q=paste0('title:"',title,'"'),size=100,page=page,all_versions=TRUE)
     rows<-resp_body_json(call(rr,200L,"find monthly deposit",retries=3L),simplifyVector=FALSE)
     if(!is.list(rows)||!is.null(rows$hits))stop("Unexpected deposition listing")
     found<-c(found,Filter(function(z)identical(z$metadata$title,title)||identical(z$title,title),rows))
     if(length(rows)<100L)break
     if(page==100L)stop("Monthly deposition lookup exceeded pagination bound")
   }
   if(length(found)>1L)stop("Multiple monthly deposits; reconcile explicitly")
   if(length(found)==1L)created<-readdep(as.character(found[[1]]$id))
   else created<-resp_body_json(call(auth(req_method(request(api),"POST"))|>
      req_body_json(metadata,auto_unbox=TRUE),201L,"create named monthly draft"),simplifyVector=FALSE)
 }
 id<-as.character(created$id)
 stopifnot(grepl("^[0-9]+$",id),identical(created$metadata$title,title),
   identical(created$metadata$access_right,"restricted"),
   grepl(identity,created$metadata$description,fixed=TRUE))
 if(isTRUE(created$submitted))stop("Monthly deposit is already published; reconcile its receipt rather than modify or create another")
 # Record draft identity before uploading; callers persist the receipt.
 fn<-paste0("w08b-discovery-run-",run,"-",sha,".tar.gz")
 # On the next upload, keep the last committed checkpoint until the new
 # object has passed the remote checksum gate.
 previous_file<-if(file.exists(pointer))as.character(p$archive_filename)else ""
 if(nzchar(previous_file)&&!previous_file%in%vapply(created$files,file_name,character(1)))stop("Committed draft checkpoint missing")
 if(nzchar(previous_file)){
   prior<-Filter(function(x)identical(file_name(x),previous_file),created$files)
   stopifnot(length(prior)==1L,identical(file_md5(prior[[1]]),p$md5))
   # Remove only superseded draft files after the previous pointer is durable.
   for(x in created$files){
     nm<-file_name(x)
     if(identical(nm,previous_file))next
     if(!grepl("^w08b-discovery-run-.*[.]tar[.]gz$",nm))stop("Unexpected monthly draft file")
     call(auth(req_method(request(paste0(api,"/",id,"/files/",x$id)),"DELETE")),c(200L,204L),"prune superseded draft checkpoint")
   }
 }

}else{
 created<-resp_body_json(call(auth(req_method(request(api),"POST"))|>
   req_body_raw(charToRaw("{}"),type="application/json"),201L,"draft create"),simplifyVector=FALSE)
 id<-as.character(created$id)
 call(auth(req_method(request(paste0(api,"/",id)),"PUT"))|>req_body_json(metadata,auto_unbox=TRUE),200L,"metadata")
 fn<-basename(archive)
}
bucket<-as.character(created$links$bucket)
stopifnot(nzchar(id),nzchar(bucket))
up<-auth(req_method(request(paste0(bucket,"/",URLencode(fn,reserved=TRUE))),"PUT"))|>
 req_headers(Expect="")|>req_body_file(archive)
call(up,c(200L,201L),"upload",timeout=1800,retries=5L)
dep<-readdep(id)
hits<-Filter(function(x)identical(file_name(x),fn),dep$files)
md5<-tolower(digest(file=archive,algo="md5",serialize=FALSE))
if(length(hits)!=1L)stop("Uploaded archive not uniquely present in remote inventory: ",fn)
if(!identical(file_md5(hits[[1]]),md5))stop("Uploaded archive failed remote MD5 verification: expected ",md5,"; received ",file_md5(hits[[1]]))
record<-id
status<-"draft"
if(!monthly){
 pub<-tryCatch(resp_body_json(call(auth(req_method(request(paste0(api,"/",id,"/actions/publish")),"POST")),
    c(200L,201L,202L),"publish"),simplifyVector=FALSE),error=identity)
 if(inherits(pub,"error")){
    pub<-readdep(id)
    if(!isTRUE(pub$submitted))stop("Publication not confirmed; retained draft ",id)
 }
 pub<-readdep(id)
 if(!isTRUE(pub$submitted)||!identical(pub$metadata$access_right,"restricted"))stop("Publication/restriction not confirmed")
 record<-as.character(if(is.null(pub$record_id))pub$id else pub$record_id)
 status<-"published"
}
dir.create(dirname(receipt),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(list(schema="workflow08b-discovery-checkpoint-v1",status=status,
 run_id=run,zenodo_record_id=record,sha256=sha,md5=md5,archive_filename=fn,
 requests=info$requests_this_execution,complete=info$complete_seeds,
 incomplete=info$incomplete_seeds),pretty=TRUE,auto_unbox=TRUE),receipt)
if(monthly){
 p<-list(schema="workflow08b-monthly-draft-pointer-v1",update_month=month,w08_canonical_sha256=canonical,
   zenodo_record_id=record,status=status,archive_filename=fn,sha256=sha,md5=md5,run_id=run)
 dir.create(dirname(pointer),recursive=TRUE,showWarnings=FALSE)
 writeLines(toJSON(p,auto_unbox=TRUE,pretty=TRUE),pointer)
}
cat("PASS: W08b restricted checkpoint ",status,": Zenodo ",record,"\n",sep="")
