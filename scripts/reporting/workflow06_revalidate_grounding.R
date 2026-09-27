#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(jsonlite)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
input <- arg("--input")
out_dir <- arg("--output-dir","outputs/workflow06_grounding_revalidation")
if(is.null(input)||!file.exists(input)) stop("--input is required",call.=FALSE)
dir.create(out_dir,recursive=TRUE,showWarnings=FALSE)

norm_ws <- function(z){
  z <- as.character(z); z[is.na(z)] <- ""
  trimws(gsub("[[:space:]]+"," ",z,perl=TRUE))
}
normalise_grounding_text <- function(z){
  z <- as.character(z); z[is.na(z)] <- ""
  z <- gsub("\\\\n|\\\\r|\\\\t", " ", z, perl=TRUE)
  z <- gsub("&nbsp;|&#160;|&#xA0;", " ", z, ignore.case=TRUE, perl=TRUE)
  z <- gsub("&amp;", "&", z, ignore.case=TRUE, fixed=FALSE)
  z <- gsub("[\u00AD\u200B\uFEFF]", "", z, perl=TRUE)
  z <- chartr("\u2018\u2019\u201C\u201D\u2010\u2011\u2012\u2013\u2014",
              "''\"\"-----", z)
  tolower(norm_ws(z))
}
ground_one <- function(evidence,title,abstract){
  e_raw <- as.character(evidence)
  if(is.na(e_raw)||!nzchar(trimws(e_raw))) return(list(valid=FALSE,method="missing"))
  txt <- normalise_grounding_text(paste(title,abstract,sep=" "))
  e <- normalise_grounding_text(e_raw)
  if(grepl(e,txt,fixed=TRUE)) return(list(valid=TRUE,method="normalised_contiguous"))
  raw <- gsub("\u2026","...",e_raw,fixed=TRUE)
  if(!grepl("...",raw,fixed=TRUE)) return(list(valid=FALSE,method="not_found"))
  parts <- strsplit(raw,"...",fixed=TRUE)[[1L]]
  parts <- vapply(parts,normalise_grounding_text,character(1))
  parts <- trimws(gsub("^[. ]+|[. ]+$","",parts,perl=TRUE))
  parts <- parts[nzchar(parts)&nchar(parts)>=4L]
  if(length(parts)<2L) return(list(valid=FALSE,method="ellipsis_insufficient"))
  pos <- 1L
  for(part in parts){
    rem <- substr(txt,pos,nchar(txt))
    hit <- regexpr(part,rem,fixed=TRUE)[[1L]]
    if(hit<1L) return(list(valid=FALSE,method="ellipsis_not_found"))
    pos <- pos+hit-1L+nchar(part)
  }
  list(valid=TRUE,method="ordered_ellipsis_fragments")
}

x <- read_csv(input,show_col_types=FALSE)
stopifnot(nrow(x)==235L,!anyDuplicated(x$record_id))

assess_row <- function(title,abstract,evidence){
  ev <- strsplit(ifelse(is.na(evidence),"",evidence),"||",fixed=TRUE)[[1L]]
  ev <- trimws(ev); ev <- ev[nzchar(ev)]
  if(!length(ev)) return(c(valid="FALSE",method="missing"))
  z <- lapply(ev,function(e) ground_one(e,title,abstract))
  valid <- all(vapply(z,function(q)isTRUE(q$valid),logical(1)))
  methods <- paste(sort(unique(vapply(z,function(q)q$method,character(1)))),collapse=";")
  c(valid=as.character(valid),method=methods)
}
z <- t(mapply(assess_row,x$title,x$abstract,x$luna_evidence,SIMPLIFY=TRUE))
x$revalidated_grounded <- z[,"valid"]=="TRUE"
x$grounding_validation_method <- z[,"method"]
x$has_ellipsis <- grepl("...|\\u2026",x$luna_evidence,fixed=FALSE)

write_csv(x,file.path(out_dir,"grounding_revalidation.csv"),na="")
write_csv(x |> filter(revalidated_grounded),file.path(out_dir,"newly_valid_grounding.csv"),na="")
write_csv(x |> filter(!revalidated_grounded),file.path(out_dir,"still_unvalidated_grounding.csv"),na="")

summary <- list(
  records=nrow(x),
  revalidated_n=sum(x$revalidated_grounded),
  still_unvalidated_n=sum(!x$revalidated_grounded),
  ellipsis_records_n=sum(x$has_ellipsis),
  ellipsis_revalidated_n=sum(x$has_ellipsis & x$revalidated_grounded),
  normalised_contiguous_records_n=sum(grepl("normalised_contiguous",x$grounding_validation_method,fixed=TRUE) & x$revalidated_grounded),
  ordered_ellipsis_records_n=sum(grepl("ordered_ellipsis_fragments",x$grounding_validation_method,fixed=TRUE) & x$revalidated_grounded)
)
write_json(summary,file.path(out_dir,"summary.json"),auto_unbox=TRUE,pretty=TRUE)
cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),"\n")
