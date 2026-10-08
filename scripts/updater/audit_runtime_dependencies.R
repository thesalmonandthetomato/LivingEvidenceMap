#!/usr/bin/env Rscript
# Read-only conservative dependency census. This DOES NOT identify safe deletions.
args <- commandArgs(trailingOnly=TRUE)
root <- if (length(args)) args[[1L]] else "."
out <- if (length(args)>1L) args[[2L]] else "outputs/dependency_audit"
dir.create(out,recursive=TRUE,showWarnings=FALSE)
paths <- list.files(root,recursive=TRUE,all.files=TRUE,no..=TRUE)
paths <- paths[!grepl("(^|/)(\\.git|outputs|node_modules|\\.Rproj\\.user)/",paths)]
sources <- paths[grepl("\\.(R|r|yml|yaml|sh)$",paths)]
edges <- list()
add <- function(source,target,kind) {
  edges[[length(edges)+1L]] <<- data.frame(source=source,target=target,kind=kind,exists=target %in% paths,stringsAsFactors=FALSE)
}
for(f in sources) {
  lines <- tryCatch(readLines(file.path(root,f),warn=FALSE,encoding="UTF-8"),error=function(e) character())
  contents <- paste(lines,collapse="\n")
  hits <- regmatches(contents,gregexpr("(?:\\.github/workflows|scripts|R|visualisations|config|data|docs|state|user_input|tests|models|internal|public_export)/[A-Za-z0-9_./-]+",contents,perl=TRUE))[[1L]]
  if(length(hits)) for(t in unique(hits)) add(f,t,"textual-reference")
  if(grepl("file\\.path\\s*\\(|paste0?\\s*\\(|sprintf\\s*\\(|list\\.files\\s*\\(|Sys\\.glob\\s*\\(",contents,perl=TRUE))
    add(f,"<dynamic-path-needs-review>","dynamic-path")
  if(grepl("source\\s*\\(|Rscript|gh workflow run|workflow_call|repository_dispatch",contents,perl=TRUE))
    add(f,"<execution-contract-needs-review>","execution-contract")
}
tbl <- if(length(edges)) unique(do.call(rbind,edges)) else data.frame(source=character(),target=character(),kind=character(),exists=logical())
write.csv(tbl,file.path(out,"dependency_edges.csv"),row.names=FALSE)
inventory <- data.frame(path=paths,referenced=paths %in% tbl$target,stringsAsFactors=FALSE)
inventory$status <- ifelse(inventory$referenced,"REFERENCED","UNVERIFIED")
write.csv(inventory,file.path(out,"file_inventory.csv"),row.names=FALSE)
notes <- c(sprintf("Repository files: %d",length(paths)),sprintf("Workflow files: %d",sum(grepl("^\\.github/workflows/.*\\.ya?ml$",paths))),sprintf("Textual dependency edges: %d",nrow(tbl)),"WARNING: unverified does not mean unused.","WARNING: dynamic references, external services and provenance need separate inspection.","Do not delete files based on this report.")
writeLines(notes,file.path(out,"README.txt"))
cat(paste(notes,collapse="\n"),"\n")
