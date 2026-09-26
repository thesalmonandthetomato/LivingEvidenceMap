#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(jsonlite)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL){
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

mode <- arg("--mode","recall_uncoded")
fresh_scores_path <- arg("--fresh-scores")
fresh_records_path <- arg("--fresh-record-results")
ontology_path <- arg("--ontology","data/reference/topic_ontology_v3_6.csv")
out_dir <- arg("--output-dir","outputs/workflow07_topic_final")
recalled_scores_path <- arg("--recalled-scores")
recall_status_path <- arg("--recall-status")

if(is.null(fresh_scores_path) || !file.exists(fresh_scores_path)) stop("--fresh-scores is required")
if(is.null(fresh_records_path) || !file.exists(fresh_records_path)) stop("--fresh-record-results is required")
if(!file.exists(ontology_path)) stop("Ontology not found")
dir.create(out_dir,recursive=TRUE,showWarnings=FALSE)

ontology <- read_csv(ontology_path,show_col_types=FALSE)
fresh <- read_csv(fresh_scores_path,show_col_types=FALSE)
fresh_records <- read_csv(fresh_records_path,show_col_types=FALSE)

required_score <- c("record_id","path_id","hierarchy_path","confidence_n","confidence_label","stars",
                    "role_a","role_b","role_c","reason_a","reason_b","reason_c")
miss <- setdiff(required_score,names(fresh))
if(length(miss)) stop("Fresh score file missing columns: ",paste(miss,collapse=", "))

fresh <- fresh |>
  mutate(
    record_id=as.character(record_id),
    path_id=as.character(path_id),
    topic_source="fresh_workflow07"
  )

if(anyDuplicated(fresh[,c("record_id","path_id")])) stop("Duplicate fresh record/path pairs")
if(any(!(fresh$path_id %in% ontology$path_id))) stop("Fresh scores contain unknown ontology path IDs")
if(any(!(fresh$confidence_n %in% 1:3))) stop("Fresh confidence_n outside 1:3")
if(any(nchar(fresh$stars) != fresh$confidence_n)) stop("Fresh star labels do not match confidence_n")

fresh_pass_ids <- fresh_records |>
  transmute(record_id=as.character(record_id),pass=as.character(pass)) |>
  distinct()
pass_counts <- fresh_pass_ids |> count(record_id,name="passes")
if(any(pass_counts$passes != 3L)) stop("Not every fresh-coded record has exactly three pass-level results")
fresh_ids <- sort(unique(fresh_pass_ids$record_id))

if(mode=="recall_uncoded"){
  if(is.null(recalled_scores_path)||!file.exists(recalled_scores_path)) stop("--recalled-scores required in recall_uncoded mode")
  if(is.null(recall_status_path)||!file.exists(recall_status_path)) stop("--recall-status required in recall_uncoded mode")

  recalled <- read_csv(recalled_scores_path,show_col_types=FALSE) |>
    rename(record_id=current_record_id) |>
    mutate(
      record_id=as.character(record_id),
      path_id=as.character(path_id),
      topic_source="recalled_three_luna"
    )

  required_recalled <- c(required_score,"old_record_id","match_method","match_key")
  miss2 <- setdiff(required_recalled,names(recalled))
  if(length(miss2)) stop("Recalled score file missing columns: ",paste(miss2,collapse=", "))
  if(anyDuplicated(recalled[,c("record_id","path_id")])) stop("Duplicate recalled record/path pairs")
  if(any(!(recalled$path_id %in% ontology$path_id))) stop("Recalled scores contain unknown ontology path IDs")
  if(any(!(recalled$confidence_n %in% 1:3))) stop("Recalled confidence_n outside 1:3")
  if(any(nchar(recalled$stars) != recalled$confidence_n)) stop("Recalled star labels do not match confidence_n")

  status <- read_csv(recall_status_path,show_col_types=FALSE) |>
    mutate(
      current_record_id=as.character(current_record_id),
      topic_recalled=as.logical(topic_recalled)
    )
  stopifnot(nrow(status)==19407L,!anyDuplicated(status$current_record_id))
  recalled_ids <- sort(status$current_record_id[status$topic_recalled %in% TRUE])
  expected_fresh_ids <- sort(status$current_record_id[!(status$topic_recalled %in% TRUE)])

  if(length(recalled_ids)!=12297L) stop("Expected 12,297 recalled records, found ",length(recalled_ids))
  if(length(expected_fresh_ids)!=7110L) stop("Expected 7,110 fresh records, found ",length(expected_fresh_ids))
  if(!identical(fresh_ids,expected_fresh_ids)) stop("Fresh production record IDs do not exactly equal the 7,110 uncoded recall-audit IDs")
  if(any(recalled$record_id %in% fresh_ids)) stop("Recalled and fresh score sets overlap")

  final_scores <- bind_rows(
    recalled |> select(all_of(required_score),topic_source,old_record_id,match_method,match_key),
    fresh |> mutate(old_record_id=NA_character_,match_method=NA_character_,match_key=NA_character_) |>
      select(all_of(required_score),topic_source,old_record_id,match_method,match_key)
  ) |>
    arrange(record_id,path_id)

  all_ids <- status$current_record_id
  source_map <- tibble(
    record_id=all_ids,
    topic_source=ifelse(status$topic_recalled,"recalled_three_luna","fresh_workflow07")
  )
} else if(mode=="workflow06_all"){
  final_scores <- fresh |> 
    mutate(old_record_id=NA_character_,match_method=NA_character_,match_key=NA_character_) |>
    select(all_of(required_score),topic_source,old_record_id,match_method,match_key) |>
    arrange(record_id,path_id)
  all_ids <- fresh_ids
  source_map <- tibble(record_id=all_ids,topic_source="fresh_workflow07")
} else {
  stop("Unknown mode: ",mode)
}

if(anyDuplicated(final_scores[,c("record_id","path_id")])) stop("Duplicate final record/path pairs")
if(any(!(final_scores$path_id %in% ontology$path_id))) stop("Final scores contain unknown path IDs")

counts <- final_scores |>
  group_by(record_id) |>
  summarise(
    retained_pathways=n(),
    one_star=sum(confidence_n==1L),
    two_star=sum(confidence_n==2L),
    three_star=sum(confidence_n==3L),
    .groups="drop"
  )

record_summary <- source_map |>
  left_join(counts,by="record_id") |>
  mutate(across(c(retained_pathways,one_star,two_star,three_star),~coalesce(.x,0L))) |>
  arrange(record_id)

if(mode=="recall_uncoded" && nrow(record_summary)!=19407L) stop("Final record summary is not 19,407 records")
if(anyDuplicated(record_summary$record_id)) stop("Duplicate final record IDs")

write_csv(final_scores,file.path(out_dir,"workflow07_topic_pathway_scores.csv"),na="")
write_csv(record_summary,file.path(out_dir,"workflow07_topic_record_summary.csv"),na="")
write_csv(record_summary |> filter(retained_pathways==0L),file.path(out_dir,"workflow07_zero_code_records.csv"),na="")

conf <- final_scores |> count(confidence_n,stars,name="n") |> arrange(confidence_n)
write_csv(conf,file.path(out_dir,"workflow07_star_counts.csv"),na="")

summary <- list(
  mode=mode,
  records=nrow(record_summary),
  recalled_records=sum(record_summary$topic_source=="recalled_three_luna"),
  fresh_records=sum(record_summary$topic_source=="fresh_workflow07"),
  retained_record_pathways=nrow(final_scores),
  one_star=sum(final_scores$confidence_n==1L),
  two_star=sum(final_scores$confidence_n==2L),
  three_star=sum(final_scores$confidence_n==3L),
  zero_code_records=sum(record_summary$retained_pathways==0L),
  ontology_sha256=digest(file=ontology_path,algo="sha256",serialize=FALSE),
  fresh_scores_sha256=digest(file=fresh_scores_path,algo="sha256",serialize=FALSE),
  recalled_scores_sha256=if(mode=="recall_uncoded") digest(file=recalled_scores_path,algo="sha256",serialize=FALSE) else NULL
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null"),file.path(out_dir,"workflow07_final_summary.json"))
writeLines("PASS",file.path(out_dir,"WORKFLOW07_HANDOFF_PASS.ok"))
cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null"),"\n")
