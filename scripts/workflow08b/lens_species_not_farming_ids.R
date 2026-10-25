#!/usr/bin/env Rscript
# W08b authoritative Lens eligible ID export; isolated from production W01.
suppressPackageStartupMessages({library(jsonlite);library(httr2)})
`%||%`<-function(x,y)if(is.null(x))y else x
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=4L)stop("Usage: lens_species_not_farming_ids.R provider_ids.csv citation_edges.csv strategy.json output_dir")
d<-read.csv(a[[1]],stringsAsFactors=FALSE,na.strings=NULL)
cfg<-fromJSON(a[[3]],simplifyVector=FALSE)
if(!identical(cfg$search_version,"v2")||!("maricultur*"%in%unlist(cfg$farm_terms)))stop("Invalid strategy")
ids<-sort(unique(as.character(d$related_provider_id[d$provider=="lens"])))
if(!length(ids)||anyNA(ids)||any(!nzchar(ids)))stop("Invalid Lens candidate IDs")
terms_clause<-function(terms)paste(vapply(c("title","abstract","keyword"),function(f)
 paste0(f,":(",paste(terms,collapse=" OR "),")"),character(1)),collapse=" OR ")
species<-terms_clause(unlist(cfg$species_terms))
farming<-terms_clause(unlist(cfg$farm_terms))
token<-Sys.getenv("LENS_API_TOKEN","")
if(!nzchar(token))stop("Lens token unavailable")
out<-a[[4]];dir.create(out,recursive=TRUE,showWarnings=FALSE)
ledger<-file.path(out,"lens_eligible_batches.csv")
chunks<-split(ids,ceiling(seq_along(ids)/500L))
done<-if(file.exists(ledger))read.csv(ledger,stringsAsFactors=FALSE,na.strings=NULL) else
 data.frame(batch=integer(),id=character(),stringsAsFactors=FALSE)
for(i in seq_along(chunks)){
 if(i %in% done$batch)next
 batch<-chunks[[i]]
 q<-list(bool=list(must=list(list(terms=list(lens_id=as.list(batch))),
    list(query_string=list(query=species))),must_not=list(list(query_string=list(query=farming)))))
 payload<-list(query=q,size=500L,include=as.list(c("lens_id")))
 res<-NULL
 for(attempt in seq_len(5L)){
  Sys.sleep(1.5)
  res<-tryCatch(request("https://api.lens.org/scholarly/search")|>
   req_headers(Authorization=paste("Bearer",token),Accept="application/json")|>
   req_body_json(payload,auto_unbox=TRUE)|>req_timeout(180)|>
   req_error(is_error=function(x)FALSE)|>req_perform(),error=identity)
  if(inherits(res,"error"))stop("Lens transport: ",conditionMessage(res))
  if(resp_status(res)==429L){Sys.sleep(65);next}
  break
 }
 if(resp_status(res)!=200L)stop("Lens HTTP ",resp_status(res),": ",substr(resp_body_string(res),1L,600))
 obj<-resp_body_json(res,simplifyVector=FALSE)
 n<-as.integer(obj$total)
 if(length(n)!=1L||is.na(n)||n<0L||n>length(batch))stop("Invalid batch count ",i)
 found<-unique(vapply(obj$data %||% list(),function(x)as.character(x$lens_id %||% ""),character(1)))
 found<-found[nzchar(found)]
 if(length(found)!=n||any(!found%in%batch))stop("Missing/mismatched Lens IDs in batch ",i,": expected ",n,", got ",length(found))
 rows<-if(length(found))data.frame(batch=rep(i,length(found)),id=found) else data.frame(batch=i,id="")
 write.table(rows,ledger,sep=",",row.names=FALSE,col.names=!file.exists(ledger),append=file.exists(ledger),qmethod="double")
 if(i%%25L==0L)cat("Completed ",i,"/",length(chunks)," batches\n",sep="")
}
z<-read.csv(ledger,stringsAsFactors=FALSE,na.strings=NULL)
if(!setequal(unique(z$batch),seq_along(chunks)))stop("Incomplete ledger")
eligible<-sort(unique(z$id[nzchar(z$id)]))
write.csv(data.frame(provider="lens",related_provider_id=eligible),file.path(out,"eligible_lens_ids.csv"),row.names=FALSE)
# Joining only after filtering preserves all directions and originating seeds.
edges<-read.csv(a[[2]],stringsAsFactors=FALSE,na.strings=NULL)
if(!all(c("provider","related_provider_id","seed_record_id","direction")%in%names(edges)))stop("Invalid citation-edge schema")
edges<-edges[edges$provider=="lens"&edges$related_provider_id%in%eligible,,drop=FALSE]
write.csv(edges,file.path(out,"eligible_lens_citation_edges.csv"),row.names=FALSE)
summary<-list(schema="w08b-lens-eligible-ids-v1",strategy_version="v2",
 candidate_ids=length(ids),batches=length(chunks),eligible_ids=length(eligible),
 eligible_edges=nrow(edges),provider_side_species_and_not_farming=TRUE)
writeLines(toJSON(summary,pretty=TRUE,auto_unbox=TRUE),file.path(out,"summary.json"))
cat("PASS: Lens eligible IDs=",length(eligible),"; provenance edges=",nrow(edges),"\n",sep="")
