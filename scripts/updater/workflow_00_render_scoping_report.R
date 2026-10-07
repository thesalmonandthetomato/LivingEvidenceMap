#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
counts_path <- arg("--counts")
meta_path <- arg("--meta")
output_path <- arg("--output")
if (any(vapply(list(counts_path,meta_path,output_path),is.null,logical(1)))) {
  stop("Required: --counts --meta --output",call.=FALSE)
}

suppressPackageStartupMessages(library(jsonlite))
counts <- read.csv(counts_path,stringsAsFactors=FALSE,na.strings="")
meta <- fromJSON(meta_path,simplifyVector=FALSE)
hits <- suppressWarnings(as.integer(counts$hits))
status <- ifelse(grepl("fail|error",tolower(counts$status)),"Failed","Complete")
fmt_hits <- ifelse(is.na(hits),"-",format(hits,big.mark=",",scientific=FALSE))
total <- sum(hits,na.rm=TRUE)

dir.create(dirname(output_path),recursive=TRUE,showWarnings=FALSE)
grDevices::pdf(output_path,width=8.27,height=11.69,onefile=TRUE,useDingbats=FALSE)
page_lines <- function(lines, mono=FALSE, cex=0.82, top=0.94, bottom=0.06, line_gap=0.027) {
  graphics::plot.new()
  y <- top
  fam <- if (mono) "mono" else "sans"
  for (line in lines) {
    graphics::text(0.06,y,labels=line,adj=c(0,1),family=fam,cex=cex,xpd=NA)
    y <- y-line_gap
    if (y < bottom) {
      graphics::plot.new()
      y <- top
    }
  }
}

graphics::plot.new()
graphics::text(0.06,0.95,"Search scoping report",adj=c(0,1),family="sans",font=2,cex=1.45)
graphics::text(0.06,0.91,sprintf("Scoping date: %s",format(as.Date(meta$search_date),"%d-%m-%Y")),adj=c(0,1),family="sans",cex=0.9)
graphics::text(0.06,0.865,"This report records a count-only scoping search. No bibliographic records or raw API responses were retained.",adj=c(0,1),family="sans",cex=0.82)

graphics::text(0.06,0.81,"Search string",adj=c(0,1),family="sans",font=2,cex=1.05)
q <- as.character(if (is.null(meta$original_search_string)) "" else meta$original_search_string)
q_lines <- unlist(strwrap(q,width=105),use.names=FALSE)
y <- 0.775
for (line in q_lines) {
  graphics::text(0.06,y,line,adj=c(0,1),family="mono",cex=0.68)
  y <- y-0.022
  if (y < 0.08) {
    graphics::plot.new()
    y <- 0.94
  }
}

graphics::plot.new()
graphics::text(0.06,0.95,"Database counts",adj=c(0,1),family="sans",font=2,cex=1.15)
graphics::text(0.06,0.91,"Database",adj=c(0,1),family="sans",font=2,cex=0.82)
graphics::text(0.77,0.91,"Hits",adj=c(1,1),family="sans",font=2,cex=0.82)
graphics::text(0.80,0.91,"Status",adj=c(0,1),family="sans",font=2,cex=0.82)
graphics::segments(0.06,0.885,0.94,0.885)
y <- 0.865
for (i in seq_len(nrow(counts))) {
  label <- as.character(counts$source[[i]])
  lab_lines <- strwrap(label,width=65)
  graphics::text(0.06,y,lab_lines[[1]],adj=c(0,1),family="sans",cex=0.76)
  graphics::text(0.77,y,fmt_hits[[i]],adj=c(1,1),family="sans",cex=0.76)
  graphics::text(0.80,y,status[[i]],adj=c(0,1),family="sans",cex=0.76)
  if (length(lab_lines)>1L) {
    for (extra in lab_lines[-1]) {
      y <- y-0.021
      graphics::text(0.06,y,extra,adj=c(0,1),family="sans",cex=0.76)
    }
  }
  y <- y-0.029
  if (y < 0.10 && i < nrow(counts)) {
    graphics::plot.new()
    y <- 0.94
    graphics::text(0.06,y,"Database counts (continued)",adj=c(0,1),family="sans",font=2,cex=1.0)
    y <- y-0.04
  }
}
graphics::segments(0.06,y+0.009,0.94,y+0.009)
graphics::text(0.06,y-0.008,"Total",adj=c(0,1),family="sans",font=2,cex=0.8)
graphics::text(0.77,y-0.008,format(total,big.mark=",",scientific=FALSE),adj=c(1,1),family="sans",font=2,cex=0.8)
graphics::text(0.06,0.045,"Counts are totals reported by each live-searchable database/API at the time of the scoping run.",adj=c(0,0),family="sans",cex=0.7)

grDevices::dev.off()
cat(sprintf("PASS: wrote %s\n",output_path))
