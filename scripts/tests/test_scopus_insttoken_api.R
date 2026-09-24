suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
})

args <- commandArgs(trailingOnly = TRUE)
input <- if (length(args) >= 1) args[[1]] else "data/master/current/living_evidence_map_master.csv"
out <- if (length(args) >= 2) args[[2]] else "scopus_api_test_20.csv"

api_key <- Sys.getenv("SCOPUS_API_KEY")
insttoken <- Sys.getenv("SCOPUS_INSTTOKEN")
if (!nzchar(api_key)) stop("SCOPUS_API_KEY is missing")
if (!nzchar(insttoken)) stop("SCOPUS_INSTTOKEN is missing")
if (!file.exists(input)) stop("Input missing: ", input)

dat <- read.csv(input, stringsAsFactors = FALSE, check.names = FALSE)

nms <- names(dat)
lower <- tolower(nms)
pick_col <- function(cands) {
  idx <- match(cands, lower, nomatch = 0L)
  idx <- idx[idx > 0L]
  if (length(idx)) nms[idx[[1]]] else NA_character_
}

doi_col <- pick_col(c("doi","prism:doi","digital_object_identifier"))
title_col <- pick_col(c("title","dc:title","article_title"))
abstract_col <- pick_col(c("abstract","dc:description","description","abstract_text"))

if (is.na(doi_col)) stop("Could not identify DOI column. Columns: ", paste(nms, collapse=", "))
if (is.na(title_col)) stop("Could not identify title column. Columns: ", paste(nms, collapse=", "))
if (is.na(abstract_col)) stop("Could not identify abstract column. Columns: ", paste(nms, collapse=", "))

clean <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  trimws(x)
}
norm_doi <- function(x) {
  x <- tolower(trimws(x))
  x <- sub("^https?://(dx\\.)?doi\\.org/", "", x)
  x <- sub("^doi:\\s*", "", x)
  x <- sub("[[:space:][:punct:]]+$", "", x)
  x
}

doi <- clean(dat[[doi_col]])
title <- clean(dat[[title_col]])
abstract <- clean(dat[[abstract_col]])
eligible <- nzchar(doi) & (!nzchar(title) | !nzchar(abstract))
idx <- which(eligible)
if (!length(idx)) stop("No DOI-bearing records with missing title or abstract found.")

set.seed(24092026)
sample_idx <- if (length(idx) <= 20L) idx else sample(idx, 20L, replace = FALSE)

first_nonempty <- function(...) {
  vals <- list(...)
  for (v in vals) {
    if (!is.null(v) && length(v)) {
      vv <- as.character(v[[1]])
      if (!is.na(vv) && nzchar(trimws(vv))) return(vv)
    }
  }
  ""
}

safe_extract <- function(obj) {
  rr <- obj[["abstracts-retrieval-response"]]
  if (is.null(rr)) rr <- obj
  core <- rr[["coredata"]]
  if (is.null(core)) core <- list()

  got_title <- first_nonempty(core[["dc:title"]], core[["title"]])
  got_doi <- first_nonempty(core[["prism:doi"]], core[["doi"]])
  got_eid <- first_nonempty(core[["eid"]], rr[["eid"]])
  got_abs <- first_nonempty(core[["dc:description"]], core[["description"]])

  if (!nzchar(got_abs)) {
    item <- rr[["item"]]
    if (!is.null(item)) {
      biblio <- item[["bibrecord"]][["head"]][["abstracts"]]
      if (is.null(biblio)) biblio <- item[["bibliography"]][["abstracts"]]
      if (!is.null(biblio)) {
        txt <- paste(unlist(biblio, use.names = FALSE), collapse = " ")
        txt <- trimws(gsub("\\s+", " ", txt))
        if (nzchar(txt)) got_abs <- txt
      }
    }
  }

  list(title=got_title, doi=got_doi, eid=got_eid, abstract=got_abs)
}

rows <- vector("list", length(sample_idx))

for (j in seq_along(sample_idx)) {
  i <- sample_idx[[j]]
  d <- norm_doi(doi[[i]])
  endpoint <- paste0("https://api.elsevier.com/content/abstract/doi/", URLencode(d, reserved = TRUE))

  req <- request(endpoint) |>
    req_headers(
      `X-ELS-APIKey` = api_key,
      `X-ELS-Insttoken` = insttoken,
      Accept = "application/json"
    ) |>
    req_user_agent("LivingEvidenceMap-Scopus-API-test/1.0") |>
    req_error(is_error = function(resp) FALSE)

  resp <- tryCatch(req_perform(req), error = function(e) e)

  if (inherits(resp, "error")) {
    rows[[j]] <- data.frame(
      row_index=i, requested_doi=d,
      missing_title_before=!nzchar(title[[i]]),
      missing_abstract_before=!nzchar(abstract[[i]]),
      http_status=NA_integer_, returned_doi="", returned_eid="",
      returned_title="", title_returned=FALSE,
      abstract_returned=FALSE, abstract_chars=0L,
      abstract_preview="", result=paste0("REQUEST_ERROR: ", conditionMessage(resp)),
      stringsAsFactors=FALSE
    )
    next
  }

  status <- resp_status(resp)
  parsed <- NULL
  if (status >= 200 && status < 300) {
    parsed <- tryCatch(resp_body_json(resp, simplifyVector = FALSE), error = function(e) NULL)
  }

  ex <- if (!is.null(parsed)) safe_extract(parsed) else list(title="", doi="", eid="", abstract="")
  abs_txt <- ex$abstract
  preview <- if (nzchar(abs_txt)) substr(gsub("\\s+", " ", abs_txt), 1, 200) else ""

  result <- if (status >= 200 && status < 300) {
    if (nzchar(ex$title) && nzchar(abs_txt)) "PASS_TITLE_AND_ABSTRACT"
    else if (nzchar(ex$title)) "PARTIAL_TITLE_ONLY"
    else if (nzchar(abs_txt)) "PARTIAL_ABSTRACT_ONLY"
    else "SUCCESS_NO_TITLE_OR_ABSTRACT"
  } else {
    paste0("HTTP_", status)
  }

  rows[[j]] <- data.frame(
    row_index=i, requested_doi=d,
    missing_title_before=!nzchar(title[[i]]),
    missing_abstract_before=!nzchar(abstract[[i]]),
    http_status=status, returned_doi=ex$doi, returned_eid=ex$eid,
    returned_title=ex$title, title_returned=nzchar(ex$title),
    abstract_returned=nzchar(abs_txt), abstract_chars=nchar(abs_txt, type="chars"),
    abstract_preview=preview, result=result,
    stringsAsFactors=FALSE
  )

  Sys.sleep(0.3)
}

res <- do.call(rbind, rows)
write.csv(res, out, row.names = FALSE, na = "")

cat("Input:", input, "\n")
cat("DOI column:", doi_col, "\n")
cat("Title column:", title_col, "\n")
cat("Abstract column:", abstract_col, "\n")
cat("Eligible records:", length(idx), "\n")
cat("Tested:", nrow(res), "\n")
cat("HTTP 2xx:", sum(res$http_status >= 200 & res$http_status < 300, na.rm=TRUE), "\n")
cat("Titles returned:", sum(res$title_returned), "\n")
cat("Abstracts returned:", sum(res$abstract_returned), "\n")
cat("Both returned:", sum(res$title_returned & res$abstract_returned), "\n")
cat("Results:\n")
print(table(res$result, useNA="ifany"))
