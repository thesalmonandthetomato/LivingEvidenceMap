#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(jsonlite)
  library(digest)
})

`%||%` <- function(x,y) if(is.null(x)) y else x
args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL) {
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
html_escape <- function(x) {
  x <- as.character(x %||% "")
  x <- gsub("&","&amp;",x,fixed=TRUE)
  x <- gsub("<","&lt;",x,fixed=TRUE)
  x <- gsub(">","&gt;",x,fixed=TRUE)
  x <- gsub('"',"&quot;",x,fixed=TRUE)
  x
}
rel_link <- function(path, root) {
  # HTML sits in internal/output_registry/archive/YYYY-MM-DD/.
  # Repository links are deliberately GitHub-relative, not public-site URLs.
  paste0("../../../../", path)
}
fmt_bytes <- function(n) {
  n <- suppressWarnings(as.numeric(n))
  if(is.na(n)) return("")
  units <- c("B","KB","MB","GB")
  i <- 1L
  while(n>=1024 && i<length(units)){n<-n/1024;i<-i+1L}
  sprintf(if(i==1L) "%.0f %s" else "%.1f %s",n,units[[i]])
}
file_row <- function(path, description, category) {
  if(!file.exists(path)) return(NULL)
  info <- file.info(path)
  list(
    category=category,
    path=path,
    description=description,
    format=toupper(sub("^.*\\.","",path)),
    bytes=as.numeric(info$size),
    sha256=digest(file=path,algo="sha256",serialize=FALSE)
  )
}

status_path <- arg("--status","docs/current_run/current_run_status.json")
flow_path <- arg("--flow","docs/reporting/workflow_09/flow_counts.json")
output_root <- arg("--output-root","internal/output_registry/archive")
w10_dir <- arg("--w10-dir","outputs/workflow10")

if(!file.exists(status_path)) stop("Current-run status not found",call.=FALSE)
status <- fromJSON(status_path,simplifyVector=FALSE)
search_date <- as.character(status$search$search_date %||% "")
if(!grepl("^\\d{4}-\\d{2}-\\d{2}$",search_date)) stop("Current run has no valid search date",call.=FALSE)

archive_dir <- file.path(output_root,search_date)
dir.create(archive_dir,recursive=TRUE,showWarnings=FALSE)

stage_desc <- c(
  W00="Database-search archives and search provenance",
  W01="Deduplication state and canonical record set",
  W02="Bibliographic enrichment patch/state",
  W03="Retraction and publication-status assessment",
  W04="Title/abstract relevance-screening state",
  W05="Deterministic species annotation state",
  W06="Geographic annotation state",
  W07="Topic annotation state",
  W08="Final adjudicated canonical evidence-map state"
)
registry_specs <- list(
  W00="docs/search_record/zenodo_registry.csv",
  W01="docs/deduplication/zenodo_registry.csv",
  W02="docs/enrichment/zenodo_registry.csv",
  W03="docs/publication_status/zenodo_registry.csv",
  W04="docs/workflow04/zenodo_registry.csv",
  W05="docs/workflow05/zenodo_registry.csv",
  W06="docs/workflow06/zenodo_registry.csv",
  W07="docs/workflow07/zenodo_registry.csv",
  W08="docs/workflow08/zenodo_registry.csv"
)

zenodo <- list()
for(stage in names(registry_specs)) {
  p <- registry_specs[[stage]]
  if(!file.exists(p)) next
  d <- read.csv(p,stringsAsFactors=FALSE,check.names=FALSE,na.strings=c("","NA"))
  if(!nrow(d)) next
  run_col <- intersect(c("source_run_id","source_github_run_id","github_run_id"),names(d))
  if(!length(run_col)) run_col <- intersect(c("publication_github_run_id"),names(d))
  for(i in seq_len(nrow(d))) {
    doi <- as.character(d$doi[[i]] %||% "")
    if(is.na(doi)) doi <- ""
    record_url <- as.character(d$record_url[[i]] %||% "")
    if(is.na(record_url) || !nzchar(record_url)) {
      record_url <- if(nzchar(doi)) paste0("https://doi.org/",doi) else ""
    }
    visibility <- if("visibility" %in% names(d)) as.character(d$visibility[[i]] %||% "") else ""
    if(is.na(visibility)) visibility <- ""
    if(stage=="W08" && !nzchar(visibility)) visibility <- "restricted"
    state_cols <- intersect(c("state","status","run_type"),names(d))
    state <- if(length(state_cols)) as.character(d[[state_cols[[1L]]]][[i]] %||% "") else ""
    if(is.na(state)) state <- ""
    pub <- if("published_at_utc" %in% names(d)) as.character(d$published_at_utc[[i]] %||% "") else ""
    if(is.na(pub)) pub <- ""
    run_id <- if(length(run_col)) as.character(d[[run_col[[1L]]]][[i]] %||% "") else ""
    if(is.na(run_id)) run_id <- ""
    zenodo[[length(zenodo)+1L]] <- list(
      stage=stage,
      description=unname(stage_desc[[stage]]),
      state=state,
      doi=doi,
      record_url=record_url,
      visibility=tolower(visibility),
      source_run_id=run_id,
      published_at_utc=pub
    )
  }
}
if(length(zenodo)) {
  vis <- vapply(zenodo,function(z)z$visibility,character(1))
  if(any(vis!="restricted")) {
    stop("Output registry refuses to describe a non-restricted Zenodo workflow record",call.=FALSE)
  }
}

searches <- list()
if(file.exists(flow_path)) {
  flow <- fromJSON(flow_path,simplifyVector=FALSE)
  src <- (flow$counts %||% list())$source_searches %||% list()
  if(length(src)) {
    searches <- lapply(src,function(x) list(
      database=as.character(x$database %||% x$code %||% ""),
      code=as.character(x$code %||% ""),
      search_date=as.character(x$search_date %||% ""),
      results=suppressWarnings(as.integer(x$hits %||% NA_integer_))
    ))
  }
}
if(!length(searches)) {
  src <- (status$search %||% list())$sources %||% list()
  if(length(src)) {
    searches <- lapply(names(src),function(code) list(
      database=code,
      code=code,
      search_date=search_date,
      results=suppressWarnings(as.integer(src[[code]]$successfully_downloaded_results %||% src[[code]]$reported_search_results %||% NA_integer_))
    ))
  }
}

catalogue <- list()
add <- function(path,desc,cat) {
  row <- file_row(path,desc,cat)
  if(!is.null(row)) catalogue[[length(catalogue)+1L]] <<- row
}
add("docs/reporting/workflow_09/data/living_evidence_map_canonical_final.ris","RIS export of the final canonical included-record set","Data")
add("docs/reporting/workflow_09/data/living_evidence_map_canonical_final.ris.manifest.json","Manifest and checksum for the final RIS export","Data")
add("docs/reporting/workflow_09/manuscript/methods.html","Rendered methods report","Report")
add("docs/reporting/workflow_09/manuscript/methods.pdf","PDF methods report","Report")
add("docs/reporting/workflow_09/manuscript/results.html","Rendered results report","Report")
add("docs/reporting/workflow_09/manuscript/results.pdf","PDF results report","Report")
add("docs/reporting/workflow_09/flow_counts.json","Workflow flow counts used for reporting","Metadata")
add("docs/reporting/workflow_09/flow_human_validation.csv","Human-validation flow summary","Metadata")
add("docs/reporting/workflow_09/data/human_validation/human_validation_summary.json","Human/model validation summary","Validation")
add("docs/reporting/workflow_09/data/human_validation/model_validation_history.csv","Model validation history","Validation")
add("docs/reporting/workflow_09/data/human_validation/human_consistency_history.csv","Human consistency history","Validation")
add("docs/reporting/workflow_09/data/human_validation/human_consistency_cumulative.csv","Cumulative human consistency statistics","Validation")
add("user_input/workflow04_screening_highlight_terms.csv","W04 screening highlight-term configuration","Codebook")
add("user_input/workflow05_deterministic_concepts.csv","Deterministic W05 concept definitions","Codebook")
add("user_input/workflow05_species_dictionary_reference.csv","Species dictionary reference","Codebook")
add("user_input/workflow07_topic_ontology.csv","Topic ontology used for W07/W08 coding","Codebook")
add("docs/index.html","Dashboard HTML source","Dashboard")
add("docs/dashboard-data.js","Dashboard data payload currently committed in the repository","Dashboard")
if(dir.exists("docs/reporting/workflow_09/figures")) {
  figs <- sort(list.files("docs/reporting/workflow_09/figures",pattern="\\.pdf$",full.names=TRUE))
  for(p in figs) add(p,paste("Workflow 09 figure:",basename(p)),"Figure")
}
if(dir.exists("docs/reporting/workflow_09/data/workflow_inputs")) {
  meta <- sort(list.files("docs/reporting/workflow_09/data/workflow_inputs",full.names=TRUE))
  meta <- meta[file.info(meta)$isdir %in% FALSE]
  for(p in meta) add(p,paste("Compact workflow reporting input:",basename(p)),"Workflow metadata")
}
if(dir.exists(w10_dir)) {
  for(p in c(
    file.path(w10_dir,"living_evidence_map-internal.csv"),
    file.path(w10_dir,"dashboard-internal-data.js"),
    file.path(w10_dir,"dashboard-data.js"),
    file.path(w10_dir,"index.html")
  )) {
    if(file.exists(p)) {
      label <- switch(basename(p),
        "living_evidence_map-internal.csv"="W10 internal dashboard source table",
        "dashboard-internal-data.js"="W10 internal dashboard data payload",
        "dashboard-data.js"="W10 public-projection dashboard data payload",
        "index.html"="W10 dashboard HTML build",
        basename(p)
      )
      row <- file_row(p,label,"W10 build artefact")
      row$path <- p
      catalogue[[length(catalogue)+1L]] <- row
    }
  }
}

payload <- list(
  schema="living-evidence-map-internal-output-registry-v1",
  generated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ"),
  search_date=search_date,
  update_id=as.character(status$update_id %||% ""),
  note="Internal repository registry. Not intended for publication.",
  zenodo_policy="All workflow Zenodo deposits listed here are restricted.",
  database_searches=searches,
  zenodo_records=zenodo,
  files=catalogue
)

json_path <- file.path(archive_dir,"output-registry.json")
writeLines(toJSON(payload,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),json_path,useBytes=TRUE)

flat <- if(length(catalogue)) do.call(rbind,lapply(catalogue,function(x)data.frame(
  category=x$category,path=x$path,description=x$description,format=x$format,
  bytes=x$bytes,sha256=x$sha256,stringsAsFactors=FALSE
))) else data.frame()
csv_path <- file.path(archive_dir,"output-registry-files.csv")
write.csv(flat,csv_path,row.names=FALSE,na="")

row_html <- function(cells) paste0("<tr>",paste0("<td>",cells,"</td>",collapse=""),"</tr>")
search_html <- if(length(searches)) paste0(vapply(searches,function(x)row_html(c(
  html_escape(x$database),html_escape(x$search_date),
  if(is.na(x$results)) "" else format(x$results,big.mark=",",scientific=FALSE)
)),character(1)),collapse="\n") else row_html(c("No search provenance found","",""))

zen_html <- if(length(zenodo)) paste0(vapply(zenodo,function(x) {
  doi_cell <- if(nzchar(x$doi)) sprintf('<a href="https://doi.org/%s">%s</a>',html_escape(x$doi),html_escape(x$doi)) else ""
  row_html(c(html_escape(x$stage),html_escape(x$description),doi_cell,html_escape(x$state),
             html_escape(x$visibility),html_escape(x$source_run_id),html_escape(x$published_at_utc)))
},character(1)),collapse="\n") else row_html(rep("",7))

file_html <- if(length(catalogue)) paste0(vapply(catalogue,function(x) {
  href <- if(startsWith(x$path,"outputs/")) "" else rel_link(x$path,archive_dir)
  name <- html_escape(x$path)
  name_cell <- if(nzchar(href)) sprintf('<a href="%s">%s</a>',href,name) else name
  row_html(c(html_escape(x$category),name_cell,html_escape(x$description),html_escape(x$format),fmt_bytes(x$bytes)))
},character(1)),collapse="\n") else row_html(rep("",5))

html <- paste0('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">',
'<title>Internal output registry ',html_escape(search_date),'</title>',
'<style>body{font-family:Arial,sans-serif;background:#f7f8fa;color:#17212b;margin:0}.wrap{max-width:1180px;margin:auto;padding:30px 24px}h1{margin-bottom:4px}p.note{color:#68747d}.card{background:white;border:1px solid #dfe5e8;border-radius:10px;margin:16px 0;padding:16px;overflow:auto}table{width:100%;border-collapse:collapse;font-size:13px}th,td{text-align:left;padding:9px 8px;border-bottom:1px solid #e8ecee;vertical-align:top}th{color:#68747d}a{color:#174f9e}.pill{display:inline-block;background:#eaf3f0;color:#1f5d50;padding:4px 8px;border-radius:999px;font-size:12px;font-weight:bold}</style></head><body><div class="wrap">',
'<span class="pill">INTERNAL · REPOSITORY ONLY</span>',
'<h1>Living Evidence Map output registry</h1>',
'<p class="note">Search date: ',html_escape(search_date),' · Update: ',html_escape(status$update_id %||% ""),' · Generated automatically by W10. This file is not part of the public dashboard publication set.</p>',
'<div class="card"><h2>Database searches</h2><table><thead><tr><th>Database/source</th><th>Search date</th><th>Results</th></tr></thead><tbody>',search_html,'</tbody></table></div>',
'<div class="card"><h2>Zenodo records</h2><p class="note">All workflow Zenodo deposits are restricted. DOI text is shown without the https://doi.org/ prefix.</p><table><thead><tr><th>Stage</th><th>Description</th><th>DOI</th><th>State</th><th>Visibility</th><th>Source run</th><th>Published</th></tr></thead><tbody>',zen_html,'</tbody></table></div>',
'<div class="card"><h2>Files and outputs</h2><table><thead><tr><th>Category</th><th>File</th><th>Description</th><th>Format</th><th>Size</th></tr></thead><tbody>',file_html,'</tbody></table></div>',
'<p class="note">Machine-readable copies: output-registry.json and output-registry-files.csv. Checksums are stored in those files.</p>',
'</div></body></html>')
html_path <- file.path(archive_dir,"output-registry.html")
writeLines(html,html_path,useBytes=TRUE)

manifest <- list(
  schema="living-evidence-map-internal-output-registry-manifest-v1",
  search_date=search_date,
  generated_at_utc=payload$generated_at_utc,
  files=list(
    list(path=basename(html_path),sha256=digest(file=html_path,algo="sha256",serialize=FALSE)),
    list(path=basename(json_path),sha256=digest(file=json_path,algo="sha256",serialize=FALSE)),
    list(path=basename(csv_path),sha256=digest(file=csv_path,algo="sha256",serialize=FALSE))
  )
)
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE),file.path(archive_dir,"manifest.json"),useBytes=TRUE)

cat(sprintf("PASS: internal output registry written to %s (%d Zenodo records; %d searches; %d files)\n",
            archive_dir,length(zenodo),length(searches),length(catalogue)))
