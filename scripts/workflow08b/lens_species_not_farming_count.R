#!/usr/bin/env Rscript
# Count distinct Lens citation candidates excluding original v2 search,
# without fetching bibliographies or touching W01.
suppressPackageStartupMessages({library(jsonlite);library(httr2)})
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=3L)stop("Usage: lens_not_count.R provider_candidate_ids.csv strategy.json output_dir")
d<-read.csv(a[[1]],stringsAsFactors=FALSE,na.strings=NULL)
cfg<-fromJSON(a[[2]],simplifyVector=FALSE)
if(!identical(cfg$search_version,"v2")||!("maricultur*"%in%unlist(cfg$farm_terms)))stop("Wrong strategy")
if(!all(c("provider","related_provider_id")%in%names(d)))stop("Invalid candidates")
ids<-sort(unique(d$related_provider_id[d$provider=="lens"]))
if(anyNA(ids)||any(!nzchar(ids)))stop("Invalid Lens ID")
terms_clause<-function(terms)paste(vapply(c("title","abstract","keyword"),function(f)
 paste0(f,":(",paste(terms,collapse=" OR "),")"),character(1)),collapse=" OR ")
species<-terms_clause(unlist(cfg$species_terms))
farming<-terms_clause(unlist(cfg$farm_terms))
token<-Sys.getenv("LENS_API_TOKEN","");if(!nzchar(token))stop("Lens token unavailable")
dir.create(a[[3]],recursive=TRUE,showWarnings=FALSE)
ledger<-file.path(a[[3]],"lens_species_not_farming_batches.jsonl")
done<-new.env(hash=TRUE,parent=emptyenv())
if(file.exists(ledger))for(line in readLines(ledger,warn=FALSE)){
 if(!nzchar(line))next
 z<-fromJSON(line,simplifyVector=FALSE)
 if(identical(z$status,"complete"))assign(as.character(z$batch_key),z,done)
}
chunks<-split(ids,ceiling(seq_along(ids)/500L))
total<-0;tested<-0L;errors<-0L
for(i in seq_along(chunks)){
 batch<-chunks[[i]]
 key<-paste0(i,":",batch[[1]],":",batch[[length(batch)]])
 if(exists(key,done,inherits=FALSE)){
  z<-get(key,done);total<-total+as.integer(z$count);next
 }
 q<-list(bool=list(must=list(list(terms=list(lens_id=as.list(batch))),list(query_string=list(query=species))),
                   must_not=list(list(query_string=list(query=farming)))))
 payload<-list(query=q,size=1L)
 res<-NULL
 for(attempt in seq_len(5L)){
  # Lens permits 50 requests/minute; remain comfortably below this ceiling.
  Sys.sleep(1.5)
  res<-tryCatch(request("https://api.lens.org/scholarly/search")|>
   req_headers(Authorization=paste("Bearer",token),Accept="application/json")|>
   req_body_json(payload,auto_unbox=TRUE)|>req_timeout(180)|>
   req_error(is_error=function(x)FALSE)|>req_perform(),error=identity)
  if(inherits(res,"error"))stop("Lens transport: ",conditionMessage(res))
  if(resp_status(res)==429L){
   message("Lens rate limited; retrying batch ",i," after cooling interval")
   Sys.sleep(65)
   next
  }
  break
 }
 if(resp_status(res)!=200L)stop("Lens HTTP ",resp_status(res),": ",substr(resp_body_string(res),1L,600))
 obj<-resp_body_json(res,simplifyVector=FALSE)
 n<-as.integer(obj$total)
 if(length(n)!=1L||is.na(n)||n<0L||n>length(batch))stop("Invalid count for batch ",i,": ",obj$total)
 z<-list(batch_key=key,batch_index=i,submitted=length(batch),count=n,status="complete")
 cat(toJSON(z,auto_unbox=TRUE),"\n",file=ledger,append=TRUE,sep="")
 total<-total+n;tested<-tested+1L
}
result<-list(schema="w08b-lens-species-not-farming-count-v1",strategy="v2",submitted_unique_lens_ids=length(ids),
 total_after_provider_not=total,not_retained_by_species_and_not_farming=length(ids)-total,
 number_of_batches=length(chunks),new_requests=tested,
 distinct_lens_ids_count_only=TRUE,not_cross_provider_or_w01_deduplicated=TRUE)
writeLines(toJSON(result,pretty=TRUE,auto_unbox=TRUE),file.path(a[[3]],"lens_species_not_farming_summary.json"))
cat("PASS: unique Lens IDs=",length(ids),"; NOT count=",total,
 "; excluded=",length(ids)-total,"; requests=",tested,"\n",sep="")
