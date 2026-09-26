#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(jsonlite)
  library(stringr)
  library(tibble)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL){
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

current_jsonl <- arg("--current-jsonl")
old_queue <- arg("--old-queue")
old_scores <- arg("--old-scores")
old_master <- arg("--old-master")
out_dir <- arg("--output-dir","outputs/workflow07_topic_recall_audit")

for(p in c(current_jsonl,old_queue,old_scores,old_master)){
  if(is.null(p)||!file.exists(p)) stop("Required input missing: ",p)
}
dir.create(out_dir,recursive=TRUE,showWarnings=FALSE)

norm_doi <- function(x){
  x <- tolower(trimws(ifelse(is.na(x),"",as.character(x))))
  x <- sub("^https?://(dx\\.)?doi\\.org/","",x,perl=TRUE)
  x <- sub("^doi:\\s*","",x,perl=TRUE)
  x <- sub("[ .;,]+$","",x,perl=TRUE)
  x
}
norm_title <- function(x){
  x <- iconv(ifelse(is.na(x),"",as.character(x)),to="ASCII//TRANSLIT")
  x[is.na(x)] <- ""
  x <- tolower(x)
  x <- gsub("[^a-z0-9]+"," ",x,perl=TRUE)
  trimws(gsub("\\s+"," ",x,perl=TRUE))
}
norm_lens <- function(x){
  x <- trimws(ifelse(is.na(x),"",as.character(x)))
  x <- sub("^lens:","",x,ignore.case=TRUE)
  x
}
resolve_col <- function(nms,candidates,pattern=NULL){
  norm <- function(x) gsub("[^a-z0-9]","",tolower(x))
  map <- setNames(nms,norm(nms))
  for(c in candidates){
    k <- norm(c)
    if(k %in% names(map)) return(unname(map[[k]]))
  }
  if(!is.null(pattern)){
    hit <- grep(pattern,nms,ignore.case=TRUE,value=TRUE,perl=TRUE)
    if(length(hit)) return(hit[[1]])
  }
  NA_character_
}

# Current authoritative Workflow 04 inclusion set.
lines <- readLines(current_jsonl,warn=FALSE,encoding="UTF-8")
if(length(lines)!=19407L) stop("Expected 19,407 current included canonical records, found ",length(lines))
cur_list <- lapply(lines,function(z) fromJSON(z,simplifyVector=FALSE))
current <- bind_rows(lapply(cur_list,function(r){
  can <- if(is.null(r$canonical)) list() else r$canonical
  ident <- if(is.null(r$identity)) list() else r$identity
  refs <- unlist(if(is.null(r$manifestation_refs)) list() else r$manifestation_refs,use.names=FALSE)
  lens_refs <- refs[grepl("^lens:",refs,ignore.case=TRUE)]
  tibble(
    current_record_id=as.character(if(is.null(ident$record_id)) "" else ident$record_id),
    title=as.character(if(is.null(can$title)) "" else can$title),
    abstract=as.character(if(is.null(can$abstract)) "" else can$abstract),
    doi=as.character(if(is.null(can$doi)) "" else can$doi),
    year=as.character(if(is.null(can$year)) "" else can$year),
    lens_ids=paste(sort(unique(norm_lens(lens_refs))),collapse="; ")
  )
}))
if(nrow(current)!=19407L||anyDuplicated(current$current_record_id)) stop("Current canonical identity validation failed")
current <- current |>
  mutate(doi_norm=norm_doi(doi),title_norm=norm_title(title))

queue <- read_csv(old_queue,show_col_types=FALSE,col_types=cols(.default=col_character()))
scores <- read_csv(old_scores,show_col_types=FALSE,col_types=cols(.default=col_character()))
master <- read_csv(old_master,show_col_types=FALSE,col_types=cols(.default=col_character()))

if(nrow(queue)!=13426L||anyDuplicated(queue$record_id)) stop("Expected 13,426 unique old topic queue records")
if(anyDuplicated(scores[c("record_id","path_id")])) stop("Duplicate old record/path scores")

rid_col <- resolve_col(names(master),c("record_id","record id","id"))
doi_col <- resolve_col(names(master),c("doi","DOI"),"doi")
title_col <- resolve_col(names(master),c("title","document title","article title"),"title")
lens_col <- resolve_col(names(master),c("lens_id","lens id","lensid"),"lens.*id")
year_col <- resolve_col(names(master),c("year","publication_year","publication year"),"year")
if(is.na(rid_col)||is.na(title_col)) stop("Could not resolve old master record_id/title columns")

old_meta <- master |>
  transmute(
    old_record_id=as.character(.data[[rid_col]]),
    old_master_title=as.character(.data[[title_col]]),
    old_doi=if(!is.na(doi_col)) as.character(.data[[doi_col]]) else "",
    old_lens_id=if(!is.na(lens_col)) as.character(.data[[lens_col]]) else "",
    old_year=if(!is.na(year_col)) as.character(.data[[year_col]]) else ""
  ) |>
  distinct(old_record_id,.keep_all=TRUE)

old <- queue |>
  transmute(old_record_id=as.character(record_id),old_title=as.character(title),old_abstract=as.character(abstract)) |>
  left_join(old_meta,by="old_record_id") |>
  mutate(
    old_title_effective=coalesce(na_if(old_title,""),old_master_title,""),
    doi_norm=norm_doi(old_doi),
    title_norm=norm_title(old_title_effective),
    lens_norm=norm_lens(old_lens_id)
  )

# Long current Lens manifestation index.
current_lens <- current |>
  select(current_record_id,lens_ids) |>
  tidyr::separate_rows(lens_ids,sep=";\\s*") |>
  mutate(lens_norm=norm_lens(lens_ids)) |>
  filter(nzchar(lens_norm)) |>
  distinct(current_record_id,lens_norm)

safe_unique_match <- function(old_df,current_df,key_old,key_cur,method,used_current,used_old){
  o <- old_df |> filter(!(old_record_id %in% used_old),nzchar(.data[[key_old]]))
  c <- current_df |> filter(!(current_record_id %in% used_current),nzchar(.data[[key_cur]]))
  oc <- o |> count(.data[[key_old]],name="old_n") |> filter(old_n==1)
  cc <- c |> count(.data[[key_cur]],name="cur_n") |> filter(cur_n==1)
  o2 <- o |> inner_join(oc,by=setNames(key_old,key_old))
  c2 <- c |> inner_join(cc,by=setNames(key_cur,key_cur))
  names(o2)[names(o2)==key_old] <- "match_key"
  names(c2)[names(c2)==key_cur] <- "match_key"
  o2 |>
    inner_join(c2 |> select(current_record_id,match_key),by="match_key") |>
    transmute(old_record_id,current_record_id,match_method=method,match_key)
}

matches <- tibble(old_record_id=character(),current_record_id=character(),match_method=character(),match_key=character())
used_o <- character(); used_c <- character()

# 1. Exact Lens manifestation ID where available.
m <- safe_unique_match(old,current_lens,"lens_norm","lens_norm","lens_id",used_c,used_o)
matches <- bind_rows(matches,m); used_o <- c(used_o,m$old_record_id); used_c <- c(used_c,m$current_record_id)

# 2. Exact normalised DOI.
m <- safe_unique_match(old,current,"doi_norm","doi_norm","doi",used_c,used_o)
matches <- bind_rows(matches,m); used_o <- c(used_o,m$old_record_id); used_c <- c(used_c,m$current_record_id)

# 3. Exact normalised title, unique-to-unique.
m <- safe_unique_match(old,current,"title_norm","title_norm","title_exact",used_c,used_o)
matches <- bind_rows(matches,m); used_o <- c(used_o,m$old_record_id); used_c <- c(used_c,m$current_record_id)

if(anyDuplicated(matches$old_record_id)||anyDuplicated(matches$current_record_id)) stop("Recall mapping is not one-to-one")

# Recalled scores retain the original three-Luna vote/star fields unchanged.
recalled_scores <- scores |>
  rename(old_record_id=record_id) |>
  inner_join(matches,by="old_record_id") |>
  relocate(current_record_id,old_record_id,match_method,match_key)

current_recall <- current |>
  left_join(matches |> select(current_record_id,old_record_id,match_method,match_key),by="current_record_id") |>
  mutate(topic_recalled=!is.na(old_record_id))

fresh_queue <- current_recall |>
  filter(!topic_recalled) |>
  transmute(record_id=current_record_id,title,abstract,doi,year)

old_not_current <- old |>
  filter(!(old_record_id %in% matches$old_record_id)) |>
  select(old_record_id,old_title_effective,old_doi,old_lens_id,old_year)

method_counts <- matches |> count(match_method,name="n") |> arrange(desc(n))
summary <- list(
  current_included_records=nrow(current),
  old_three_luna_records=nrow(old),
  recalled_records=nrow(matches),
  fresh_coding_records=nrow(fresh_queue),
  old_topic_records_not_in_current=nrow(old_not_current),
  recall_fraction=round(nrow(matches)/nrow(current),6),
  matches_by_method=setNames(as.list(method_counts$n),method_counts$match_method),
  recalled_record_pathway_scores=nrow(recalled_scores),
  old_score_rows=nrow(scores),
  old_confidence_counts=as.list(table(scores$stars,useNA="ifany")),
  safety_rule="Only one-to-one exact Lens manifestation, normalised DOI, or exact normalised title matches are reused. No fuzzy matches."
)

write_csv(matches,file.path(out_dir,"topic_recall_crosswalk.csv"),na="")
write_csv(current_recall,file.path(out_dir,"current_topic_recall_status.csv"),na="")
write_csv(recalled_scores,file.path(out_dir,"recalled_three_luna_pathway_scores.csv"),na="")
write_csv(fresh_queue,file.path(out_dir,"fresh_topic_coding_queue.csv"),na="")
write_csv(old_not_current,file.path(out_dir,"old_topic_records_not_current.csv"),na="")
write_csv(method_counts,file.path(out_dir,"match_method_counts.csv"),na="")
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),file.path(out_dir,"summary.json"))

cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),"\n")
