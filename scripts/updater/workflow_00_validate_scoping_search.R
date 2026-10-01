#!/usr/bin/env Rscript

suppressPackageStartupMessages(library(jsonlite))

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s", flag), call. = FALSE)
  args[[i + 1L]]
}

input_path <- arg("--input")
output_json <- arg("--output")
ebsco_config_path <- arg("--ebsco-config","config/workflow00_ebsco_sources.json")
if (is.null(input_path) || is.null(output_json)) {
  stop("Required: --input --output", call. = FALSE)
}
if (!file.exists(input_path)) stop("Scoping search string file not found", call. = FALSE)
if (!file.exists(ebsco_config_path)) stop("EBSCO source config not found", call. = FALSE)

raw_lines <- readLines(input_path, warn = FALSE, encoding = "UTF-8")
raw <- trimws(paste(raw_lines, collapse = " "))
raw <- gsub("\\s+", " ", raw)
if (!nzchar(raw)) stop("Scoping search string is empty", call. = FALSE)

if (grepl("[“”‘’]", raw)) {
  stop('Smart quotes are not allowed. Use straight double quotes for phrases, e.g. "rainbow trout".', call. = FALSE)
}

tokenize <- function(x) {
  n <- nchar(x)
  i <- 1L
  out <- character()
  while (i <= n) {
    ch <- substr(x, i, i)
    if (grepl("\\s", ch)) {
      i <- i + 1L
      next
    }
    if (ch %in% c("(", ")")) {
      out <- c(out, ch)
      i <- i + 1L
      next
    }
    if (ch == '"') {
      j <- i + 1L
      while (j <= n && substr(x, j, j) != '"') j <- j + 1L
      if (j > n) stop("Unclosed double quote in search string", call. = FALSE)
      val <- substr(x, i, j)
      if (!nzchar(trimws(substr(x, i + 1L, j - 1L)))) {
        stop("Quoted phrases cannot be empty", call. = FALSE)
      }
      out <- c(out, val)
      i <- j + 1L
      next
    }
    j <- i
    while (j <= n && !grepl("\\s|[()]", substr(x, j, j))) j <- j + 1L
    tok <- substr(x, i, j - 1L)
    if (!nzchar(tok)) stop("Could not tokenize search string", call. = FALSE)
    out <- c(out, tok)
    i <- j
  }
  out
}

tokens <- tokenize(raw)
if (!length(tokens)) stop("Scoping search string contains no tokens", call. = FALSE)

normalise_token <- function(tok) {
  up <- toupper(tok)
  if (up %in% c("AND", "OR", "NOT")) up else tok
}
tokens <- vapply(tokens, normalise_token, character(1))

is_operator <- function(x) x %in% c("AND", "OR", "NOT")
is_operand <- function(x) !(x %in% c("AND", "OR", "NOT", "(", ")"))

pos <- 1L
peek <- function() if (pos <= length(tokens)) tokens[[pos]] else NA_character_
consume <- function(expected = NULL) {
  if (pos > length(tokens)) stop("Unexpected end of search string", call. = FALSE)
  tok <- tokens[[pos]]
  if (!is.null(expected) && !identical(tok, expected)) {
    stop(sprintf("Expected '%s' but found '%s'", expected, tok), call. = FALSE)
  }
  pos <<- pos + 1L
  tok
}

parse_primary <- function() {
  tok <- peek()
  if (is.na(tok)) stop("Expected a search term or '('", call. = FALSE)
  if (tok == "(") {
    consume("(")
    if (identical(peek(), ")")) stop("Empty parentheses are not allowed", call. = FALSE)
    parse_or()
    consume(")")
    return(invisible(TRUE))
  }
  if (tok %in% c("AND", "OR", ")")) {
    stop(sprintf("Expected a search term but found '%s'", tok), call. = FALSE)
  }
  if (tok == "NOT") {
    consume("NOT")
    parse_primary()
    return(invisible(TRUE))
  }
  consume()
  invisible(TRUE)
}

parse_and <- function() {
  parse_primary()
  repeat {
    tok <- peek()
    if (is.na(tok) || tok %in% c("OR", ")")) break
    if (tok == "AND") {
      consume("AND")
      parse_primary()
      next
    }
    if (tok == "NOT") {
      stop("NOT must be preceded by AND/OR or used as a unary operator", call. = FALSE)
    }
    if (is_operand(tok) || tok == "(") {
      stop(sprintf("Missing Boolean operator before '%s'", tok), call. = FALSE)
    }
    break
  }
  invisible(TRUE)
}

parse_or <- function() {
  parse_and()
  while (identical(peek(), "OR")) {
    consume("OR")
    parse_and()
  }
  invisible(TRUE)
}

parse_or()
if (pos <= length(tokens)) {
  stop(sprintf("Unexpected token '%s' after a complete Boolean expression", tokens[[pos]]), call. = FALSE)
}

# Require at least one explicit Boolean operator for a genuine Boolean scoping string.
if (!any(tokens %in% c("AND", "OR", "NOT"))) {
  stop("Search string must contain at least one Boolean operator: AND, OR, or NOT", call. = FALSE)
}

# Terms may contain letters, numbers, punctuation commonly used in bibliographic searching,
# wildcards, hyphens and periods. Database field codes are intentionally not accepted here.
operands <- tokens[vapply(tokens, is_operand, logical(1))]
bad_field <- operands[grepl("^[A-Za-z][A-Za-z0-9_-]*[:=]", operands)]
if (length(bad_field)) {
  stop(sprintf(
    "The scoping file must contain database-neutral Boolean syntax, not field codes. Remove: %s",
    paste(unique(bad_field), collapse = ", ")
  ), call. = FALSE)
}

normalised <- paste(tokens, collapse = " ")
normalised <- gsub("\\( ", "(", normalised)
normalised <- gsub(" \\)", ")", normalised)

quote_openalex_operand <- function(tok) {
  if (!is_operand(tok)) return(tok)
  if (startsWith(tok, '"') && endsWith(tok, '"')) return(tok)
  paste0('"', gsub('"', '\\"', tok, fixed = TRUE), '"')
}
oa_tokens <- vapply(tokens, quote_openalex_operand, character(1))
oa_tokens[oa_tokens == "AND"] <- "and"
oa_tokens[oa_tokens == "OR"] <- "or"
oa_tokens[oa_tokens == "NOT"] <- "not"
openalex_expr <- paste(oa_tokens, collapse = " ")
openalex_expr <- gsub("\\( ", "(", openalex_expr)
openalex_expr <- gsub(" \\)", ")", openalex_expr)

source_queries <- list(
  lens = sprintf("(title:(%s) OR abstract:(%s) OR keyword:(%s))", normalised, normalised, normalised),
  scopus = sprintf("TITLE-ABS-KEY(%s)", normalised),
  openalex = sprintf("works where title/abstract has (%s)", openalex_expr),
  agricola = sprintf("SRC:AGR AND TITLE_ABS:(%s)", normalised),
  pubmed = sprintf("SRC:MED AND TITLE_ABS:(%s)", normalised),
  ethos = sprintf("SRC:ETH AND TITLE_ABS:(%s)", normalised),
  cba = sprintf("SRC:CBA AND TITLE_ABS:(%s)", normalised),
  epmc_preprints = sprintf("SRC:PPR AND TITLE_ABS:(%s)", normalised),
  wos = sprintf("(TI=(%s)) OR (AB=(%s)) OR (AK=(%s))", normalised, normalised, normalised)
)

ebsco_cfg <- fromJSON(ebsco_config_path,simplifyVector=FALSE)
if (is.null(ebsco_cfg$sources) || !length(ebsco_cfg$sources)) stop("EBSCO source catalogue contains no sources",call.=FALSE)
ebsco_query <- function(fields, expr) {
  paste(sprintf("%s (%s)",fields,expr),collapse=" OR ")
}
for (src in names(ebsco_cfg$sources)) {
  fields <- unlist(ebsco_cfg$sources[[src]]$search_fields,use.names=FALSE)
  source_queries[[src]] <- sprintf("(%s)",ebsco_query(fields,normalised))
}

out <- list(
  schema = "living-evidence-map-workflow00-scoping-search-plan-v1",
  workflow = "00_search_scoping",
  status = "valid",
  validated_at_utc = format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ"),
  input_path = input_path,
  original_search_string = raw,
  normalised_search_string = normalised,
  validation = list(
    balanced_quotes = TRUE,
    balanced_parentheses = TRUE,
    boolean_grammar = TRUE,
    database_neutral = TRUE,
    allowed_operators = c("AND", "OR", "NOT")
  ),
  source_queries = source_queries
)

dir.create(dirname(output_json), recursive = TRUE, showWarnings = FALSE)
writeLines(toJSON(out, auto_unbox = TRUE, pretty = TRUE, null = "null"), output_json, useBytes = TRUE)
cat("PASS: scoping Boolean search string is valid\n")
