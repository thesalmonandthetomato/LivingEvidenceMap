#!/usr/bin/env Rscript
# Conservative dependency graph and reachability, observational only.
args <- commandArgs(trailingOnly=TRUE)
root <- if(length(args)) args[[1]] else "."
out <- if(length(args)>1) args[[2]] else "outputs/dependency_audit"
dir.create(out,recursive=TRUE,showWarnings=FALSE)
paths <- list.files(root,recursive=TRUE,all.files=TRUE,no..=TRUE)
paths <- paths[!grepl("(^|/)(\\.git|outputs|node_modules|\\.Rproj\\.user)/",paths)]
code <- paths[grepl("\\.(R|r|yml|yaml|sh)$",paths)]
edges <- list()
add <- function(a,b,kind) edges[[length(edges)+1L]] <<- data.frame(source=a,target=b,kind=kind,exists=b %in% paths)
for(f in code) {
  s <- paste(tryCatch(readLines(file.path(root,f),warn=FALSE),error=function(e)character()),collapse="\n")
  tokens <- regmatches(s,gregexpr("(?:\\.github/workflows|scripts|R|visualisations|config|data|docs|state|user_input|tests|models|internal|public_export)/[A-Za-z0-9_./-]+",s,perl=TRUE))[[1]]
  if(length(tokens))for(t in unique(tokens)) add(f,t,"textual-reference")
  # Runtime expressions cannot be safely resolved by static matching.
  if(grepl("file\\.path\\s*\\(|paste0?\\s*\\(|sprintf\\s*\\(|list\\.files\\s*\\(|Sys\\.glob\\s*\\(",s,perl=TRUE))
    add(f,"<dynamic-path-needs-review>","dynamic-path")
  if(grepl("source\\s*\\(|Rscript|gh workflow run|workflow_call|repository_dispatch",s,perl=TRUE))
    add(f,"<execution-contract-needs-review>","execution-contract")
}
# Confirmed current Shiny GitHub dispatch entry points from app's R/github_dispatch.R.
shiny <- c("workflow_00_search_scoping.yml","shiny-adjudication-dry-run-export-w01.yml",
"workflow_02_resume_after_human_review.yml","workflow_04_finalize_human_validation.yml",
"workflow_08_resume_after_shiny.yml","workflow_04_resume_after_shiny.yml")
for(w in shiny)add("EXTERNAL:LivingEvidenceMapAdjudication/R/github_dispatch.R",
 paste0(".github/workflows/",w),"verified-shiny-dispatch")
tbl <- if(length(edges))unique(do.call(rbind,edges)) else data.frame(source=character(),target=character(),kind=character(),exists=logical())
write.csv(tbl,file.path(out,"dependency_edges.csv"),row.names=FALSE)
roots <- unique(c(paste0(".github/workflows/",c("_workflow_00_orchestrated_source_child.yml",
"workflow_00_search_orchestrator.yml","workflow_00_search_scoping.yml",
paste0("workflow_0",1:8,"_production.yml"),"workflow_01_resume_after_human_review.yml",
"workflow_02_resume_after_human_review.yml","workflow_04_resume_after_shiny.yml",
"workflow_08_resume_after_shiny.yml","report_workflow09_figures.yml",
"workflow_10_dashboard.yml","workflow_current_run_live_status.yml")),paste0(".github/workflows/",shiny)))
roots <- roots[roots %in% paths]
visited <- roots
repeat {
  next_paths <- unique(tbl$target[tbl$source %in% visited & tbl$target %in% paths])
  more <- setdiff(next_paths,visited)
  if(!length(more))break
  visited <- c(visited,more)
}
inv <- data.frame(path=paths,referenced=paths %in% tbl$target,reachable=paths %in% visited)
inv$status <- ifelse(inv$reachable,"POTENTIAL_PRODUCTION_DEPENDENCY","UNVERIFIED")
write.csv(inv,file.path(out,"file_inventory.csv"),row.names=FALSE)
write.csv(data.frame(root=roots),file.path(out,"entry_points.csv"),row.names=FALSE)
write.csv(tbl[!tbl$exists | tbl$kind=="dynamic-path",],file.path(out,"review_queue.csv"),row.names=FALSE)
notes <- c(sprintf("Repository files: %d",length(paths)),sprintf("Workflow files: %d",sum(grepl("^\\.github/workflows/.*\\.ya?ml$",paths))),
sprintf("Textual dependency edges: %d",nrow(tbl)),sprintf("Entry points: %d",length(roots)),sprintf("Potentially reachable files: %d",length(visited)),
"Conservative textual reachability only. Other dynamic/external dependencies may be missing.",
"UNVERIFIED does not mean unused. No deletion decisions allowed.")
writeLines(notes,file.path(out,"README.txt"))
cat(paste(notes,collapse="\n"),"\n")
