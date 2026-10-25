#!/usr/bin/env Rscript
# Isolated W08b OpenAlex provider-side eligibility harvest.
# Searches title, abstract and keywords; preserves OpenAlex identities and source provenance.
suppressPackageStartupMessages({library(jsonlite);library(httr2)})
a <- commandArgs(trailingOnly=TRUE)
if(length(a)!=4L) stop("Usage: harvest_openalex_eligible.R provider_candidate_ids.csv citation_edges.csv strategy.json output_dir")
d <- read.csv(a[[1]],stringsAsFactors=FALSE,na.strings=NULL)
edges <- read.csv(a[[2]],stringsAsFactors=FALSE,na.strings=NULL)
cfg <- fromJSON(a[[3]],simplifyVector=FALSE)
if(!identical(cfg$search_version,"v2")) stop("Strategy version mismatch")
if(!all(c("provider","related_provider_id") %in% names(d))) stop("Missing candidate columns")
if(!all(c("seed_record_id","provider","related_provider_id","direction") %in% names(edges))) stop("Missing provenance columns")
norm <- function(x) toupper(sub("^https?://openalex[.]org/","",trimws(as.character(x)),ignore.case=TRUE))
ids <- sort(unique(norm(d$related_provider_id[d$provider=="openalex"])))
if(!length(ids)||any(!grepl("^W[0-9]+$",ids))) stop("Invalid OpenAlex candidate IDs")
out <- a[[4]];dir.create(out,recursive=TRUE,showWarnings=FALSE)
file <- file.path(out,"openalex_batch_ledger.csv")
batch_size <- 40L
groups <- split(ids,ceiling(seq_along(ids)/batch_size))
sp <- paste(cfg$species_terms,collapse=" OR ")
fm <- paste(cfg$farm_terms,collapse=" OR ")
expression <- paste0("(",sp,") NOT (",fm,")")
key <- Sys.getenv("OPENALEX_API_KEY","")
if(!nzchar(key)) stop("Missing OpenAlex API key")
req <- function(group) {
  q <- request("https://api.openalex.org/works") |>
    req_url_query(filter=paste0("ids.openalex:",paste(group,collapse="|")),
      search.title_abstract_keywords.exact=expression,per_page=200,select="id",api_key=key) |>
    req_timeout(120)
  for(attempt in seq_len(5L)) {
    z <- tryCatch(req_perform(req_error(q,is_error=function(x)FALSE)),error=identity)
    if(!inherits(z,"error") && resp_status(z)==200L) return(resp_body_json(z,simplifyVector=FALSE))
    status <- if(inherits(z,"error")) 0L else resp_status(z)
    if(!(status %in% c(0L,429L,500L,502L,503L,504L))) 
      stop("OpenAlex HTTP ",status,": ",substr(resp_body_string(z),1,500))
    if(attempt==5L) stop("OpenAlex retry exhaustion for batch, HTTP ",status)
    Sys.sleep(min(2^attempt,30))
  }
}
completed <- if(file.exists(file)) read.csv(file,stringsAsFactors=FALSE) else
  data.frame(batch=integer(),id=character(),stringsAsFactors=FALSE)
for(i in seq_along(groups)) {
  if(i %in% completed$batch) next
  result <- req(groups[[i]])
  found <- norm(vapply(result$results,function(x)as.character(x$id),character(1)))
  if(any(!found %in% groups[[i]]) || length(found)!=as.integer(result$meta$count))
    stop("Incomplete or mismatched response, batch ",i)
  # Record an explicit empty batch, so retries do not repeat unsuccessful selection.
  rows <- if(length(found)) data.frame(batch=rep(i,length(found)),id=found) else data.frame(batch=i,id="")
  write.table(rows,file,sep=",",row.names=FALSE,col.names=!file.exists(file),append=file.exists(file),qmethod="double")
  if(i%%20L==0L) cat("Completed",i,"of",length(groups),"batches\n")
  Sys.sleep(0.12)
}
ledger <- read.csv(file,stringsAsFactors=FALSE,na.strings=NULL)
if(!setequal(unique(ledger$batch),seq_along(groups))) stop("Incomplete harvest ledger")
selected <- sort(unique(ledger$id[nzchar(ledger$id)]))
write.csv(data.frame(provider="openalex",related_provider_id=selected),
  file.path(out,"eligible_openalex_ids.csv"),row.names=FALSE)
e <- edges[edges$provider=="openalex" & norm(edges$related_provider_id)%in%selected,,drop=FALSE]
write.csv(e,file.path(out,"eligible_openalex_citation_edges.csv"),row.names=FALSE)
writeLines(toJSON(list(schema="w08b-openalex-eligible-v1",strategy_version=cfg$search_version,
  search_scope="title_abstract_keywords.exact",candidate_ids=length(ids),
  batches=length(groups),eligible_ids=length(selected),eligible_edges=nrow(e),
  provider_side_species_and_not_farming=TRUE),pretty=TRUE,auto_unbox=TRUE),
  file.path(out,"summary.json"))
cat("PASS: OpenAlex eligible IDs=",length(selected)," / ",length(ids),"; provenance edges=",nrow(e),"\n",sep="")
