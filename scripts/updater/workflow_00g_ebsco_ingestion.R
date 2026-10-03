#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
  library(xml2)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

cluster <- arg("--cluster")
query <- arg("--query")
config_path <- arg("--config","config/workflow00_ebsco_clusters.json")
max_records <- as.integer(arg("--max-records","10"))
page_size <- as.integer(arg("--page-size","10"))
output_dir <- arg("--output-dir","outputs/updater/ebsco_cluster_test")
if (is.null(cluster)||!nzchar(cluster)||is.null(query)||!nzchar(query)) {
  stop("Required: --cluster --query",call.=FALSE)
}
if (is.na(max_records)||max_records<1L) stop("--max-records must be >=1",call.=FALSE)
if (is.na(page_size)||page_size<1L||page_size>100L) stop("--page-size must be 1..100",call.=FALSE)

uid <- Sys.getenv("EBSCO_EHOST_UID",unset="")
pwd <- Sys.getenv("EBSCO_EHOST_PWD",unset="")
if (!nzchar(uid)||!nzchar(pwd)) stop("EBSCO_EHOST_UID and EBSCO_EHOST_PWD are required",call.=FALSE)

cfg <- fromJSON(config_path,simplifyVector=FALSE)
cl <- cfg$clusters[[cluster]]
if (is.null(cl)) stop(sprintf("Unknown EBSCO cluster: %s",cluster),call.=FALSE)
dbs <- cl$databases
if (!length(dbs)) stop(sprintf("EBSCO cluster %s has no verified database members",cluster),call.=FALSE)

dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)
dir.create(file.path(output_dir,"raw"),recursive=TRUE,showWarnings=FALSE)

now_utc <- function() format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
text1 <- function(node,xpath) {
  x <- xml_find_first(node,xpath)
  if (inherits(x,"xml_missing")) return(NA_character_)
  z <- trimws(xml_text(x))
  if (!nzchar(z)) NA_character_ else z
}
texts <- function(node,xpath) {
  x <- xml_find_all(node,xpath)
  z <- trimws(xml_text(x))
  z[nzchar(z)]
}
attr1 <- function(node,xpath,attr) {
  x <- xml_find_first(node,xpath)
  if (inherits(x,"xml_missing")) return(NA_character_)
  z <- xml_attr(x,attr)
  if (is.na(z)||!nzchar(z)) NA_character_ else z
}
doi_from_rec <- function(rec) {
  uis <- xml_find_all(rec,".//*[local-name()='ui']")
  if (!length(uis)) return(NA_character_)
  typ <- tolower(ifelse(is.na(xml_attr(uis,"type")),"",xml_attr(uis,"type")))
  vals <- trimws(xml_text(uis))
  hit <- which(typ=="doi" & nzchar(vals))
  if (!length(hit)) NA_character_ else vals[[hit[[1L]]]]
}

records_out <- file.path(output_dir,"records.jsonl")
if (file.exists(records_out)) unlink(records_out)
manifest_dbs <- list()
total_written <- 0L

for (db in dbs) {
  code <- as.character(db$code)
  expected_title <- as.character(db$title)
  start <- 1L
  db_written <- 0L
  reported <- NA_integer_
  observed_title <- NA_character_
  batch <- 0L

  while (db_written < max_records) {
    nreq <- min(page_size,max_records-db_written)
    req <- request("https://eit.ebscohost.com/Services/SearchService.asmx/Search") |>
      req_url_query(
        prof=uid,
        pwd=pwd,
        authType="profile",
        db=code,
        query=query,
        format="detailed",
        startrec=start,
        numrec=nreq
      ) |>
      req_error(is_error=function(resp) FALSE)
    resp <- req_perform(req)
    status <- resp_status(resp)
    body <- resp_body_string(resp)
    if (status>=400L) stop(sprintf("EBSCO %s HTTP %d",code,status),call.=FALSE)
    batch <- batch+1L
    raw_path <- file.path(output_dir,"raw",sprintf("%s_%04d.xml",code,batch))
    writeLines(body,raw_path,useBytes=TRUE)
    doc <- read_xml(body)

    fault <- xml_find_first(doc,"//*[local-name()='Fault']")
    if (!inherits(fault,"xml_missing")) {
      msg <- text1(fault,".//*[local-name()='Message'][1]")
      stop(sprintf("EBSCO %s provider fault: %s",code,msg),call.=FALSE)
    }

    if (is.na(reported)) {
      h <- text1(doc,"//*[local-name()='Hits'][1]")
      reported <- suppressWarnings(as.integer(h))
    }
    recs <- xml_find_all(doc,"//*[local-name()='rec']")
    if (!length(recs)) break

    con <- file(records_out,open="at",encoding="UTF-8")
    for (rec in recs) {
      header <- xml_find_first(rec,".//*[local-name()='header']")
      db_code <- xml_attr(header,"shortDbName")
      db_title <- xml_attr(header,"longDbName")
      accession <- xml_attr(header,"uiTerm")
      if (is.na(db_code)||!nzchar(db_code)) db_code <- code
      if (is.na(db_title)||!nzchar(db_title)) db_title <- expected_title
      if (is.na(accession)||!nzchar(accession)) accession <- text1(rec,".//*[local-name()='ui'][not(@type)][1]")
      if (is.na(accession)||!nzchar(accession)) stop(sprintf("EBSCO %s record lacks accession identity",code),call.=FALSE)
      observed_title <- db_title

      dt <- xml_find_first(rec,".//*[local-name()='dt'][1]")
      year <- suppressWarnings(as.integer(xml_attr(dt,"year")))
      if (is.na(year)) {
        dtt <- text1(rec,".//*[local-name()='dt'][1]")
        if (!is.na(dtt)&&nchar(dtt)>=4L) year <- suppressWarnings(as.integer(substr(dtt,1L,4L)))
      }
      obj <- list(
        schema="living-evidence-map-workflow00-ebsco-record-v1",
        source=paste0("ebsco_",tolower(db_code)),
        source_record_id=accession,
        title=text1(rec,".//*[local-name()='atl'][1]"),
        abstract=text1(rec,".//*[local-name()='ab'][1]"),
        authors=as.list(texts(rec,".//*[local-name()='au']")),
        year=if(is.na(year)) NULL else year,
        doi=doi_from_rec(rec),
        journal=text1(rec,".//*[local-name()='jtl'][1]"),
        ebsco=list(
          cluster=cluster,
          database_code=db_code,
          database_name=db_title,
          accession_number=accession,
          permalink=text1(rec,".//*[local-name()='plink'][1]"),
          subjects=as.list(texts(rec,".//*[local-name()='su']")),
          publication_types=as.list(texts(rec,".//*[local-name()='pubtype']")),
          document_type=text1(rec,".//*[local-name()='doctype'][1]"),
          raw_record_xml=as.character(rec)
        )
      )
      writeLines(toJSON(obj,auto_unbox=TRUE,null="null",na="null"),con,useBytes=TRUE)
      db_written <- db_written+1L
      total_written <- total_written+1L
      if (db_written>=max_records) break
    }
    close(con)
    start <- start + length(recs)
    if (length(recs)<nreq || (!is.na(reported) && start>reported)) break
  }

  manifest_dbs[[code]] <- list(
    database_code=code,
    configured_title=expected_title,
    observed_title=if(is.na(observed_title)) NULL else observed_title,
    reported_hits=if(is.na(reported)) NULL else reported,
    records_written=db_written
  )
}

manifest <- list(
  schema="living-evidence-map-workflow00-ebsco-cluster-harvest-v1",
  status="success",
  created_at=now_utc(),
  cluster=cluster,
  cluster_label=cl$label,
  query=query,
  database_count=length(dbs),
  records_retrieved=total_written,
  databases=manifest_dbs,
  provenance_rule="Cluster selection expands to database-specific EBSCO searches; database code/name/accession remain on every manifestation."
)
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),
           file.path(output_dir,"manifest.json"),useBytes=TRUE)
cat(sprintf("PASS: EBSCO cluster %s harvested %d records across %d verified database(s)\n",
            cluster,total_written,length(dbs)))
