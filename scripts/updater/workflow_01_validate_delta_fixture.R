#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(data.table)
  library(jsonlite)
  library(digest)
})

root <- "outputs/workflow01_delta_fixture"
unlink(root,recursive=TRUE,force=TRUE)
prev <- file.path(root,"previous")
cur_seed <- file.path(root,"current_seed")
cur_final <- file.path(root,"current_final")
target <- file.path(root,"target")
delta <- file.path(root,"delta")
replayed <- file.path(root,"replayed")
for(d in c(
  file.path(prev,"workflow01_seed"),
  file.path(prev,"workflow01_full_five_source"),
  file.path(prev,"canonical"),
  cur_seed,cur_final,target,delta,replayed
)) dir.create(d,recursive=TRUE,showWarnings=FALSE)

write_jsonl <- function(objs,path){
  con <- file(path,"wt",encoding="UTF-8")
  on.exit(close(con),add=TRUE)
  for(z in objs) writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null"),con,useBytes=TRUE)
}
sha <- function(path) digest(file=path,algo="sha256",serialize=FALSE)

records <- list(
  list(source="lens",source_record_id="L1",title="Alpha",abstract="A",doi="10.1/a"),
  list(source="lens",source_record_id="L2",title="Beta",abstract="B",doi="10.1/b")
)
write_jsonl(records,file.path(prev,"workflow01_seed","lens_records_for_deduplication.jsonl"))
for(src in c("scopus","openalex","agricola","wos")) {
  file.create(file.path(prev,"workflow01_seed",paste0(src,"_records_for_deduplication.jsonl")))
}
file.copy(file.path(prev,"workflow01_seed","lens_records_for_deduplication.jsonl"),
          file.path(cur_seed,"lens_records_for_deduplication.jsonl"))
for(src in c("scopus","openalex","agricola","wos")) {
  file.copy(
    file.path(prev,"workflow01_seed",paste0(src,"_records_for_deduplication.jsonl")),
    file.path(cur_seed,paste0(src,"_records_for_deduplication.jsonl"))
  )
}

pairs <- data.table(
  pair_key="1::2",record_i=1L,record_j=2L,
  rescored_classification="not_duplicate",rescored_rule="fixture",
  review_route="non_duplicate"
)
fwrite(pairs,file.path(prev,"workflow01_full_five_source","final_pair_decisions.csv"))
fwrite(pairs,file.path(cur_final,"final_pair_decisions.csv"))

cmap <- data.table(
  idx=1:2,source=c("lens","lens"),source_record_id=c("L1","L2"),
  cluster_id=c("work-a","work-b"),cluster_size=1L,cluster_id_origin="preserved"
)
fwrite(cmap,file.path(prev,"workflow01_full_five_source","manifestation_cluster_map.csv"))
fwrite(cmap,file.path(cur_final,"manifestation_cluster_map.csv"))
fwrite(data.table(
  retired_cluster_id=character(),surviving_cluster_id=character(),
  reason=character(),workflow01_output_cluster_member_count=integer()
),file.path(cur_final,"cluster_id_aliases.csv"))
file.create(file.path(prev,"workflow01_full_five_source","abstract_strip_actions.jsonl"))
file.create(file.path(cur_final,"abstract_strip_actions.jsonl"))
writeLines("{}",file.path(cur_final,"summary.json"))

base_records <- list(
  list(
    schema_version="living-evidence-map-canonical-v1",
    identity=list(record_id="work-a",record_id_type="deduplication_cluster_id"),
    canonical=list(title="Alpha",abstract="A",doi="10.1/a"),
    manifestations=list(list(source="lens",source_record_id="L1",title="Alpha",abstract="A",doi="10.1/a")),
    provenance=list(workflow01_run_id="old",generated_at_utc="2026-01-01T00:00:00Z",source_manifestation_count=1L)
  ),
  list(
    schema_version="living-evidence-map-canonical-v1",
    identity=list(record_id="work-b",record_id_type="deduplication_cluster_id"),
    canonical=list(title="Beta",abstract="B",doi="10.1/b"),
    manifestations=list(list(source="lens",source_record_id="L2",title="Beta",abstract="B",doi="10.1/b")),
    provenance=list(workflow01_run_id="old",generated_at_utc="2026-01-01T00:00:00Z",source_manifestation_count=1L)
  )
)
write_jsonl(base_records,file.path(prev,"canonical","records.jsonl"))

target_records <- base_records
target_records[[1]]$canonical$title <- "Alpha repaired"
target_records[[1]]$manifestations[[1]]$title <- "Alpha repaired"
for(i in seq_along(target_records)) {
  target_records[[i]]$provenance$workflow01_run_id <- NULL
  target_records[[i]]$provenance$generated_at_utc <- NULL
}
target_canonical <- file.path(target,"records.jsonl")
write_jsonl(target_records,target_canonical)

target_manifest <- list(
  schema="living-evidence-map-canonical-manifest-v1",
  canonical_schema_version="living-evidence-map-canonical-v1",
  workflow="01",github_run_id="fixture",
  records=2L,source_manifestations=2L,
  canonical_jsonl_sha256=sha(target_canonical),
  canonical_jsonl_bytes=unname(file.info(target_canonical)$size)
)
writeLines(toJSON(target_manifest,auto_unbox=TRUE,pretty=TRUE),
           file.path(target,"canonical_manifest.json"))

pointer <- list(
  status="published",state="final",github_run_id="baseline-fixture",
  zenodo_record_id="fixture",doi="fixture",manifest_sha256="fixture"
)
writeLines(toJSON(pointer,auto_unbox=TRUE,pretty=TRUE),file.path(root,"previous_pointer.json"))

cmd <- function(script,args){
  status <- system2("Rscript",c(script,args))
  if(!identical(status,0L)) stop(sprintf("%s failed with status %s",script,status),call.=FALSE)
}

cmd("scripts/updater/workflow_01_build_delta.R",c(
  "--previous-root",prev,
  "--current-seed-root",cur_seed,
  "--current-final-root",cur_final,
  "--current-canonical",target_canonical,
  "--current-canonical-manifest",file.path(target,"canonical_manifest.json"),
  "--previous-pointer",file.path(root,"previous_pointer.json"),
  "--output-dir",delta,
  "--run-id","fixture-delta"
))

dm <- fromJSON(file.path(delta,"delta_manifest.json"))
stopifnot(dm$delta$new_source_manifestations == 0L)
stopifnot(dm$delta$pair_decision_upserts == 0L)
stopifnot(dm$delta$cluster_map_upserts == 0L)
stopifnot(dm$delta$canonical_upserts == 1L)
stopifnot(dm$delta$canonical_retired_ids == 0L)

cmd("scripts/updater/workflow_01_replay_delta.R",c(
  "--previous-root",prev,
  "--delta-dir",delta,
  "--output-root",replayed
))

replayed_canonical <- file.path(replayed,"canonical","records.jsonl")
stopifnot(identical(sha(replayed_canonical),sha(target_canonical)))
stopifnot(
  identical(
    sha(file.path(replayed,"workflow01_full_five_source","final_pair_decisions.csv")),
    sha(file.path(prev,"workflow01_full_five_source","final_pair_decisions.csv"))
  )
)
stopifnot(
  identical(
    sha(file.path(replayed,"workflow01_full_five_source","manifestation_cluster_map.csv")),
    sha(file.path(prev,"workflow01_full_five_source","manifestation_cluster_map.csv"))
  )
)

cat("PASS: fast Workflow 01 delta/replay fixture\n")
