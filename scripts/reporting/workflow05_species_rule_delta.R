#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(dplyr);library(readr);library(jsonlite);library(fs)})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(f,d=NULL){i<-match(f,args);if(is.na(i))d else args[[i+1L]]}
old_path<-arg("--old")
new_path<-arg("--new")
out<-arg("--output-dir","outputs/workflow05_species_delta")
dir_create(out,recurse=TRUE)

old<-read_csv(old_path,show_col_types=FALSE)
new<-read_csv(new_path,show_col_types=FALSE)
stopifnot(nrow(old)==19407L,nrow(new)==19407L,!anyDuplicated(old$record_id),!anyDuplicated(new$record_id))

norm<-function(x){
  x<-as.character(x);x[is.na(x)]<-""
  vapply(strsplit(x,";",fixed=TRUE),function(z){
    z<-trimws(z);z<-z[nzchar(z)]
    if(!length(z)) "" else paste(sort(unique(z)),collapse="; ")
  },character(1))
}

cmp<-old |>
  transmute(
    record_id,
    old_species_ids=norm(deterministic_species_ids),
    old_species=norm(deterministic_species),
    old_review=species_review_required
  ) |>
  inner_join(
    new |>
      transmute(
        record_id,
        new_species_ids=norm(deterministic_species_ids),
        new_species=norm(deterministic_species),
        new_review=species_review_required
      ),
    by="record_id"
  ) |>
  mutate(
    assignment_changed=old_species_ids!=new_species_ids,
    review_changed=old_review!=new_review
  )

write_csv(cmp,file.path(out,"species_delta_all.csv"))
write_csv(filter(cmp,assignment_changed|review_changed),file.path(out,"species_delta_changed.csv"))

summary<-list(
  records=19407L,
  assignment_changed=sum(cmp$assignment_changed),
  review_flag_changed=sum(cmp$review_changed),
  changed_any=sum(cmp$assignment_changed|cmp$review_changed),
  old_review_records=sum(cmp$old_review),
  new_review_records=sum(cmp$new_review),
  old_unspecified=sum(grepl("(^|; )UNSPEC_SALMON(; |$)",cmp$old_species_ids)),
  new_unspecified=sum(grepl("(^|; )UNSPEC_SALMON(; |$)",cmp$new_species_ids))
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),file.path(out,"species_delta_summary.json"))
print(summary)
