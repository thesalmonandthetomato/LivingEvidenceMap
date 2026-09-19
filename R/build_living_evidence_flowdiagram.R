#!/usr/bin/env Rscript

# Living Evidence Map flow diagram
#
# PRISMA 2020-inspired layout implemented directly with DiagrammeR/Graphviz.
# The geometry, palette defaults and section-label treatment follow the
# open-source PRISMA2020 R package by Haddaway et al., but the node structure is
# deliberately adapted for a living evidence map with title/abstract screening
# and no full-text eligibility stage.
#
# Reference implementation:
# https://github.com/prisma-flowdiagram/PRISMA2020
#
# This script does NOT feed the dashboard yet. First finalise the standalone
# diagram and its data semantics; dashboard integration comes afterwards.

suppressPackageStartupMessages({
  library(DiagrammeR)
  library(stringr)
})

or_default <- function(x, y) {
  if (is.null(x) || length(x) == 0) y else x
}

fmt_n <- function(x) {
  if (length(x) != 1 || is.na(x)) return("NA")
  format(as.integer(x), big.mark = ",", scientific = FALSE, trim = TRUE)
}

dot_escape <- function(x) {
  x <- as.character(or_default(x, ""))
  x <- gsub("\\", "\\\\", x, fixed = TRUE)
  x <- gsub("'", "\\'", x, fixed = TRUE)
  x <- gsub("\n", "\\n", x, fixed = TRUE)
  x
}

living_evidence_flow_data <- function(
    database_results,
    duplicates_removed = 0L,
    other_removed_before_screening = 0L,
    records_screened,
    records_excluded,
    records_included,
    search_date = NA_character_) {

  if (is.null(names(database_results)) ||
      any(!nzchar(trimws(names(database_results))))) {
    stop("database_results must be a named numeric vector.", call. = FALSE)
  }

  database_results <- as.integer(database_results)
  names(database_results) <- trimws(names(database_results))

  numeric_fields <- c(
    database_results,
    duplicates_removed,
    other_removed_before_screening,
    records_screened,
    records_excluded,
    records_included
  )

  if (any(is.na(numeric_fields)) || any(numeric_fields < 0)) {
    stop("All flow counts must be known, non-negative integers.", call. = FALSE)
  }

  identified <- sum(database_results)
  removed_before <- as.integer(duplicates_removed) +
    as.integer(other_removed_before_screening)

  if (identified - removed_before != as.integer(records_screened)) {
    stop(
      sprintf(
        paste0(
          "Identification arithmetic is inconsistent: identified (%s) - ",
          "removed before screening (%s) != screened (%s)."
        ),
        fmt_n(identified),
        fmt_n(removed_before),
        fmt_n(records_screened)
      ),
      call. = FALSE
    )
  }

  if (as.integer(records_screened) - as.integer(records_excluded) !=
      as.integer(records_included)) {
    stop(
      sprintf(
        paste0(
          "Screening arithmetic is inconsistent: screened (%s) - excluded (%s) ",
          "!= included (%s)."
        ),
        fmt_n(records_screened),
        fmt_n(records_excluded),
        fmt_n(records_included)
      ),
      call. = FALSE
    )
  }

  list(
    database_results = database_results,
    total_identified = identified,
    duplicates_removed = as.integer(duplicates_removed),
    other_removed_before_screening = as.integer(other_removed_before_screening),
    records_screened = as.integer(records_screened),
    records_excluded = as.integer(records_excluded),
    records_included = as.integer(records_included),
    search_date = as.character(search_date)
  )
}

living_evidence_flowdiagram <- function(
    data,
    fontsize = 10,
    font = "Helvetica",
    title_colour = "Goldenrod1",
    greybox_colour = "Gainsboro",
    section_colour = "LightSteelBlue2",
    main_colour = "Black",
    arrow_colour = "Black",
    side_boxes = TRUE,
    show_note = TRUE) {

  required <- c(
    "database_results",
    "total_identified",
    "duplicates_removed",
    "other_removed_before_screening",
    "records_screened",
    "records_excluded",
    "records_included"
  )
  missing <- setdiff(required, names(data))
  if (length(missing)) {
    stop(
      "Flow data missing required fields: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }

  db_lines <- paste0(
    names(data$database_results),
    " (n = ",
    vapply(data$database_results, fmt_n, character(1)),
    ")"
  )

  identified_label <- paste0(
    "Records identified from databases:\n",
    paste(db_lines, collapse = "\n"),
    "\nTotal (n = ",
    fmt_n(data$total_identified),
    ")"
  )

  removal_lines <- character()
  if (data$duplicates_removed > 0) {
    removal_lines <- c(
      removal_lines,
      paste0(
        "Duplicate records removed (n = ",
        fmt_n(data$duplicates_removed),
        ")"
      )
    )
  }
  if (data$other_removed_before_screening > 0) {
    removal_lines <- c(
      removal_lines,
      paste0(
        "Other records removed before screening (n = ",
        fmt_n(data$other_removed_before_screening),
        ")"
      )
    )
  }
  if (!length(removal_lines)) {
    removal_lines <- "No records removed before screening (n = 0)"
  }

  removed_label <- paste0(
    "Records removed before screening:\n",
    paste(removal_lines, collapse = "\n")
  )

  screened_label <- paste0(
    "Records screened at title and abstract\n(n = ",
    fmt_n(data$records_screened),
    ")"
  )

  excluded_label <- paste0(
    "Records excluded at title and abstract\n(n = ",
    fmt_n(data$records_excluded),
    ")"
  )

  included_label <- paste0(
    "Records included in the Living Evidence Map\n(n = ",
    fmt_n(data$records_included),
    ")"
  )

  note_label <- "No full-text screening stage is included in the current workflow."

  pos <- list(
    identified = c(4.7, 9.8),
    removed = c(9.0, 9.8),
    screened = c(4.7, 6.8),
    excluded = c(9.0, 6.8),
    included = c(4.7, 3.8),
    note = c(4.7, 2.0),
    identification_section = c(1.0, 9.8),
    screening_section = c(1.0, 6.8),
    included_section = c(1.0, 3.8)
  )

  node <- function(
      id,
      label,
      xy,
      width = 3.7,
      height = 1.2,
      fill = greybox_colour,
      rounded = FALSE,
      bold = FALSE,
      border = main_colour) {

    style <- if (rounded) "rounded,filled" else "filled"
    lab <- dot_escape(label)

    paste0(
      id, " [",
      "label='", lab, "', ",
      "shape=box, ",
      "style='", style, "', ",
      "fillcolor='", fill, "', ",
      "color='", border, "', ",
      "fontcolor='", main_colour, "', ",
      "fontname='", font, "', ",
      "fontsize=", fontsize, ", ",
      "penwidth=", if (bold) "1.7" else "1.0", ", ",
      "width=", width, ", ",
      "height=", height, ", ",
      "fixedsize=false, ",
      "margin='0.16,0.10', ",
      "pos='", xy[[1]], ",", xy[[2]], "!'",
      "];"
    )
  }

  section_node <- function(id, label, xy) {
    paste0(
      id, " [",
      "label='", dot_escape(label), "', ",
      "shape=box, ",
      "style='rounded,filled', ",
      "fillcolor='", section_colour, "', ",
      "color='", section_colour, "', ",
      "fontcolor='", main_colour, "', ",
      "fontname='", font, "', ",
      "fontsize=", fontsize, ", ",
      "width=1.55, ",
      "height=0.55, ",
      "pos='", xy[[1]], ",", xy[[2]], "!'",
      "];"
    )
  }

  nodes <- c(
    node(
      "identified",
      identified_label,
      pos$identified,
      fill = title_colour,
      rounded = TRUE
    ),
    node("removed", removed_label, pos$removed),
    node("screened", screened_label, pos$screened),
    node("excluded", excluded_label, pos$excluded),
    node(
      "included",
      included_label,
      pos$included,
      fill = greybox_colour,
      bold = TRUE
    )
  )

  if (show_note) {
    nodes <- c(
      nodes,
      node(
        "note",
        note_label,
        pos$note,
        width = 4.1,
        height = 0.65,
        fill = "White",
        rounded = TRUE,
        border = "Grey60"
      )
    )
  }

  if (side_boxes) {
    nodes <- c(
      nodes,
      section_node(
        "section_identification",
        "Identification",
        pos$identification_section
      ),
      section_node(
        "section_screening",
        "Screening",
        pos$screening_section
      ),
      section_node(
        "section_included",
        "Included",
        pos$included_section
      )
    )
  }

  edges <- c(
    paste0(
      "identified -> screened [",
      "color='", arrow_colour, "', arrowhead=normal, penwidth=1.0];"
    ),
    paste0(
      "identified -> removed [",
      "color='", arrow_colour, "', arrowhead=normal, penwidth=1.0, ",
      "constraint=false];"
    ),
    paste0(
      "screened -> excluded [",
      "color='", arrow_colour, "', arrowhead=normal, penwidth=1.0, ",
      "constraint=false];"
    ),
    paste0(
      "screened -> included [",
      "color='", arrow_colour, "', arrowhead=normal, penwidth=1.0];"
    )
  )

  if (show_note) {
    edges <- c(
      edges,
      paste0(
        "included -> note [",
        "color='Grey60', style=dashed, arrowhead=none, penwidth=0.8];"
      )
    )
  }

  graph <- paste0(
    "digraph living_evidence_flow {\n",
    "graph [layout=neato, overlap=false, splines=ortho, outputorder=edgesfirst, ",
    "bgcolor='transparent', pad=0.25];\n",
    "node [shape=box];\n",
    paste(nodes, collapse = "\n"), "\n",
    paste(edges, collapse = "\n"), "\n",
    "}\n"
  )

  DiagrammeR::grViz(graph)
}

export_living_evidence_flow_svg <- function(widget, path) {
  if (!requireNamespace("DiagrammeRsvg", quietly = TRUE)) {
    stop("Install DiagrammeRsvg to export SVG.", call. = FALSE)
  }
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  svg <- DiagrammeRsvg::export_svg(widget)
  writeLines(svg, path, useBytes = TRUE)
  invisible(path)
}

# DEVELOPMENT EXAMPLE ONLY
#
# Verified search information currently available in the repository:
#   Lens baseline on 2026-08-24: 21,851
#   Additional candidate results on 2026-09-07: 48
#
# Complete deduplication and title/abstract screening counts should be supplied
# from provenance outputs before this is promoted into production.
#
# Example:
#
# flow_data <- living_evidence_flow_data(
#   database_results = c("Lens" = 21899),
#   duplicates_removed = 0,
#   other_removed_before_screening = 8510,
#   records_screened = 13389,
#   records_excluded = 0,
#   records_included = 13389,
#   search_date = "2026-09-14"
# )
#
# p <- living_evidence_flowdiagram(flow_data)
# p
# export_living_evidence_flow_svg(
#   p,
#   "outputs/workflow07/evidence_flowdiagram.svg"
# )
