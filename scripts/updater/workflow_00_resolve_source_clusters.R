#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default="") {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
split_csv <- function(x) {
  x <- trimws(x)
  if (!nzchar(x)) return(character())
  y <- trimws(strsplit(x,",",fixed=TRUE)[[1L]])
  unique(y[nzchar(y)])
}

config_path <- arg("--config","config/workflow00_ebsco_clusters.json")
selected_clusters <- split_csv(arg("--selected-clusters",""))
direct_sources <- split_csv(arg("--direct-sources",""))
output <- arg("--output","outputs/updater/workflow00_plan/resolved_sources.json")

cfg <- fromJSON(config_path,simplifyVector=FALSE)
valid_clusters <- names(cfg$clusters)
bad <- setdiff(selected_clusters,valid_clusters)
if (length(bad)) stop(sprintf("Unknown source cluster(s): %s",paste(bad,collapse=", ")),call.=FALSE)

standard_sources <- direct_sources
ebsco_codes <- character()
cluster_expansion <- list()

for (cl in selected_clusters) {
  ecodes <- unname(unlist(cfg$clusters[[cl]]$database_codes))
  nons <- unname(unlist(cfg$non_ebsco_cluster_members[[cl]]))
  ebsco_codes <- c(ebsco_codes,ecodes)
  standard_sources <- c(standard_sources,nons)
  cluster_expansion[[cl]] <- list(
    ebsco_database_codes=as.list(ecodes),
    non_ebsco_sources=as.list(nons)
  )
}

standard_sources <- sort(unique(standard_sources[nzchar(standard_sources)]))
ebsco_codes <- sort(unique(ebsco_codes[nzchar(ebsco_codes)]))
known_standard <- c("lens","scopus","openalex","agricola","pubmed","ethos","cba","epmc_preprints","wos")
unknown_standard <- setdiff(standard_sources,known_standard)
if (length(unknown_standard)) stop(sprintf("Unknown standard source(s): %s",paste(unknown_standard,collapse=", ")),call.=FALSE)
unknown_ebsco <- setdiff(ebsco_codes,names(cfg$databases))
if (length(unknown_ebsco)) stop(sprintf("Unknown EBSCO database code(s): %s",paste(unknown_ebsco,collapse=", ")),call.=FALSE)
if (!length(standard_sources) && !length(ebsco_codes)) stop("Select at least one source or topic cluster",call.=FALSE)

db_meta <- lapply(ebsco_codes,function(code) {
  z <- cfg$databases[[code]]
  list(code=code,title=z$title,source=paste0("ebsco_",tolower(code)))
})
names(db_meta) <- ebsco_codes

out <- list(
  schema="living-evidence-map-workflow00-source-resolution-v1",
  selected_clusters=as.list(selected_clusters),
  direct_sources=as.list(direct_sources),
  standard_sources=as.list(standard_sources),
  ebsco_database_codes=as.list(ebsco_codes),
  ebsco_sources=db_meta,
  cluster_expansion=cluster_expansion,
  overlap_policy="Union selected clusters and direct sources; execute each resolved source/database once."
)
dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(out,auto_unbox=TRUE,pretty=TRUE,null="null"),output,useBytes=TRUE)
cat(sprintf("PASS: resolved %d standard source(s) and %d EBSCO database(s) from %d cluster(s)\n",
            length(standard_sources),length(ebsco_codes),length(selected_clusters)))
