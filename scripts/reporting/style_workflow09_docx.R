#!/usr/bin/env Rscript

# Apply deterministic publication styling to Workflow 09 Word manuscripts.
#
# This post-processing step keeps manuscript content unchanged while enforcing
# Word/PDF layout details that Pandoc pipe tables and default reference styles
# do not expose reliably:
#   * Methods Tables 1-2 use 25% / 75% column widths.
#   * Table and figure captions are 20% smaller than the 12 pt manuscript base
#     font (9.5 pt, the nearest Word half-point).
#   * Captions have additional space below them.
#   * Heading levels 1-3 have increased space above them.

required <- c("xml2")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) stop("Install required package(s): ", paste(missing, collapse = ", "))

library(xml2)

args <- commandArgs(trailingOnly = TRUE)
if (!length(args)) {
  stop("Usage: style_workflow09_docx.R <docx> [<docx> ...]", call. = FALSE)
}

W_NS <- "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

ensure_child <- function(parent, xpath, qname, ns, where = length(xml_children(parent))) {
  hit <- xml_find_first(parent, xpath, ns)
  if (inherits(hit, "xml_missing")) hit <- xml_add_child(parent, qname, .where = where)
  hit
}

set_w_attr <- function(node, local_name, value) {
  xml_set_attr(node, paste0("w:", local_name), as.character(value))
}

paragraph_text <- function(p, ns) {
  paste0(xml_text(xml_find_all(p, ".//w:t", ns)), collapse = "")
}

set_run_size <- function(p, half_points, ns) {
  runs <- xml_find_all(p, ".//w:r", ns)
  for (r in runs) {
    rPr <- ensure_child(r, "./w:rPr", "w:rPr", ns, where = 0)
    sz <- ensure_child(rPr, "./w:sz", "w:sz", ns)
    szCs <- ensure_child(rPr, "./w:szCs", "w:szCs", ns)
    set_w_attr(sz, "val", half_points)
    set_w_attr(szCs, "val", half_points)
  }
}

set_paragraph_after <- function(p, twips, ns) {
  pPr <- ensure_child(p, "./w:pPr", "w:pPr", ns, where = 0)
  spacing <- ensure_child(pPr, "./w:spacing", "w:spacing", ns)
  set_w_attr(spacing, "after", twips)
}

set_style_before <- function(styles, style_id, twips, ns) {
  st <- xml_find_first(
    styles,
    sprintf("//w:style[@w:styleId='%s']", style_id),
    ns
  )
  if (inherits(st, "xml_missing")) stop("Missing Word style: ", style_id, call. = FALSE)
  pPr <- ensure_child(st, "./w:pPr", "w:pPr", ns)
  spacing <- ensure_child(pPr, "./w:spacing", "w:spacing", ns)
  set_w_attr(spacing, "before", twips)
}

set_table_ratio <- function(tbl, left_fraction, ns) {
  grid_cols <- xml_find_all(tbl, "./w:tblGrid/w:gridCol", ns)
  if (length(grid_cols) != 2L) stop("Expected a two-column table", call. = FALSE)

  old_widths <- suppressWarnings(as.numeric(xml_attr(grid_cols, "w")))
  if (anyNA(old_widths) || sum(old_widths) <= 0) {
    stop("Could not read table grid widths", call. = FALSE)
  }
  total <- sum(old_widths)
  widths <- c(round(total * left_fraction), total - round(total * left_fraction))

  for (j in seq_along(grid_cols)) set_w_attr(grid_cols[[j]], "w", widths[[j]])

  tblPr <- ensure_child(tbl, "./w:tblPr", "w:tblPr", ns, where = 0)
  layout <- ensure_child(tblPr, "./w:tblLayout", "w:tblLayout", ns)
  set_w_attr(layout, "type", "fixed")

  rows <- xml_find_all(tbl, "./w:tr", ns)
  for (row in rows) {
    cells <- xml_find_all(row, "./w:tc", ns)
    if (length(cells) != 2L) next
    for (j in 1:2) {
      tcPr <- ensure_child(cells[[j]], "./w:tcPr", "w:tcPr", ns, where = 0)
      tcW <- ensure_child(tcPr, "./w:tcW", "w:tcW", ns)
      set_w_attr(tcW, "type", "dxa")
      set_w_attr(tcW, "w", widths[[j]])
    }
  }

  invisible(widths)
}

style_docx <- function(path) {
  if (!file.exists(path)) stop("DOCX not found: ", path, call. = FALSE)

  work <- tempfile("w09_docx_")
  dir.create(work)
  on.exit(unlink(work, recursive = TRUE, force = TRUE), add = TRUE)
  unzip(path, exdir = work)

  doc_path <- file.path(work, "word", "document.xml")
  styles_path <- file.path(work, "word", "styles.xml")
  if (!file.exists(doc_path) || !file.exists(styles_path)) {
    stop("Invalid DOCX package: ", path, call. = FALSE)
  }

  doc <- read_xml(doc_path)
  styles <- read_xml(styles_path)
  ns_doc <- xml_ns(doc)
  ns_styles <- xml_ns(styles)

  # Captions: 12 pt base -> 9.5 pt (nearest half-point to a 20% reduction).
  caption_paras <- xml_find_all(doc, "//w:p", ns_doc)
  caption_paras <- caption_paras[vapply(caption_paras, function(p) {
    grepl("^(Table|Figure)\\s+[0-9]+\\.", trimws(paragraph_text(p, ns_doc)))
  }, logical(1))]
  for (p in caption_paras) {
    set_run_size(p, 19L, ns_doc)
    set_paragraph_after(p, 240L, ns_doc) # 12 pt after
  }

  # Increase whitespace above headings and subheadings.
  set_style_before(styles, "Heading1", 600L, ns_styles) # 30 pt
  set_style_before(styles, "Heading2", 360L, ns_styles) # 18 pt
  set_style_before(styles, "Heading3", 320L, ns_styles) # 16 pt

  # Only the Methods manuscript contains Tables 1 and 2.
  if (identical(basename(path), "methods.docx")) {
    tables <- xml_find_all(doc, "//w:tbl", ns_doc)
    if (length(tables) < 2L) stop("Methods DOCX contains fewer than two tables", call. = FALSE)
    ratios <- lapply(tables[1:2], set_table_ratio, left_fraction = 0.25, ns = ns_doc)
    observed <- vapply(ratios, function(x) x[[1L]] / sum(x), numeric(1))
    if (any(abs(observed - 0.25) > 0.002)) {
      stop("Methods table column-width validation failed", call. = FALSE)
    }
  }

  write_xml(doc, doc_path)
  write_xml(styles, styles_path)

  out_tmp <- tempfile(fileext = ".docx")
  oldwd <- getwd()
  on.exit(setwd(oldwd), add = TRUE)
  setwd(work)
  status <- system2("zip", c("-q", "-r", shQuote(out_tmp), "."))
  setwd(oldwd)
  if (!identical(status, 0L) || !file.exists(out_tmp) || file.info(out_tmp)$size <= 0) {
    stop("Failed to rebuild DOCX: ", path, call. = FALSE)
  }
  if (!file.copy(out_tmp, path, overwrite = TRUE)) {
    stop("Failed to replace styled DOCX: ", path, call. = FALSE)
  }

  cat(sprintf(
    "PASS: styled %s (%d captions; heading spacing updated%s)\n",
    path,
    length(caption_paras),
    if (identical(basename(path), "methods.docx")) "; Tables 1-2 = 25/75" else ""
  ))
}

invisible(lapply(args, style_docx))
