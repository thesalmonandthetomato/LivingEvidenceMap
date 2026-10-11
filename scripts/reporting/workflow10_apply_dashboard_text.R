#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))
args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2L) stop("Usage: workflow10_apply_dashboard_text.R <config.json> <index.html>")
config <- fromJSON(args[[1L]], simplifyVector = TRUE)
if (!all(c("title", "intro") %in% names(config))) stop("Dashboard text needs title and intro")
for (key in c("title", "intro")) {
  v <- config[[key]]
  if (!is.character(v) || length(v) != 1L || is.na(v) || !nzchar(trimws(v))) {
    stop("Dashboard ", key, " must be non-empty plain text")
  }
}
escape_html <- function(x) {
  for (pair in list(c("&","&amp;"),c("<","&lt;"),c(">","&gt;"),c('"',"&quot;"),c("'","&#39;"))) {
    x <- gsub(pair[[1L]], pair[[2L]], x, fixed=TRUE)
  }
  x
}
html <- paste(readLines(args[[2L]], warn=FALSE, encoding="UTF-8"), collapse="\n")
replace_once <- function(x, pattern, replacement) {
  m <- regexpr(pattern, x, perl=TRUE)
  if (length(m) != 1L || m[[1L]] < 0L) stop("Dashboard HTML template missing: ", pattern)
  start <- as.integer(m[[1L]])
  len <- as.integer(attr(m, "match.length")[[1L]])
  paste0(substr(x, 1L, start - 1L), replacement, substr(x, start + len, nchar(x)))
}
title <- escape_html(trimws(config$title))
intro <- escape_html(trimws(config$intro))
html <- replace_once(html, "<title>[^<]*</title>", paste0("<title>", title, "</title>"))
html <- replace_once(html, "<h1>[^<]*</h1>", paste0("<h1>", title, "</h1>"))
html <- replace_once(html, '<p class="project-description">.*?</p>',
                     paste0('<p class="project-description">', intro, '</p>'))
writeLines(html, args[[2L]], useBytes=TRUE)
cat("PASS: dashboard title and introduction applied from user_input\n")
