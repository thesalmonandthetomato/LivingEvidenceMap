#!/usr/bin/env Rscript
# Analyse a checked-out Shiny application without changing it.
a <- commandArgs(trailingOnly=TRUE)
app <- if(length(a)) a[[1]] else "shiny_app"
out <- if(length(a)>1) a[[2]] else "outputs/dependency_audit"
dir.create(out,recursive=TRUE,showWarnings=FALSE)
if(!file.exists(file.path(app,"app.R")))stop("Missing app.R in Shiny checkout")
files <- list.files(app,recursive=TRUE,all.files=TRUE,no..=TRUE)
files <- files[!grepl("(^|/)(\\.git|node_modules|renv/library)/",files)]
rfiles <- files[grepl("\\.[Rr]$",files)]
edges <- list()
append_edge <- function(from,to,kind)edges[[length(edges)+1L]] <<- data.frame(source=from,target=to,kind=kind,exists=to %in% files)
for(f in rfiles){
  txt <- paste(readLines(file.path(app,f),warn=FALSE),collapse="\n")
  matches <- regmatches(txt,gregexpr("(?:(?:source|readRDS|read_csv|read\\.csv|fromJSON|readLines)\\s*\\(\\s*['\"][^'\"\\n]+['\"])",txt,perl=TRUE))[[1]]
  if(length(matches))for(m in unique(matches)){
    path <- sub("^.*?['\"]([^'\"]+)['\"]$","\\1",m,perl=TRUE)
    append_edge(f,path,"literal-file-input")
  }
  wf <- regmatches(txt,gregexpr("/actions/workflows/[A-Za-z0-9_.-]+\\.ya?ml",txt,perl=TRUE))[[1]]
  if(length(wf))for(x in unique(wf))append_edge(f,paste0("EXTERNAL:LivingEvidenceMap/.github/workflows/",sub("^/actions/workflows/","",x)),"github-dispatch")
  markers <- regmatches(txt,gregexpr("(?:docs|data|config|state)/[A-Za-z0-9_./-]+",txt,perl=TRUE))[[1]]
  if(length(markers))for(x in unique(markers))append_edge(f,paste0("EXTERNAL:LivingEvidenceMap/",x),"github-path")
  if(grepl("file\\.path\\s*\\(|paste0?\\s*\\(|sprintf\\s*\\(|list\\.files\\s*\\(",txt,perl=TRUE))append_edge(f,"<dynamic-path-review>","dynamic-path")
}
tab <- if(length(edges))unique(do.call(rbind,edges)) else data.frame(source=character(),target=character(),kind=character(),exists=logical())
write.csv(tab,file.path(out,"shiny_edges.csv"),row.names=FALSE)
write.csv(data.frame(path=files,referenced=files %in% tab$target),file.path(out,"shiny_inventory.csv"),row.names=FALSE)
notes <- c(sprintf("Shiny app files: %s",length(files)),sprintf("Shiny R files: %s",length(rfiles)),sprintf("Detected links: %s",nrow(tab)),"Read-only analysis, not proof of safe deletion.")
writeLines(notes,file.path(out,"shiny_summary.txt"));cat(paste(notes,collapse="\n"),"\n")
