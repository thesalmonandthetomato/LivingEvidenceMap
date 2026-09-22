#!/usr/bin/env Rscript

# WORKFLOW 07 TODO
# After Workflow 06 topic coding is complete, embed the approved Living Evidence
# Map flow diagram immediately below the dashboard choropleth. Populate all flow
# counts programmatically from update/provenance outputs (database retrieval,
# deduplication, title/abstract screening, retained records, records excluded
# from topic coding because abstracts are missing, and records assigned topic
# codes). Do not hand-enter counts.
#
suppressPackageStartupMessages({
  library(jsonlite)
  library(readr)
})

args <- commandArgs(trailingOnly = TRUE)
source_jsonl <- if (length(args) >= 1) args[[1]] else "data/canonical/current/repair/records.jsonl"
out_csv <- if (length(args) >= 2) args[[2]] else "docs/living_evidence_map_static.csv"
out_js <- if (length(args) >= 3) args[[3]] else "docs/dashboard-data.js"

ontology_path <- Sys.getenv("TOPIC_ONTOLOGY_PATH", "data/reference/topic_ontology_v3_6.csv")
iso_map_path <- Sys.getenv("ISO_NUMERIC_MAP_PATH", "config/iso3_numeric_map.json")
gazetteer_path <- Sys.getenv("COUNTRY_GAZETTEER_PATH", "config/global_country_gazetteer_v3.csv")

stopf <- function(...) stop(sprintf(...), call. = FALSE)
trim <- function(x) trimws(as.character(x %||% ""))
`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

scalar <- function(x) {
  if (is.null(x) || length(x) == 0) return("")
  if (is.list(x) && !is.data.frame(x)) {
    if (length(x) == 1 && !is.list(x[[1]])) return(as.character(x[[1]] %||% ""))
    return("")
  }
  as.character(x[[1]] %||% "")
}

first_field <- function(rec, names, default = "") {
  for (nm in names) {
    if (!is.null(rec[[nm]])) return(rec[[nm]])
  }
  default
}

vec <- function(x) {
  if (is.null(x) || length(x) == 0) return(character())
  if (is.list(x) && !is.data.frame(x)) {
    if (all(vapply(x, function(z) !is.list(z), logical(1)))) {
      y <- unlist(x, use.names = FALSE)
    } else {
      return(character())
    }
  } else {
    y <- unlist(x, use.names = FALSE)
  }
  y <- trimws(as.character(y))
  y <- y[nzchar(y) & !tolower(y) %in% c("na","n/a","nan","null","none","unknown")]
  unique(y)
}

split_semis <- function(x) {
  s <- trim(x)
  if (!nzchar(s)) return(character())
  trimws(strsplit(s, "\\s*;\\s*", perl = TRUE)[[1]])
}

safe_year <- function(x) {
  z <- suppressWarnings(as.integer(substr(trim(x), 1, 4)))
  if (is.na(z) || z < 1800 || z > 2200) return("")
  as.character(z)
}

if (!file.exists(source_jsonl)) stopf("Canonical JSONL not found: %s", source_jsonl)
if (!file.exists(ontology_path)) stopf("Ontology not found: %s", ontology_path)

ontology <- read_csv(ontology_path, show_col_types = FALSE, progress = FALSE)
required_ontology <- c("path_id","level_1","level_2","level_3","hierarchy_path","definition")
missing_ontology <- setdiff(required_ontology, names(ontology))
if (length(missing_ontology)) stopf("Ontology missing columns: %s", paste(missing_ontology, collapse=", "))

if (anyDuplicated(ontology$path_id)) stopf("Ontology path_id values are not unique")
if (any(!grepl("^V3_[0-9]{3}$", ontology$path_id))) stopf("Ontology contains invalid V3 path_id values")

onto_by_id <- split(ontology, ontology$path_id)

read_jsonl_records <- function(path) {
  con <- file(path, open = "r", encoding = "UTF-8")
  on.exit(close(con), add = TRUE)
  records <- list()
  n <- 0L
  repeat {
    lines <- readLines(con, n = 1000L, warn = FALSE)
    if (!length(lines)) break
    lines <- lines[nzchar(trimws(lines))]
    for (line in lines) {
      n <- n + 1L
      rec <- tryCatch(
        fromJSON(line, simplifyVector = FALSE),
        error = function(e) stopf("Invalid JSONL at non-empty line %d: %s", n, conditionMessage(e))
      )
      if (!is.list(rec)) stopf("Canonical JSONL line %d is not a JSON object", n)
      records[[length(records) + 1L]] <- rec
    }
  }
  records
}

records <- read_jsonl_records(source_jsonl)
raw <- list()
if (!length(records)) stopf("Canonical JSONL contains no records")

normalise_topics <- function(rec, rec_id) {
  topics <- first_field(rec, c("topics","topic_assignments"), list())
  if (is.null(topics) || length(topics) == 0) return(list())
  if (!is.list(topics)) stopf("Record %s topics are not structured objects", rec_id)

  out <- list()
  for (i in seq_along(topics)) {
    t <- topics[[i]]
    if (!is.list(t)) stopf("Record %s topic %d is not an object", rec_id, i)
    id <- scalar(t$path_id %||% t$code)
    if (!nzchar(id)) stopf("Record %s topic %d has no path_id", rec_id, i)
    if (is.null(onto_by_id[[id]])) stopf("Record %s uses unknown ontology path_id %s", rec_id, id)

    stars <- suppressWarnings(as.integer(scalar(t$stars)))
    if (is.na(stars) || !stars %in% 1:3) stopf("Record %s topic %s has invalid stars=%s", rec_id, id, scalar(t$stars))

    o <- onto_by_id[[id]][1,]
    out[[length(out)+1]] <- list(
      path_id = id,
      hierarchy_path = as.character(o$hierarchy_path[[1]]),
      stars = stars
    )
  }

  ids <- vapply(out, `[[`, "", "path_id")
  if (anyDuplicated(ids)) stopf("Record %s contains duplicate topic path_id values", rec_id)
  out[order(ids)]
}

rows <- vector("list", length(records))
seen_ids <- character()

for (i in seq_along(records)) {
  rec <- records[[i]]
  if (!is.list(rec)) stopf("Record %d is not a JSON object", i)

  lens_id <- scalar(first_field(rec, c("lens_id","record_id","id"), ""))
  record_id <- scalar(first_field(rec, c("record_id","lens_id","id"), ""))
  stable_id <- if (nzchar(record_id)) record_id else lens_id
  if (!nzchar(stable_id)) stopf("Record %d has no record_id/lens_id", i)
  if (stable_id %in% seen_ids) stopf("Duplicate canonical record identifier: %s", stable_id)
  seen_ids <- c(seen_ids, stable_id)

  topics <- normalise_topics(rec, stable_id)
  topic_ids <- if (length(topics)) vapply(topics, `[[`, "", "path_id") else character()
  topic_paths <- if (length(topics)) vapply(topics, `[[`, "", "hierarchy_path") else character()
  topic_stars <- if (length(topics)) vapply(topics, `[[`, integer(1), "stars") else integer()

  coding <- first_field(rec, c("topic_coding"), list())
  coded_at <- scalar(coding$coded_at %||% rec$topic_coded_at %||% "")
  ontology_version <- scalar(coding$ontology_version %||% rec$topic_ontology_version %||% "3.6")
  coding_model <- scalar(coding$model %||% rec$topic_coding_model %||% "")
  independent_runs <- scalar(coding$independent_runs %||% rec$topic_independent_runs %||% "")

  species <- vec(first_field(rec, c("species","final_species","farmed_species"), character()))
  if (!length(species)) species <- "Unspecified species"
  iso3 <- toupper(vec(first_field(rec, c("iso3","countries_iso3","final_primary_country_iso3c","country_iso3"), character())))
  countries <- vec(first_field(rec, c("countries","country_names","country"), character()))

  authors <- first_field(rec, c("authors","author","author_names"), "")
  if (is.list(authors)) authors <- paste(vec(authors), collapse="; ")

  rows[[i]] <- data.frame(
    record_id = stable_id,
    lens_id = lens_id,
    title = scalar(first_field(rec, c("title","article_title"), "")),
    abstract = scalar(first_field(rec, c("abstract","abstract_text"), "")),
    doi = scalar(first_field(rec, c("doi","digital_object_identifier"), "")),
    year = safe_year(first_field(rec, c("year","publication_year"), "")),
    authors = scalar(authors),
    journal = scalar(first_field(rec, c("journal","source_title","publication"), "")),
    volume = scalar(first_field(rec, c("volume"), "")),
    issue = scalar(first_field(rec, c("issue"), "")),
    pages = scalar(first_field(rec, c("pages","page_range"), "")),
    lens_url = scalar(first_field(rec, c("lens_url","url"), "")),
    species = paste(species, collapse="; "),
    iso3 = paste(iso3, collapse="; "),
    countries = paste(countries, collapse="; "),
    topic_path_ids = paste(topic_ids, collapse="; "),
    topic_hierarchy_paths = paste(topic_paths, collapse="; "),
    topic_stars = paste(topic_stars, collapse="; "),
    topic_coded_at = coded_at,
    topic_ontology_version = ontology_version,
    topic_coding_model = coding_model,
    topic_independent_runs = independent_runs,
    stringsAsFactors = FALSE
  )
}

flat <- do.call(rbind, rows)

# Critical alignment audit: IDs, hierarchy paths and stars must remain one-to-one.
for (i in seq_len(nrow(flat))) {
  a <- split_semis(flat$topic_path_ids[[i]])
  b <- split_semis(flat$topic_hierarchy_paths[[i]])
  c <- split_semis(flat$topic_stars[[i]])
  if (!(length(a) == length(b) && length(b) == length(c))) {
    stopf("Topic alignment failure in record %s: ids=%d paths=%d stars=%d",
          flat$record_id[[i]], length(a), length(b), length(c))
  }
}

dir.create(dirname(out_csv), recursive = TRUE, showWarnings = FALSE)
write_csv(flat, out_csv, na = "")

# Build browser-optimised dashboard data strictly from the CSV just written.
csv <- read_csv(out_csv, show_col_types = FALSE, progress = FALSE, col_types = cols(.default = col_character()))

iso_numeric <- list()
if (file.exists(iso_map_path)) {
  x <- fromJSON(iso_map_path, simplifyVector = TRUE)
  if (is.list(x) || is.vector(x)) iso_numeric <- as.list(x)
}

country_name_by_iso3 <- list()
if (file.exists(gazetteer_path)) {
  g <- suppressWarnings(read_csv(gazetteer_path, show_col_types = FALSE, progress = FALSE))
  iso_col <- intersect(c("iso3","iso3c","alpha3","iso_a3"), names(g))
  name_col <- intersect(c("country_name","name","country","name_en"), names(g))
  if (length(iso_col) && length(name_col)) {
    iso_col <- iso_col[[1]]
    name_col <- name_col[[1]]
    for (j in seq_len(nrow(g))) {
      k <- toupper(trim(g[[iso_col]][[j]]))
      v <- trim(g[[name_col]][[j]])
      if (nzchar(k) && nzchar(v)) country_name_by_iso3[[k]] <- v
    }
  }
}

topic_definitions <- setNames(as.list(as.character(ontology$definition)), as.character(ontology$hierarchy_path))
topic_path_id_by_path <- setNames(as.list(as.character(ontology$path_id)), as.character(ontology$hierarchy_path))

dash_records <- vector("list", nrow(csv))
species_counts <- list()
country_counts <- list()
country_species <- list()
topic_record_sets <- new.env(parent = emptyenv())
topic_tree <- list()

inc <- function(lst, key, n=1L) {
  lst[[key]] <- as.integer(lst[[key]] %||% 0L) + n
  lst
}

tree_add <- function(tree, parts, rid) {
  if (!length(parts)) return(tree)
  name <- parts[[1]]
  node <- tree[[name]] %||% list(count=0L, children=list(), ids=character())
  if (!(rid %in% node$ids)) {
    node$ids <- c(node$ids, rid)
    node$count <- length(node$ids)
  }
  if (length(parts) > 1) node$children <- tree_add(node$children, parts[-1], rid)
  tree[[name]] <- node
  tree
}

for (i in seq_len(nrow(csv))) {
  r <- csv[i,]
  sp <- split_semis(r$species[[1]])
  isos <- toupper(split_semis(r$iso3[[1]]))
  countries <- split_semis(r$countries[[1]])
  ids <- split_semis(r$topic_path_ids[[1]])
  paths <- split_semis(r$topic_hierarchy_paths[[1]])
  stars <- suppressWarnings(as.integer(split_semis(r$topic_stars[[1]])))
  if (length(stars) && any(is.na(stars) | !stars %in% 1:3)) stopf("Invalid star ratings after CSV read for %s", r$record_id[[1]])

  topic_paths <- lapply(paths, function(p) trimws(strsplit(p, "\\s*>\\s*", perl=TRUE)[[1]]))
  star_map <- list()
  id_map <- list()
  if (length(paths)) {
    for (j in seq_along(paths)) {
      star_map[[paths[[j]]]] <- stars[[j]]
      id_map[[paths[[j]]]] <- ids[[j]]
      topic_tree <- tree_add(topic_tree, topic_paths[[j]], r$record_id[[1]])
    }
  }

  for (s in sp) species_counts <- inc(species_counts, s)
  for (z in isos) {
    country_counts <- inc(country_counts, z)
    for (s in sp) {
      if (is.null(country_species[[s]])) country_species[[s]] <- list()
      country_species[[s]] <- inc(country_species[[s]], z)
    }
  }

  dash_records[[i]] <- list(
    record_id = r$record_id[[1]],
    lens_id = r$lens_id[[1]],
    title = r$title[[1]],
    abstract = r$abstract[[1]],
    doi = r$doi[[1]],
    year = r$year[[1]],
    authors = r$authors[[1]],
    journal = r$journal[[1]],
    volume = r$volume[[1]],
    pages = r$pages[[1]],
    lens_url = r$lens_url[[1]],
    species = sp,
    countries = if (length(isos)) isos else countries,
    iso3 = isos,
    topics = unique(unlist(topic_paths, use.names=FALSE)),
    topic_paths = topic_paths,
    topic_stars = star_map,
    topic_path_ids = id_map,
    topic_coded_at = r$topic_coded_at[[1]]
  )
}

# Remove internal ID vectors from tree before serialisation.
strip_tree <- function(tree) {
  out <- list()
  for (nm in names(tree)) {
    n <- tree[[nm]]
    out[[nm]] <- list(count=as.integer(n$count), children=strip_tree(n$children))
  }
  out
}

map_id_to_iso3 <- list()
if (length(iso_numeric)) {
  for (k in names(iso_numeric)) {
    n <- suppressWarnings(as.integer(iso_numeric[[k]]))
    if (!is.na(n)) map_id_to_iso3[[sprintf("%03d", n)]] <- toupper(k)
  }
}

root_meta <- if (is.list(raw) && !is.null(raw$metadata)) raw$metadata else list()
last_search <- scalar(first_field(root_meta, c("last_search","last_search_at","search_date"), ""))
if (!nzchar(last_search) && is.list(raw)) {
  last_search <- scalar(first_field(raw, c("last_search","last_search_at","search_date"), ""))
}

all_topic_dates <- unique(csv$topic_coded_at[nzchar(csv$topic_coded_at)])
last_evidence_update <- if (length(all_topic_dates)) max(all_topic_dates) else ""

payload <- list(
  generated_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
  source = list(
    canonical_jsonl = source_jsonl,
    static_csv = out_csv,
    ontology = ontology_path,
    ontology_version = "3.6"
  ),
  metrics = list(
    total_records = nrow(csv),
    total_topics = nrow(ontology),
    total_countries = length(country_counts),
    total_species = length(species_counts),
    last_search = last_search,
    last_evidence_update = last_evidence_update
  ),
  species_display_order = c(
    "Atlantic salmon","Chinook salmon","Chum salmon","Coho salmon",
    "Masu salmon","Pink salmon","Sockeye salmon","Rainbow trout","Unspecified species"
  ),
  species_counts = species_counts,
  country_iso3_counts = country_counts,
  country_iso3_species_counts = country_species,
  country_name_by_iso3 = country_name_by_iso3,
  map_id_to_iso3 = map_id_to_iso3,
  topic_tree = strip_tree(topic_tree),
  topic_definitions = topic_definitions,
  topic_path_id_by_path = topic_path_id_by_path,
  topic_level_labels = list("1"="High-level topic","2"="Topic","3"="Specific topic"),
  records = dash_records
)

dir.create(dirname(out_js), recursive = TRUE, showWarnings = FALSE)
payload_json <- toJSON(payload, auto_unbox=TRUE, null="null", na="null", pretty=FALSE)
writeLines(
  paste0("window.LIVING_EVIDENCE_MAP_DASHBOARD_DATA=", payload_json, ";"),
  out_js,
  useBytes = TRUE
)

manifest <- list(
  generated_at = payload$generated_at,
  source_jsonl = source_jsonl,
  output_csv = out_csv,
  output_js = out_js,
  records = nrow(csv),
  topic_assignments = sum(vapply(dash_records, function(r) length(r$topic_paths), integer(1))),
  records_without_topics = sum(vapply(dash_records, function(r) length(r$topic_paths)==0, logical(1))),
  star_counts = as.list(table(factor(unlist(lapply(dash_records, function(r) unlist(r$topic_stars, use.names=FALSE))), levels=1:3)))
)
manifest_path <- file.path(dirname(out_js), "dashboard-data-manifest.json")
write_json(manifest, manifest_path, auto_unbox=TRUE, pretty=TRUE)

cat(sprintf("Dashboard build complete: %d records; CSV=%s; dashboard JS=%s\n", nrow(csv), out_csv, out_js))
