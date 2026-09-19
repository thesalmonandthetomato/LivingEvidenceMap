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
    excluded_topic_coding_missing_abstracts,
    records_with_topic_coding,
    search_date = NA_character_,
    draft = FALSE) {

  if (is.null(names(database_results)) ||
      any(!nzchar(trimws(names(database_results))))) {
    stop("database_results must be a named numeric vector.", call. = FALSE)
  }

  database_names <- trimws(names(database_results))
  database_results <- suppressWarnings(as.integer(database_results))
  names(database_results) <- database_names

  numeric_fields <- c(
    database_results,
    duplicates_removed,
    other_removed_before_screening,
    records_screened,
    records_excluded,
    records_included,
    excluded_topic_coding_missing_abstracts,
    records_with_topic_coding
  )

  if (!isTRUE(draft) && (any(is.na(numeric_fields)) || any(numeric_fields < 0))) {
    stop("All flow counts must be known, non-negative integers in production mode.", call. = FALSE)
  }

  identified <- if (all(!is.na(database_results))) sum(database_results) else NA_integer_
  removed_before <- if (!is.na(duplicates_removed) && !is.na(other_removed_before_screening)) {
    as.integer(duplicates_removed) + as.integer(other_removed_before_screening)
  } else {
    NA_integer_
  }

  if (!isTRUE(draft) && identified - removed_before != as.integer(records_screened)) {
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

  if (!isTRUE(draft) &&
      as.integer(records_screened) - as.integer(records_excluded) !=
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

  if (!isTRUE(draft) &&
      as.integer(records_included) -
      as.integer(excluded_topic_coding_missing_abstracts) !=
      as.integer(records_with_topic_coding)) {
    stop(
      sprintf(
        paste0(
          "Topic-coding arithmetic is inconsistent: included (%s) - ",
          "missing abstracts (%s) != with topic coding (%s)."
        ),
        fmt_n(records_included),
        fmt_n(excluded_topic_coding_missing_abstracts),
        fmt_n(records_with_topic_coding)
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
    excluded_topic_coding_missing_abstracts =
      as.integer(excluded_topic_coding_missing_abstracts),
    records_with_topic_coding = as.integer(records_with_topic_coding),
    search_date = as.character(search_date),
    draft = isTRUE(draft)
  )
}

living_evidence_flowdiagram <- function(
    data,
    fontsize = 10,
    font = "Helvetica",
    title_colour = "#e55634",
    greybox_colour = "#eef2f1",
    section_colour = "#a8bdbe",
    main_colour = "#2c454a",
    arrow_colour = "#577c84",
    side_boxes = TRUE,
    show_note = TRUE) {

  required <- c(
    "database_results",
    "total_identified",
    "duplicates_removed",
    "other_removed_before_screening",
    "records_screened",
    "records_excluded",
    "records_included",
    "excluded_topic_coding_missing_abstracts",
    "records_with_topic_coding"
  )
  missing <- setdiff(required, names(data))
  if (length(missing)) {
    stop(
      "Flow data missing required fields: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }

  display_n <- function(x) if (length(x) != 1 || is.na(x)) "TBC" else fmt_n(x)

  if (isTRUE(data$draft)) {
    db_lines <- paste0(names(data$database_results), " (n = TBC)")
    identified_label <- paste0(
      "Records identified from databases\n",
      paste(db_lines, collapse = "\n")
    )
  } else {
    db_lines <- paste0(
      names(data$database_results),
      " (n = ",
      vapply(data$database_results, display_n, character(1)),
      ")"
    )
    identified_label <- paste0(
      "Records identified from databases\n",
      paste(db_lines, collapse = "\n"),
      "\nTotal (n = ",
      display_n(data$total_identified),
      ")"
    )
  }

  removal_lines <- character()
  if (!is.na(data$duplicates_removed) && data$duplicates_removed > 0) {
    removal_lines <- c(
      removal_lines,
      paste0(
        "Duplicate records removed (n = ",
        display_n(data$duplicates_removed),
        ")"
      )
    )
  }
  if (!is.na(data$other_removed_before_screening) &&
      data$other_removed_before_screening > 0) {
    removal_lines <- c(
      removal_lines,
      paste0(
        "Retractions and withdrawals (n = ",
        display_n(data$other_removed_before_screening),
        ")"
      )
    )
  }
  if (!length(removal_lines)) {
    if (isTRUE(data$draft) &&
        (is.na(data$duplicates_removed) ||
         is.na(data$other_removed_before_screening))) {
      removal_lines <- c(
        "Duplicate records removed (n = TBC)",
        "Retractions and withdrawals (n = TBC)"
      )
    } else {
      removal_lines <- "No records removed before screening (n = 0)"
    }
  }

  removed_label <- paste0(
    "Records removed before screening\n",
    paste(removal_lines, collapse = "\n")
  )

  screened_label <- paste0(
    "Records screened at title and abstract\n(n = ",
    display_n(data$records_screened),
    ")"
  )

  excluded_label <- paste0(
    "Records excluded at title and abstract\n(n = ",
    display_n(data$records_excluded),
    ")"
  )

  included_label <- paste0(
    "Records included in the Living Evidence Map\n(n = ",
    display_n(data$records_included),
    ")"
  )

  topic_excluded_label <- paste0(
    "Excluded from topic coding - missing abstracts\n(n = ",
    display_n(data$excluded_topic_coding_missing_abstracts),
    ")"
  )

  topic_included_label <- paste0(
    "Records assigned topic codes\n(n = ",
    display_n(data$records_with_topic_coding),
    ")"
  )

  note_label <- "No full-text screening stage is included in the current workflow."

  pos <- list(
    identified = c(3.7, 6.9),
    removed = c(9.3, 6.9),
    screened = c(3.7, 4.9),
    excluded = c(9.3, 4.9),
    included = c(3.7, 2.9),
    topic_excluded = c(9.3, 2.9),
    topic_included = c(3.7, 0.9),
    note = c(3.7, -0.45),
    identification_section = c(0.75, 6.9),
    screening_section = c(0.75, 4.9),
    included_section = c(0.75, 2.9),
    topic_coding_section = c(0.75, 0.9)
  )

  node <- function(
      id,
      label,
      xy,
      width = 4.15,
      height = 0.72,
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
      "pin=true, ",
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
      "width=0.48, ",
      "height=1.55, ",
      "pin=true, ",
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
    ),
    node(
      "topic_excluded",
      topic_excluded_label,
      pos$topic_excluded
    ),
    node(
      "topic_included",
      topic_included_label,
      pos$topic_included,
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
        width = 4.15,
        height = 0.48,
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
        " ",
        pos$identification_section
      ),
      section_node(
        "section_screening",
        " ",
        pos$screening_section
      ),
      section_node(
        "section_included",
        " ",
        pos$included_section
      ),
      section_node(
        "section_topic_coding",
        " ",
        pos$topic_coding_section
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
    ),
    paste0(
      "included -> topic_excluded [",
      "color='", arrow_colour, "', arrowhead=normal, penwidth=1.0, ",
      "constraint=false];"
    ),
    paste0(
      "included -> topic_included [",
      "color='", arrow_colour, "', arrowhead=normal, penwidth=1.0];"
    )
  )

  if (show_note) {
    edges <- c(
      edges,
      paste0(
        "topic_included -> note [",
        "color='Grey60', style=dashed, arrowhead=none, penwidth=0.8];"
      )
    )
  }

  graph <- paste0(
    "digraph living_evidence_flow {\n",
    "graph [layout=neato, overlap=true, splines=ortho, outputorder=edgesfirst, ",
    "bgcolor='White', pad=0.12];\n",
    "node [shape=box];\n",
    paste(nodes, collapse = "\n"), "\n",
    paste(edges, collapse = "\n"), "\n",
    "}\n"
  )

  plot <- DiagrammeR::grViz(graph)

  if (side_boxes) {
    # PRISMA2020 approach: Graphviz renders blank labels, then JavaScript
    # inserts and rotates the SVG text after rendering. Target by node title
    # rather than generated node number so declaration order cannot break it.
    javascript <- htmltools::HTML("
      const labelMap = new Map([
        ['section_identification', 'Identification'],
        ['section_screening', 'Screening'],
        ['section_included', 'Included'],
        ['section_topic_coding', 'Topic coding']
      ]);
      document.querySelectorAll('g.node').forEach(function(node) {
        const title = node.querySelector('title');
        if (!title || !labelMap.has(title.textContent)) return;
        const txt = node.querySelector('text');
        const shape = node.querySelector('path, polygon, ellipse');
        if (!txt || !shape) return;

        const box = shape.getBBox();
        const cx = box.x + box.width / 2;
        const cy = box.y + box.height / 2;

        txt.setAttribute('x', cx);
        txt.setAttribute('y', cy);
        txt.setAttribute('text-anchor', 'middle');
        txt.setAttribute('dominant-baseline', 'middle');
        txt.setAttribute('transform', 'rotate(-90 ' + cx + ' ' + cy + ')');
        txt.removeAttribute('style');
        txt.textContent = labelMap.get(title.textContent);
      });
    ")
    plot <- htmlwidgets::appendContent(
      plot,
      htmlwidgets::onStaticRenderComplete(javascript)
    )
  }

  plot
}

export_living_evidence_flow_svg <- function(widget, path) {
  if (!requireNamespace("DiagrammeRsvg", quietly = TRUE)) {
    stop("Install DiagrammeRsvg to export SVG.", call. = FALSE)
  }

  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  svg <- DiagrammeRsvg::export_svg(widget)

  # DiagrammeRsvg exports before the PRISMA-style JavaScript executes.
  # Rebuild each side-label <text> element cleanly in the static SVG rather
  # than appending attributes to Graphviz's original tag.
  rotate_static_label <- function(svg_text, node_id, label) {
    node_pattern <- paste0(
      "(<g[^>]*class=\\\"node\\\"[^>]*>[\\s\\S]*?<title>",
      node_id,
      "</title>[\\s\\S]*?)(<text[^>]*x=\\\"([^\\\"]+)\\\" ",
      "y=\\\"([^\\\"]+)\\\"[^>]*>[^<]*</text>)"
    )

    m <- regexec(node_pattern, svg_text, perl = TRUE)
    hit <- regmatches(svg_text, m)[[1]]

    if (!length(hit)) {
      stop("Could not locate static SVG side label node: ", node_id, call. = FALSE)
    }

    x <- as.numeric(hit[4])
    y <- as.numeric(hit[5]) - 3

    clean_text <- paste0(
      "<text text-anchor=\\\"middle\\\"",
      " x=\\\"", x, "\\\"",
      " y=\\\"", y, "\\\"",
      " font-family=\\\"Helvetica,sans-Serif\\\"",
      " font-size=\\\"10.00\\\"",
      " fill=\\\"#000000\\\"",
      " dominant-baseline=\\\"middle\\\"",
      " transform=\\\"rotate(-90 ", x, " ", y, ")\\\">",
      label,
      "</text>"
    )

    replacement <- paste0(hit[2], clean_text)
    sub(node_pattern, replacement, svg_text, perl = TRUE)
  }

  svg <- rotate_static_label(svg, "section_identification", "Identification")
  svg <- rotate_static_label(svg, "section_screening", "Screening")
  svg <- rotate_static_label(svg, "section_included", "Included")
  svg <- rotate_static_label(svg, "section_topic_coding", "Topic coding")

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
# Draft design preview:
#
# flow_data <- living_evidence_flow_data(
#   database_results = c(
#     "Lens" = NA,
#     "Scopus" = NA,
#     "Web of Science Core Collection" = NA,
#     "OpenAlex" = NA
#   ),
#   duplicates_removed = NA,
#   other_removed_before_screening = NA,
#   records_screened = NA,
#   records_excluded = NA,
#   records_included = NA,
#   excluded_topic_coding_missing_abstracts = NA,
#   records_with_topic_coding = NA,
#   search_date = NA,
#   draft = TRUE
# )
#
# p <- living_evidence_flowdiagram(flow_data)
# p
# export_living_evidence_flow_svg(
#   p,
#   "outputs/workflow07/evidence_flowdiagram.svg"
# )
