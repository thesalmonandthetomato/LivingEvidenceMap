#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

previous_seed <- arg("--previous-seed")
checkpoint_dir <- arg("--checkpoint-dir")
output_dir <- arg("--output-dir")
if(any(vapply(list(previous_seed,checkpoint_dir,output_dir),is.null,logical(1)))) {
  stop("Required: --previous-seed --checkpoint-dir --output-dir",call.=FALSE)
}
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

files <- c(
  lens="lens_records_for_deduplication.jsonl",
  scopus="scopus_records_for_deduplication.jsonl",
  openalex="openalex_records_for_deduplication.jsonl",
  agricola="agricola_records_for_deduplication.jsonl",
  wos="wos_records_for_deduplication.jsonl"
)
append_raw <- function(base,delta,out){
  con_in <- file(base,"rb"); con_out <- file(out,"wb")
  on.exit(close(con_in),add=TRUE); on.exit(close(con_out),add=TRUE)
  repeat{
    z <- readBin(con_in,"raw",n=1024L*1024L)
    if(!length(z)) break
    writeBin(z,con_out)
  }
  close(con_in); on.exit(NULL,add=FALSE)
  if(file.exists(delta)&&file.info(delta)$size>0){
    z <- readBin(delta,"raw",n=file.info(delta)$size)
    writeBin(z,con_out)
  }
  close(con_out); on.exit(NULL,add=FALSE)
}
count_lines <- function(path){
  con<-file(path,"rt",encoding="UTF-8");on.exit(close(con),add=TRUE)
  n<-0L
  repeat{
    x<-readLines(con,n=10000L,warn=FALSE)
    if(!length(x))break
    n<-n+sum(nzchar(trimws(x)))
  }
  n
}

cm <- fromJSON(file.path(checkpoint_dir,"checkpoint_manifest.json"),simplifyVector=FALSE)
counts <- list()
for(src in names(files)){
  base <- file.path(previous_seed,files[[src]])
  delta <- file.path(checkpoint_dir,"source_manifestations",paste0(src,"_new.jsonl"))
  out <- file.path(output_dir,files[[src]])
  if(!file.exists(base)||!file.exists(delta)) stop(sprintf("Missing checkpoint source input for %s",src),call.=FALSE)
  before <- count_lines(base); add <- count_lines(delta)
  append_raw(base,delta,out)
  after <- count_lines(out)
  if(after!=before+add) stop(sprintf("Source append count mismatch for %s",src),call.=FALSE)
  expected_add <- as.integer(cm$new_source_manifestations_by_source[[src]])
  if(add!=expected_add) stop(sprintf("Checkpoint source count mismatch for %s",src),call.=FALSE)
  counts[[src]] <- list(previous=before,added=add,current=after,
                       sha256=digest(file=out,algo="sha256",serialize=FALSE))
}
writeLines(toJSON(list(status="PASS",source_counts=counts),auto_unbox=TRUE,pretty=TRUE),
           file.path(output_dir,"checkpoint_source_reconstruction.json"))
cat(sprintf("PASS: reconstructed checkpoint source union with %d appended manifestations\n",
            sum(vapply(counts,function(z)z$added,integer(1)))))
