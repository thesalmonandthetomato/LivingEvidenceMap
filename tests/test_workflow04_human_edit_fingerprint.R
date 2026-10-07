suppressPackageStartupMessages({
  library(jsonlite)
  library(digest)
})

td <- tempfile("w04-human-edit-fingerprint-")
dir.create(td, recursive=TRUE)

write_jsonl <- function(xs,path){
  con <- file(path,"wt",encoding="UTF-8"); on.exit(close(con))
  for(x in xs) writeLines(toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)
}
read_jsonl <- function(path){
  x <- readLines(path,warn=FALSE,encoding="UTF-8")
  x <- x[nzchar(trimws(x))]
  lapply(x,function(z)fromJSON(z,simplifyVector=FALSE))
}
fp <- function(r){
  c <- r$canonical
  v <- list(
    title=c$title,
    abstract=c$abstract,
    keywords=c$keywords,
    journal_source_title=c$journal,
    affiliations=c$affiliations,
    funding=c$funding
  )
  digest(toJSON(v,auto_unbox=TRUE,null="null",na="null",digits=NA),algo="sha256",serialize=FALSE)
}

canonical <- list(list(
  identity=list(record_id="work-test"),
  canonical=list(
    title="Test title",
    abstract="Original abstract",
    keywords="alpha",
    journal="Journal A",
    affiliations="Affiliation",
    funding="Funding"
  )
))
old_fp <- fp(canonical[[1L]])
layer <- list(list(
  record_id="work-test",
  screening=list(
    decision="uncertain",
    screening_input_sha256=old_fp,
    input_title_present=TRUE,
    input_abstract_present=TRUE
  )
))
decisions <- list(list(
  record_id="work-test",
  decision="retain",
  rationale="Human decision after correcting abstract",
  reviewer="reviewer",
  adjudicated_at_utc="2026-10-07T00:00:00Z",
  edited_abstract="Corrected abstract",
  abstract_edit_reviewer="reviewer",
  abstract_edit_saved_at_utc="2026-10-07T00:00:00Z",
  abstract_edit_id="edit-1"
))
summary <- list(
  mode="update",
  workflow03_excluded=0L,
  reused_records=0L,
  newly_screened_records=1L,
  new_record_ids=0L,
  changed_screening_input=0L
)

canonical_path <- file.path(td,"canonical.jsonl")
layer_path <- file.path(td,"layer.jsonl")
decisions_path <- file.path(td,"decisions.jsonl")
summary_path <- file.path(td,"summary.json")
out_dir <- file.path(td,"resolved")
write_jsonl(canonical,canonical_path)
write_jsonl(layer,layer_path)
write_jsonl(decisions,decisions_path)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),summary_path)

status <- system2(
  file.path(R.home("bin"),"Rscript"),
  c(
    "scripts/updater/workflow_04_apply_human_resolution.R",
    "--source-layer",layer_path,
    "--canonical",canonical_path,
    "--decisions",decisions_path,
    "--source-summary",summary_path,
    "--output-dir",out_dir
  ),
  stdout=FALSE,stderr=FALSE
)
stopifnot(status==0L)

final_can <- read_jsonl(file.path(out_dir,"workflow04_included_canonical.jsonl"))[[1L]]
final_layer <- read_jsonl(file.path(out_dir,"workflow04_final_screening_layer.jsonl"))[[1L]]
corrections <- read_jsonl(file.path(out_dir,"workflow04_human_abstract_corrections.jsonl"))
stopifnot(
  identical(as.character(final_can$canonical$abstract),"Corrected abstract"),
  !identical(as.character(final_layer$screening$screening_input_sha256),old_fp),
  identical(as.character(final_layer$screening$screening_input_sha256),fp(final_can)),
  identical(as.character(final_layer$screening$human_edit_fingerprint_refresh$reason),"human_w04_abstract_edit"),
  length(corrections)==1L,
  identical(as.character(corrections[[1L]]$record_id_at_edit),"work-test"),
  identical(as.character(corrections[[1L]]$title),"Test title"),
  identical(as.character(corrections[[1L]]$edited_abstract),"Corrected abstract")
)

# Simulate the next update with unchanged post-human bibliographic content.
w03 <- list(list(record_id="work-test",publication_status=list(exclude_from_workflow04=FALSE)))
w03_path <- file.path(td,"w03.jsonl")
prior_can_path <- file.path(td,"prior_can.jsonl")
next_out <- file.path(td,"next")
write_jsonl(w03,w03_path)
write_jsonl(list(final_can),prior_can_path)

status <- system2(
  file.path(R.home("bin"),"Rscript"),
  c(
    "scripts/updater/workflow_04_prepare_incremental.R",
    "--canonical",prior_can_path,
    "--workflow03-status",w03_path,
    "--prior-workflow04",file.path(out_dir,"workflow04_final_screening_layer.jsonl"),
    "--prior-canonical",prior_can_path,
    "--output-dir",next_out
  ),
  stdout=FALSE,stderr=FALSE
)
stopifnot(status==0L)

queued <- trimws(readLines(file.path(next_out,"screen_queue_record_ids.txt"),warn=FALSE))
reused <- trimws(readLines(file.path(next_out,"reused_record_ids.txt"),warn=FALSE))
manifest <- fromJSON(file.path(next_out,"prepare_manifest.json"),simplifyVector=FALSE)

stopifnot(
  !("work-test" %in% queued),
  "work-test" %in% reused,
  as.integer(manifest$changed_screening_input)==0L,
  as.integer(manifest$changed_screening_input_reused)==0L
)

cat("PASS: W04 human abstract edit refreshes fingerprint and is reusable unchanged next update\n")
