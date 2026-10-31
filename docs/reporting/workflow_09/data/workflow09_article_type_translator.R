# Workflow 09 publication-type display translator, consumed by Workflow 10.
# Source labels are retained unchanged in canonical JSONL.
# Exactly one dashboard article type is selected using precedence.
workflow09_article_type_order <- c(
  "Journal article", "Book chapter", "Conference paper",
  "Preprint", "Thesis", "Report", "Other"
)

workflow09_article_type_labels <- function(values) {
  x <- as.character(unlist(values, use.names=FALSE))
  x <- unique(tolower(trimws(gsub("[[:space:]]+", " ", x[!is.na(x)]))))
  x <- x[nzchar(x)]
  if(!length(x)) return(character())

  out <- character()
  for(v in x) {
    categories <- character()
    # A few providers concatenate multiple publication formats into one value.
    if(v %in% c("article", "jour", "journal article", "review",
                "research article", "peer-reviewed article",
                "journal article [online]", "literature review") ||
       grepl("journal article", v, fixed=TRUE)) {
      categories <- c(categories, "Journal article")
    }
    if(v %in% c("book-chapter", "book chapter", "chap") ||
       grepl("book chapter", v, fixed=TRUE)) {
      categories <- c(categories, "Book chapter")
    }
    if(v %in% c("cpaper", "conference-paper", "conference paper",
                "conf", "conference proceedings", "conference proceedings article",
                "conference proceedings / symposia [online]",
                "conference proceedings [online]", "conference-abstract",
                "symposium", "proceeding") ||
       grepl("conference paper", v, fixed=TRUE) ||
       grepl("conference proceedings", v, fixed=TRUE)) {
      categories <- c(categories, "Conference paper")
    }
    if(v=="preprint") categories <- c(categories, "Preprint")
    if(v %in% c("dissertation", "thes", "thesis", "thèse et mémoire",
                "thesis abstract [online]", "licentiate", "master", "master's",
                "ph.d.", "d.phil.", "dr.sc.", "dr.scient.", "dr.phil.",
                "dr.ing.", "dr.nat.", "dr.agr.", "d.eng.", "d.sc.",
                "fil.dr.", "vet.med.dr.") ||
       grepl("^(m\\.|dr\\.|ph\\.|d\\.)", v)) {
      categories <- c(categories, "Thesis")
    }
    if(v %in% c("report", "reports", "rprt", "annual report",
                "working paper", "web documentadvisory/extension reports; fact sheets, posters") ||
       grepl("annual report", v, fixed=TRUE)) {
      categories <- c(categories, "Report")
    }
    out <- c(out, categories)
  }
  unique(out)
}

workflow09_article_type <- function(values) {
  labels <- workflow09_article_type_labels(values)
  winner <- workflow09_article_type_order[workflow09_article_type_order %in% labels]
  if(length(winner)) winner[[1L]] else "Other"
}

# Deterministic guardrails for priority and ambiguous source labels.
stopifnot(
  identical(workflow09_article_type(c("JOUR","article","Review")), "Journal article"),
  identical(workflow09_article_type(c("THES","preprint")), "Preprint"),
  identical(workflow09_article_type(c("Ph.D.","Journal Article")), "Journal article"),
  identical(workflow09_article_type(c("CPAPER","book-chapter")), "Book chapter"),
  identical(workflow09_article_type(c("Report","preprint")), "Preprint"),
  identical(workflow09_article_type("Journal article Conference paper"), "Journal article"),
  identical(workflow09_article_type("Book chapter Conference paper"), "Book chapter"),
  identical(workflow09_article_type("Comparative Study"), "Other"),
  identical(workflow09_article_type(NULL), "Other")
)
