#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(httr2)
  library(xml2)
  library(jsonlite)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

source_slug <- arg("--source")
query <- arg("--query")
config_path <- arg("--config","config/workflow00_ebsco_sources.json")
output_dir <- arg("--output-dir","outputs/updater/source_child")
page_size <- as.integer(arg("--page-size","100"))
max_records_arg <- arg("--max-records","all")
max_records <- if (identical(max_records_arg,"all")) Inf else suppressWarnings(as.integer(max_records_arg))

if (is.null(source_slug) || is.null(query)) stop("--source and --query are required",call.=FALSE)
if (!file.exists(config_path)) stop(sprintf("EBSCO source config not found: %s",config_path),call.=FALSE)
if (is.na(page_size) || page_size < 1L || page_size > 200L) stop("--page-size must be 1..200",call.=FALSE)
if (!is.infinite(max_records) && (is.na(max_records) || max_records < 1L)) stop("--max-records must be all or a positive integer",call.=FALSE)

uid <- Sys.getenv("EBSCO_EHOST_UID")
pwd <- Sys.getenv("EBSCO_EHOST_PWD")
if (!nzchar(uid) || !nzchar(pwd)) stop("EBSCO_EHOST_UID and EBSCO_EHOST_PWD are required",call.=FALSE)

cfg <- fromJSON(config_path,simplifyVector=FALSE)
src <- cfg$sources[[source_slug]]
if (is.null(src)) stop(sprintf("Unknown EBSCO Workflow 00 source: %s",source_slug),call.=FALSE)
db_code <- as.character(src$db_code)
db_name <- as.character(src$display_name)
search_fields <- unlist(src$search_fields,use.names=FALSE)

dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)
raw_dir <- file.path(output_dir,"raw")
dir.create(raw_dir,recursive=TRUE,showWarnings=FALSE)

now_utc <- function() format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
scalar_text <- function(node) {
  if (length(node)==0L) return(NULL)
  x <- trimws(xml_text(node[[1L]]))
  if (!nzchar(x)) NULL else x
}
texts <- function(node, xpath) {
  x <- trimws(xml_text(xml_find_all(node,xpath)))
  x[nzchar(x)]
}
first_text <- function(node, xpaths) {
  for (xp in xpaths) {
    z <- scalar_text(xml_find_all(node,xp))
    if (!is.null(z)) return(z)
  }
  NULL
}
norm_doi <- function(x) {
  if (is.null(x)) return(NULL)
  x <- tolower(trimws(x))
  x <- sub("^https?://(dx\\.)?doi\\.org/","",x,perl=TRUE)
  x <- sub("^doi:\\s*","",x,perl=TRUE)
  x <- sub("[.,;:]+$","",x,perl=TRUE)
  if (!nzchar(x)) NULL else x
}
perform_xml <- function(url, params, label, timeout=180) {
  req <- request(url) |> req_url_query(!!!params) |> req_timeout(timeout) |>
    req_error(is_error=function(resp) FALSE)
  resp <- req_perform(req)
  st <- resp_status(resp)
  if (st != 200L) stop(sprintf("EBSCO %s returned HTTP %d",label,st),call.=FALSE)
  raw <- resp_body_raw(resp)
  doc <- tryCatch(read_xml(raw),error=function(e) NULL)
  if (is.null(doc)) stop(sprintf("EBSCO %s returned non-XML content",label),call.=FALSE)
  err <- xml_find_first(doc,"//*[local-name()='Error' or local-name()='error']")
  if (!inherits(err,"xml_missing")) {
    msg <- trimws(xml_text(err))
    stop(sprintf("EBSCO %s returned an API error%s",label,if(nzchar(msg)) paste0(": ",msg) else ""),call.=FALSE)
  }
  list(raw=raw,doc=doc)
}

# Validate live entitlement and field metadata before harvesting.
info <- perform_xml(
  "https://eit.ebscohost.com/Services/SearchService.asmx/Info",
  list(prof=uid,pwd=pwd,authType="profile"),
  "Info"
)
db_nodes <- xml_find_all(info$doc,"//*[local-name()='db']")
match_ix <- which(xml_attr(db_nodes,"shortName")==db_code)
if (length(match_ix)!=1L) stop(sprintf("EBSCO profile does not expose configured database %s (%s)",db_code,db_name),call.=FALSE)
db_node <- db_nodes[[match_ix]]
live_name <- xml_attr(db_node,"longName")
live_fields <- unique(xml_attr(xml_find_all(db_node,".//*[local-name()='dbTag']"),"name"))
missing_fields <- setdiff(search_fields,live_fields)
if (length(missing_fields)) {
  stop(sprintf("Configured search fields absent from live EBSCO Info for %s: %s",
               source_slug,paste(missing_fields,collapse=", ")),call.=FALSE)
}

records <- list()
reported_total <- NA_integer_
startrec <- 1L
page <- 0L
page_files <- character()

repeat {
  page <- page + 1L
  ans <- perform_xml(
    "https://eit.ebscohost.com/Services/SearchService.asmx/Search",
    list(
      prof=uid,
      pwd=pwd,
      authType="profile",
      db=db_code,
      query=query,
      format="detailed",
      startrec=as.character(startrec),
      numrec=as.character(page_size)
    ),
    sprintf("Search page %d",page),
    timeout=300
  )

  raw_path <- file.path(raw_dir,sprintf("response_%06d.xml",page))
  writeBin(ans$raw,raw_path)
  page_files <- c(page_files,raw_path)

  hit_nodes <- xml_find_all(ans$doc,"//*[local-name()='Hits']")
  hit_vals <- suppressWarnings(as.integer(trimws(xml_text(hit_nodes))))
  hit_vals <- hit_vals[!is.na(hit_vals)]
  if (is.na(reported_total) && length(hit_vals)) reported_total <- hit_vals[[1L]]

  rec_nodes <- xml_find_all(ans$doc,"//*[local-name()='rec']")
  if (!length(rec_nodes)) break

  for (rec in rec_nodes) {
    if (length(records) >= max_records) break
    header <- xml_find_first(rec,".//*[local-name()='header']")
    accession <- if (!inherits(header,"xml_missing")) xml_attr(header,"uiTerm") else NA_character_
    if (is.na(accession) || !nzchar(trimws(accession))) {
      ui_plain <- xml_find_all(rec,".//*[local-name()='ui' and not(@type)]")
      accession <- scalar_text(ui_plain)
    }
    accession <- if (is.null(accession)) "" else trimws(accession)
    if (!nzchar(accession)) stop(sprintf("Missing EBSCO accession number on page %d",page),call.=FALSE)

    short_db <- if (!inherits(header,"xml_missing")) xml_attr(header,"shortDbName") else db_code
    long_db <- if (!inherits(header,"xml_missing")) xml_attr(header,"longDbName") else db_name
    if (!is.na(short_db) && nzchar(short_db) && short_db != db_code) {
      stop(sprintf("EBSCO response provenance mismatch: requested %s received %s",db_code,short_db),call.=FALSE)
    }

    title <- first_text(rec,c(".//*[local-name()='atl']",".//*[local-name()='btl']"))
    abstract <- first_text(rec,c(".//*[local-name()='ab']"))
    au <- texts(rec,".//*[local-name()='au']")
    doi_nodes <- xml_find_all(rec,".//*[local-name()='ui' and translate(@type,'DOI','doi')='doi']")
    doi <- norm_doi(scalar_text(doi_nodes))
    dt <- xml_find_first(rec,".//*[local-name()='dt']")
    year <- if (!inherits(dt,"xml_missing")) suppressWarnings(as.integer(xml_attr(dt,"year"))) else NA_integer_
    if (is.na(year)) year <- NULL
    pub_date <- if (!inherits(dt,"xml_missing")) trimws(xml_text(dt)) else ""
    if (!nzchar(pub_date)) pub_date <- NULL
    journal <- first_text(rec,c(".//*[local-name()='jtl']"))
    kw <- unique(texts(rec,".//*[local-name()='kw']"))
    subjects <- unique(c(texts(rec,".//*[local-name()='su']"),texts(rec,".//*[local-name()='subj']")))
    pubtypes <- unique(c(texts(rec,".//*[local-name()='doctype']"),texts(rec,".//*[local-name()='pubtype']")))
    plink <- first_text(rec,c(".//*[local-name()='plink']"))

    sidecar_id <- paste(source_slug,accession,sep=":")
    authors <- if (length(au)) lapply(au,function(a) list(display_name=a)) else NULL

    records[[length(records)+1L]] <- list(
      sidecar_identity=list(
        sidecar_record_id=sidecar_id,
        ebsco_accession_number=accession,
        doi=doi
      ),
      source=list(
        provider=source_slug,
        source_format="ebscohost_eit_search_api_xml",
        ebsco_database_code=db_code,
        ebsco_database_name=if(!is.na(long_db)&&nzchar(long_db)) long_db else db_name
      ),
      ebsco=list(
        accession_number=accession,
        database_code=db_code,
        database_name=if(!is.na(long_db)&&nzchar(long_db)) long_db else db_name,
        permalink=plink,
        subject_terms=if(length(subjects)) subjects else NULL,
        publication_types=if(length(pubtypes)) pubtypes else NULL
      ),
      mapped_fields=list(
        title=title,
        abstract=abstract,
        authors=authors,
        first_author=if(length(au)) au[[1L]] else NULL,
        year=year,
        publication_date=pub_date,
        source=journal,
        doi=doi,
        keywords=if(length(kw)) kw else NULL,
        author_keywords=if(length(kw)) kw else NULL,
        publication_type=if(length(pubtypes)) pubtypes[[1L]] else NULL,
        affiliations=NULL
      ),
      provenance=list(
        adapter_workflow="workflow_00g_ebsco_ingestion",
        implementation_language="R",
        harvested_at=now_utc(),
        source_stage="ebscohost_eit_search",
        database_code=db_code,
        database_name=db_name,
        canonical_json_modified=FALSE
      )
    )
  }

  if (length(records) >= max_records) break
  if (!is.na(reported_total) && length(records) >= reported_total) break
  if (length(rec_nodes) < page_size) break
  startrec <- startrec + length(rec_nodes)
}

ids <- vapply(records,function(r) r$sidecar_identity$sidecar_record_id,character(1))
if (anyDuplicated(ids)) stop("Duplicate EBSCO accession numbers returned within harvest",call.=FALSE)
if (is.na(reported_total)) reported_total <- length(records)
if (is.infinite(max_records) && length(records) != reported_total) {
  stop(sprintf("EBSCO harvest count mismatch for %s: reported=%d retrieved=%d",
               source_slug,reported_total,length(records)),call.=FALSE)
}

records_path <- file.path(output_dir,"records.jsonl")
con <- file(records_path,"wt",encoding="UTF-8")
if (length(records)) for (r in records) {
  writeLines(toJSON(r,auto_unbox=TRUE,null="null",na="null",digits=NA),con)
}
close(con)

coverage <- if (length(records)) do.call(rbind,lapply(records,function(r) data.frame(
  sidecar_record_id=r$sidecar_identity$sidecar_record_id,
  accession_number=r$sidecar_identity$ebsco_accession_number,
  doi=if(is.null(r$mapped_fields$doi)) NA_character_ else r$mapped_fields$doi,
  title=if(is.null(r$mapped_fields$title)) NA_character_ else r$mapped_fields$title,
  abstract_present=!is.null(r$mapped_fields$abstract),
  authors_present=!is.null(r$mapped_fields$authors),
  year=if(is.null(r$mapped_fields$year)) NA_integer_ else as.integer(r$mapped_fields$year),
  keywords_present=!is.null(r$mapped_fields$keywords),
  stringsAsFactors=FALSE
))) else data.frame(
  sidecar_record_id=character(),accession_number=character(),doi=character(),title=character(),
  abstract_present=logical(),authors_present=logical(),year=integer(),keywords_present=logical()
)
write.csv(coverage,file.path(output_dir,"field_coverage_records.csv"),row.names=FALSE,na="")

manifest <- list(
  workflow="workflow_00g_ebsco_ingestion",
  status="success",
  source=source_slug,
  database_code=db_code,
  database_name=db_name,
  query=query,
  search_fields=search_fields,
  live_database_name=live_name,
  reported_total=reported_total,
  records_retrieved=length(records),
  max_records=if(is.infinite(max_records)) "all" else as.integer(max_records),
  page_size=page_size,
  pages_retrieved=page,
  native_id="EBSCO accession number",
  raw_response_format="XML",
  raw_files=basename(page_files),
  handoff_jsonl="records.jsonl",
  source_provenance_preserved=TRUE,
  generated_at_utc=now_utc()
)
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null"),
           file.path(output_dir,"manifest.json"))

checksum_files <- c(page_files,records_path,file.path(output_dir,"field_coverage_records.csv"),
                    file.path(output_dir,"manifest.json"))
checksum_lines <- vapply(checksum_files,function(p)
  sprintf("%s  %s",digest(file=p,algo="sha256",serialize=FALSE),
          substring(p,nchar(output_dir)+2L)),character(1))
writeLines(checksum_lines,file.path(output_dir,"SHA256SUMS"))

message(sprintf("PASS: EBSCO source=%s db=%s reported=%d retrieved=%d pages=%d",
                source_slug,db_code,reported_total,length(records),page))
