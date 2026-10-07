suppressPackageStartupMessages({
  library(readr)
  library(jsonlite)
  library(digest)
})

td <- tempfile("w07-changed-input-")
dir.create(td, recursive=TRUE)

ontology <- file.path(td,"ontology.csv")
prompt <- file.path(td,"prompt.txt")
writeLines("path_id,hierarchy_path\np1,Topic 1",ontology)
writeLines("test prompt",prompt)

fp <- function(t,a) digest(
  toJSON(list(title=t,abstract=a),auto_unbox=TRUE,null="null",na="null"),
  algo="sha256",serialize=FALSE
)

prior_records <- data.frame(
  record_id=c("work-unchanged","work-changed"),
  title=c("Title A","Title B"),
  abstract=c("Abstract A","Old abstract"),
  topic_input_sha256=c(fp("Title A","Abstract A"),fp("Title B","Old abstract")),
  stringsAsFactors=FALSE
)
prior_scores <- data.frame(
  record_id=c("work-unchanged","work-changed"),
  path_id=c("p1","p1"),
  hierarchy_path=c("Topic 1","Topic 1"),
  confidence_n=c(3L,3L),
  stringsAsFactors=FALSE
)
current <- data.frame(
  record_id=c("work-unchanged","work-changed"),
  title=c("Title A","Title B"),
  abstract=c("Abstract A","Changed abstract"),
  stringsAsFactors=FALSE
)

prior_records_path <- file.path(td,"prior_records.csv")
prior_scores_path <- file.path(td,"prior_scores.csv")
current_path <- file.path(td,"current.csv")
manifest_path <- file.path(td,"prior_manifest.json")
out <- file.path(td,"out")
write_csv(prior_records,prior_records_path,na="")
write_csv(prior_scores,prior_scores_path,na="")
write_csv(current,current_path,na="")
write_json(list(
  ontology_sha256=digest(file=ontology,algo="sha256",serialize=FALSE),
  prompt_sha256=digest(file=prompt,algo="sha256",serialize=FALSE)
),manifest_path,auto_unbox=TRUE,pretty=TRUE)

status <- system2(
  file.path(R.home("bin"),"Rscript"),
  c(
    "scripts/updater/workflow_07_prepare_incremental.R",
    "--current",current_path,
    "--prior-records",prior_records_path,
    "--prior-scores",prior_scores_path,
    "--prior-manifest",manifest_path,
    "--ontology",ontology,
    "--prompt",prompt,
    "--output-dir",out
  ),
  stdout=FALSE,stderr=FALSE
)
stopifnot(status==0L)

queue <- read_csv(file.path(out,"topic_screen_queue.csv"),show_col_types=FALSE)
reuse <- read_csv(file.path(out,"reused_topic_records.csv"),show_col_types=FALSE)
qm <- read_csv(file.path(out,"topic_screen_queue_manifest.csv"),show_col_types=FALSE)
m <- fromJSON(file.path(out,"prepare_manifest.json"),simplifyVector=FALSE)

stopifnot(
  identical(as.character(queue$record_id),"work-changed"),
  identical(as.character(reuse$record_id),"work-unchanged"),
  identical(as.character(qm$queue_reason),"title_or_abstract_changed"),
  as.integer(m$changed_title_abstract)==1L,
  as.integer(m$existing_records_refreshed)==1L,
  as.integer(m$changed_title_abstract_reused)==0L,
  identical(as.character(m$scientific_input_refresh_rule),"any_title_or_abstract_fingerprint_change"),
  identical(as.character(m$reuse_basis),"existing_record_id_reused_only_when_topic_input_sha256_is_unchanged")
)

cat("PASS: W07 reuses only unchanged title/abstract fingerprints\n")
