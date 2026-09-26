#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(jsonlite)
})

source("R/species_detect.R")
source("R/species_filter.R")
source("R/species_assign.R")
source("R/species_annotation.R")

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL){
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
records_path <- arg("--records")
old_path <- arg("--old")
dict_path <- arg("--dictionary","config/species_dictionary.csv")
out_dir <- arg("--output-dir","outputs/workflow05_species_only_rerun")
dir.create(out_dir,recursive=TRUE,showWarnings=FALSE)

if(is.null(records_path)||!file.exists(records_path)) stop("--records is required")
if(is.null(old_path)||!file.exists(old_path)) stop("--old is required")

records <- read_csv(records_path,show_col_types=FALSE)
old <- read_csv(old_path,show_col_types=FALSE)
dictionary <- read_csv(dict_path,show_col_types=FALSE)

stopifnot(
  nrow(records)==19407L,
  !anyDuplicated(records$record_id),
  !anyDuplicated(old$record_id)
)

eligible_ids <- c(
  "SAL_SALAR","ONC_MYKISS","ONC_TSHAWYTSCHA","ONC_KISUTCH",
  "ONC_NERKA","ONC_KETA","ONC_GORBUSCHA","ONC_MASOU","UNSPEC_SALMON"
)
stopifnot(all(dictionary$species_id %in% eligible_ids))
stopifnot(all(dictionary$is_farmed_candidate %in% TRUE))

species <- annotate_species(
  records |> select(record_sequence,record_id,title,abstract),
  dictionary,
  progress=TRUE
)
if(nrow(species$failures)) stop(sprintf("Species rerun had %d technical failures",nrow(species$failures)))

write_csv(species$species_mentions,file.path(out_dir,"species_mentions.csv"),na="")
write_csv(species$species_assignments,file.path(out_dir,"species_assignments.csv"),na="")

new_summary <- species$species_assignments |>
  mutate(record_id=as.character(record_id)) |>
  group_by(record_id) |>
  summarise(
    deterministic_species=paste(sort(unique(stats::na.omit(farmed_species))),collapse="; "),
    deterministic_species_ids=paste(sort(unique(stats::na.omit(farmed_species_id))),collapse="; "),
    species_review_required=any(review_required %in% TRUE),
    species_assignment_reason=paste(sort(unique(stats::na.omit(assignment_reason))),collapse=" | "),
    .groups="drop"
  )

new_summary <- records |>
  select(record_sequence,record_id,title,abstract) |>
  left_join(new_summary,by="record_id") |>
  mutate(
    deterministic_species=coalesce(deterministic_species,""),
    deterministic_species_ids=coalesce(deterministic_species_ids,""),
    species_review_required=coalesce(species_review_required,FALSE),
    species_assignment_reason=coalesce(species_assignment_reason,"")
  )
write_csv(new_summary,file.path(out_dir,"deterministic_species_summary.csv"),na="")

norm_set <- function(x){
  x <- as.character(x); x[is.na(x)] <- ""
  vapply(strsplit(x,";",fixed=TRUE),function(z){
    z <- trimws(z); z <- z[nzchar(z)]
    paste(sort(unique(z)),collapse="; ")
  },character(1))
}

delta <- old |>
  transmute(
    record_id=as.character(record_id),
    old_species_ids=norm_set(deterministic_species_ids),
    old_review=species_review_required %in% TRUE
  ) |>
  inner_join(
    new_summary |>
      transmute(
        record_id=as.character(record_id),
        new_species_ids=norm_set(deterministic_species_ids),
        new_review=species_review_required %in% TRUE,
        title,abstract
      ),
    by="record_id"
  ) |>
  mutate(
    assignment_changed=old_species_ids!=new_species_ids,
    review_changed=old_review!=new_review
  )

stopifnot(nrow(delta)==19407L)
write_csv(delta,file.path(out_dir,"species_delta_all.csv"),na="")
write_csv(delta |> filter(assignment_changed|review_changed),file.path(out_dir,"species_delta_changed.csv"),na="")

counts <- species$species_assignments |>
  filter(!is.na(farmed_species_id), farmed_species_id %in% eligible_ids) |>
  distinct(record_id,farmed_species_id,farmed_species) |>
  count(farmed_species_id,farmed_species,name="records") |>
  arrange(desc(records),farmed_species_id)
write_csv(counts,file.path(out_dir,"species_record_counts.csv"),na="")

mention_counts <- species$species_mentions |>
  filter(species_id %in% eligible_ids) |>
  count(species_id,matched_term,sort=TRUE,name="mentions")
write_csv(mention_counts,file.path(out_dir,"species_term_counts.csv"),na="")

summary <- list(
  records=nrow(records),
  dictionary_rows=nrow(dictionary),
  eligible_species_codes=eligible_ids,
  species_mentions=nrow(species$species_mentions),
  assignment_rows=nrow(species$species_assignments),
  review_records=sum(new_summary$species_review_required),
  changed_assignment_records=sum(delta$assignment_changed),
  changed_review_records=sum(delta$review_changed),
  unchanged_records=sum(!delta$assignment_changed & !delta$review_changed),
  unspecified_records=sum(grepl("(^|; )UNSPEC_SALMON($|; )",new_summary$deterministic_species_ids)),
  named_species_records=sum(grepl("SAL_SALAR|ONC_",new_summary$deterministic_species_ids))
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),file.path(out_dir,"summary.json"))

cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),"
")
print(counts,n=Inf)
