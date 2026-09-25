#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(data.table)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
cluster_map_path <- arg("--cluster-map")
strip_path <- arg("--strip-actions")
repairs_path <- arg("--data-quality-repairs",NULL)
repair_audit_path <- arg("--repair-audit",NULL)
lens_path <- arg("--lens")
scopus_path <- arg("--scopus")
openalex_path <- arg("--openalex")
agricola_path <- arg("--agricola")
wos_path <- arg("--wos")
run_id <- arg("--run-id")
output_path <- arg("--output")
manifest_path <- arg("--manifest")
required <- list(cluster_map_path,lens_path,scopus_path,openalex_path,agricola_path,wos_path,run_id,output_path,manifest_path)
if(any(vapply(required,is.null,logical(1)))) stop("Required: --cluster-map --lens --scopus --openalex --agricola --wos --run-id --output --manifest",call.=FALSE)

`%||%` <- function(x,y) if(is.null(x)) y else x
scalar <- function(x){
  if(is.null(x)||!length(x)) return(NULL)
  y <- trimws(as.character(x[[1L]]))
  if(!nzchar(y)) NULL else y
}
clean_text <- function(x){
  x <- scalar(x)
  if(is.null(x)) return(NULL)
  x <- gsub("[[:space:]]+"," ",x)
  x <- trimws(x)
  if(!nzchar(x)) NULL else x
}
norm_doi <- function(x){
  x <- clean_text(x)
  if(is.null(x)) return(NULL)
  x <- tolower(x)
  x <- sub("^https?://(dx\\.)?doi\\.org/","",x,perl=TRUE)
  x <- sub("^doi:\\s*","",x,perl=TRUE)
  x <- sub("[?#].*$","",x,perl=TRUE)
  x <- sub("[.,;:]+$","",x,perl=TRUE)
  if(!nzchar(x)) NULL else x
}
source_kind <- function(r){
  if(is.list(r$lens)) return("lens")
  p <- scalar((r$source %||% list())$provider)
  if(identical(p,"scopus")) return("scopus")
  if(identical(p,"openalex")) return("openalex")
  if(identical(p,"agricola_via_europe_pmc")) return("agricola")
  if(identical(p,"wos_starter")) return("wos")
  stop(sprintf("Unknown source provider: %s",p %||% "<missing>"),call.=FALSE)
}
source_record_id <- function(r){
  src <- source_kind(r)
  if(src=="lens") return(as.character((r$identity %||% list())$lens_id %||% (r$identity %||% list())$record_id %||% ""))
  as.character((r$sidecar_identity %||% list())$sidecar_record_id %||% "")
}
field <- function(r,name){
  src <- source_kind(r)
  if(src=="lens"){
    can <- r$canonical %||% list()
    raw <- (r$lens %||% list())$raw_payload %||% list()
    if(name=="title") return(clean_text(can$title %||% raw$title))
    if(name=="abstract") return(clean_text(can$abstract %||% raw$abstract))
    if(name=="doi"){
      d <- norm_doi(can$doi)
      if(!is.null(d)) return(d)
      ids <- raw$external_ids %||% list()
      for(z in ids) if(is.list(z) && identical(tolower(as.character(z$type %||% "")),"doi")){
        d <- norm_doi(z$value); if(!is.null(d)) return(d)
      }
      return(NULL)
    }
    if(name=="authors") return(can$authors %||% raw$authors)
    if(name=="year") return(can$year %||% raw$year_published %||% raw$date_published)
    if(name=="journal"){
      s <- can$source %||% raw$source
      if(is.list(s)) return(clean_text(s$title))
      return(clean_text(s))
    }
    if(name=="volume") return(clean_text(can$volume %||% raw$volume))
    if(name=="issue") return(clean_text(can$issue %||% raw$issue))
    if(name=="pages") return(clean_text(can$pages %||% raw$pages))
  } else {
    m <- r$mapped_fields %||% list()
    if(name=="title") return(clean_text(m$title))
    if(name=="abstract") return(clean_text(m$abstract))
    if(name=="doi") return(norm_doi(m$doi %||% (r$sidecar_identity %||% list())$doi))
    if(name=="authors") return(m$authors %||% m$first_author)
    if(name=="year") return(m$year %||% m$publication_date)
    if(name=="journal") return(clean_text(m$source %||% m$journal))
    if(name=="volume") return(clean_text(m$volume))
    if(name=="issue") return(clean_text(m$issue))
    if(name=="pages") return(clean_text(m$pages %||% m$article_number))
  }
  NULL
}
author_strings <- function(x){
  if(is.null(x)||!length(x)) return(character())
  one <- function(z){
    if(is.character(z)) return(clean_text(z) %||% "")
    if(is.list(z)){
      display <- clean_text(z$display_name %||% z$name %||% z$full_name)
      if(!is.null(display)) return(display)
      surname <- clean_text(z$surname %||% z$last_name %||% z$family) %||% ""
      given <- clean_text(z$given_name %||% z$first_name %||% z$given) %||% ""
      return(trimws(paste(given,surname)))
    }
    ""
  }
  if(is.character(x)) vals <- as.character(x) else vals <- vapply(x,one,character(1))
  vals <- trimws(vals)
  vals[nzchar(vals)]
}
year_value <- function(x){
  s <- as.character(x %||% "")
  m <- regexpr("(18|19|20|21)[0-9]{2}",s,perl=TRUE)
  if(m[[1L]]<0L) return(NULL)
  as.integer(regmatches(s,m)[[1L]])
}
modal_pick <- function(values, keys, normalise=function(x)x){
  ok <- !vapply(values,is.null,logical(1))
  if(!any(ok)) return(list(value=NULL,source_key=NULL))
  vals <- values[ok]; ks <- keys[ok]
  disp <- vapply(vals,function(v){
    if(is.list(v)||length(v)>1L) paste(as.character(unlist(v,use.names=FALSE)),collapse="; ") else as.character(v)
  },character(1))
  norm <- vapply(disp,function(v){
    z <- normalise(v)
    if(is.null(z)) "" else as.character(z)
  },character(1))
  keep <- nzchar(norm)
  if(!any(keep)) return(list(value=NULL,source_key=NULL))
  vals <- vals[keep]; ks <- ks[keep]; disp <- disp[keep]; norm <- norm[keep]
  freq <- table(norm)
  bestn <- max(freq)
  candidates <- names(freq)[freq==bestn]
  ix <- which(norm %in% candidates)
  lens <- nchar(disp[ix],type="chars")
  best <- ix[order(-lens,ks[ix])][1L]
  list(value=vals[[best]],source_key=ks[[best]])
}

cluster_map <- fread(cluster_map_path,na.strings=c("","NA"))
need <- c("source","source_record_id","cluster_id","cluster_size")
if(length(setdiff(need,names(cluster_map)))) stop("Cluster map missing required columns",call.=FALSE)
cluster_map[,key:=paste(source,source_record_id,sep="::")]
if(anyDuplicated(cluster_map$key)) stop("Cluster map has duplicate source manifestation keys",call.=FALSE)

strip_keys <- character()
strip_audit <- list()
if(!is.null(strip_path) && file.exists(strip_path)){
  lines <- readLines(strip_path,warn=FALSE,encoding="UTF-8")
  lines <- lines[nzchar(trimws(lines))]
  if(length(lines)){
    ss <- lapply(lines,fromJSON,simplifyVector=FALSE)
    strip_keys <- unique(vapply(ss,function(z)paste(z$source,z$source_record_id,sep="::"),character(1)))
    strip_audit <- setNames(ss,strip_keys)
  }
}


read_jsonl <- function(path){
  if(is.null(path) || !file.exists(path)) return(list())
  lines <- readLines(path,warn=FALSE,encoding="UTF-8")
  lines <- lines[nzchar(trimws(lines))]
  lapply(lines,fromJSON,simplifyVector=FALSE)
}
repairs <- read_jsonl(repairs_path)
allowed_repair_actions <- c("strip_abstract","replace_abstract","set_doi","set_title","set_canonical_preference")
repair_by_key <- list()
repair_application <- vector("list",length(repairs))
if(length(repairs)){
  for(i in seq_along(repairs)){
    r <- repairs[[i]]
    action <- as.character(r$action %||% "")
    if(!(action %in% allowed_repair_actions)) stop(sprintf("Unsupported data-quality repair action: %s",action),call.=FALSE)
    src <- as.character(r$source %||% "")
    rid <- as.character(r$source_record_id %||% "")
    if(!nzchar(src)||!nzchar(rid)) stop(sprintf("Repair %d lacks immutable source identity",i),call.=FALSE)
    key <- paste(src,rid,sep="::")
    repair_by_key[[key]] <- c(repair_by_key[[key]],list(r))
    repair_application[[i]] <- list(
      review_case_id=as.character(r$review_case_id %||% ""),
      source=src,
      source_record_id=rid,
      action=action,
      value=if(is.null(r$value)) NULL else r$value,
      status="pending"
    )
  }
}
if(is.null(repair_audit_path)) repair_audit_path <- file.path(dirname(manifest_path),"data_quality_repair_application.jsonl")

records <- new.env(hash=TRUE,parent=emptyenv())
read_source <- function(path,expected){
  con <- file(path,"rt",encoding="UTF-8"); on.exit(close(con),add=TRUE)
  n <- 0L
  repeat{
    lines <- readLines(con,n=500L,warn=FALSE)
    if(!length(lines)) break
    for(line in lines){
      if(!nzchar(trimws(line))) next
      r <- fromJSON(line,simplifyVector=FALSE)
      src <- source_kind(r)
      if(!identical(src,expected)) stop(sprintf("Expected %s, found %s",expected,src),call.=FALSE)
      rid <- source_record_id(r)
      if(!nzchar(rid)) stop(sprintf("%s record missing source ID",expected),call.=FALSE)
      key <- paste(src,rid,sep="::")
      if(exists(key,records,inherits=FALSE)) stop(sprintf("Duplicate source record key: %s",key),call.=FALSE)
      assign(key,r,records); n <- n+1L
    }
  }
  n
}
source_paths <- c(lens=lens_path,scopus=scopus_path,openalex=openalex_path,agricola=agricola_path,wos=wos_path)
source_counts <- vapply(names(source_paths),function(src)read_source(source_paths[[src]],src),integer(1))
all_keys <- ls(records,all.names=TRUE)
missing <- setdiff(cluster_map$key,all_keys)
extra <- setdiff(all_keys,cluster_map$key)
if(length(missing)) stop(sprintf("%d cluster-map manifestations are absent from source records",length(missing)),call.=FALSE)
if(length(extra)) stop(sprintf("%d source records are absent from cluster map",length(extra)),call.=FALSE)

dir.create(dirname(output_path),recursive=TRUE,showWarnings=FALSE)
out <- file(output_path,"wt",encoding="UTF-8")
on.exit(close(out),add=TRUE)
clusters <- split(cluster_map,cluster_map$cluster_id)
manifestations_total <- 0L
duplicate_clusters <- 0L
stripped_manifestations <- 0L
missing_abstract_manifestations <- 0L

for(cid in sort(names(clusters))){
  cm <- clusters[[cid]]
  setorder(cm,source,source_record_id)
  mans <- vector("list",nrow(cm))
  keys <- cm$key
  for(i in seq_len(nrow(cm))){
    r <- get(keys[[i]],records,inherits=FALSE)
    title <- field(r,"title")
    a <- field(r,"abstract")
    doi <- field(r,"doi")
    preferred <- FALSE
    applied_repairs <- list()

    # Automatic strip actions and explicit human repairs are both immutable,
    # source-manifestation-specific transformations.
    stripped <- keys[[i]] %in% strip_keys
    if(stripped) a <- NULL

    rs <- repair_by_key[[keys[[i]]]]
    if(length(rs)){
      for(rr in rs){
        action <- as.character(rr$action)
        before <- switch(action,
          strip_abstract=a,
          replace_abstract=a,
          set_doi=doi,
          set_title=title,
          set_canonical_preference=preferred
        )
        if(action=="strip_abstract"){
          a <- NULL
          stripped <- TRUE
        } else if(action=="replace_abstract"){
          a <- clean_text(rr$value)
        } else if(action=="set_doi"){
          doi <- norm_doi(rr$value)
        } else if(action=="set_title"){
          title <- clean_text(rr$value)
        } else if(action=="set_canonical_preference"){
          preferred <- TRUE
        }
        after <- switch(action,
          strip_abstract=a,
          replace_abstract=a,
          set_doi=doi,
          set_title=title,
          set_canonical_preference=preferred
        )
        applied_repairs[[length(applied_repairs)+1L]] <- list(
          review_case_id=as.character(rr$review_case_id %||% ""),
          action=action,
          supplied_value=if(is.null(rr$value)) NULL else rr$value,
          before=before,
          after=after,
          reason=rr$reason %||% NULL
        )
        # Mark the exact ledger item as applied.
        hit <- which(vapply(repair_application,function(z)
          identical(z$review_case_id,as.character(rr$review_case_id %||% "")) &&
          identical(z$source,as.character(cm$source[[i]])) &&
          identical(z$source_record_id,as.character(cm$source_record_id[[i]])) &&
          identical(z$action,action),logical(1)))
        if(length(hit)!=1L) stop(sprintf("Could not uniquely map repair application for %s %s",keys[[i]],action),call.=FALSE)
        repair_application[[hit]]$status <- "applied"
        repair_application[[hit]]$cluster_id <- cid
      }
    }

    if(stripped) stripped_manifestations <- stripped_manifestations+1L
    if(is.null(a)) missing_abstract_manifestations <- missing_abstract_manifestations+1L
    mans[[i]] <- list(
      source=as.character(cm$source[[i]]),
      source_record_id=as.character(cm$source_record_id[[i]]),
      title=title,
      abstract=a,
      doi=doi,
      authors=author_strings(field(r,"authors")),
      year=year_value(field(r,"year")),
      journal=field(r,"journal"),
      volume=field(r,"volume"),
      issue=field(r,"issue"),
      pages=field(r,"pages"),
      canonical_preference=preferred,
      data_quality_repairs=if(length(applied_repairs)) applied_repairs else NULL,
      abstract_stripped=stripped,
      abstract_strip_provenance=if(keys[[i]] %in% strip_keys) strip_audit[[keys[[i]]]] else NULL
    )
  }
  manifestations_total <- manifestations_total+length(mans)
  if(length(mans)>1L) duplicate_clusters <- duplicate_clusters+1L
  mk <- vapply(mans,function(m)paste(m$source,m$source_record_id,sep=":"),character(1))
  preferred_ix <- which(vapply(mans,function(m)isTRUE(m$canonical_preference),logical(1)))
  if(length(preferred_ix)>1L){
    stop(sprintf("Cluster %s has %d conflicting canonical-preference manifestations",cid,length(preferred_ix)),call.=FALSE)
  }
  pick_field <- function(name,normalise=function(x)x,transform=function(x)x){
    if(length(preferred_ix)==1L){
      v <- mans[[preferred_ix]][[name]]
      if(!is.null(v) && length(v) && !(is.character(v)&&!nzchar(trimws(paste(v,collapse=""))))){
        return(list(value=transform(v),source_key=mk[[preferred_ix]],selection="human_canonical_preference"))
      }
    }
    z <- modal_pick(lapply(mans,`[[`,name),mk,normalise)
    z$selection <- "deterministic_modal"
    z
  }
  title_pick <- pick_field("title",function(x)tolower(gsub("[^[:alnum:]]+","",x)))
  abstract_pick <- pick_field("abstract",function(x)tolower(gsub("[[:space:]]+"," ",x)))
  doi_pick <- pick_field("doi",norm_doi)
  authors_pick <- pick_field("authors",function(x)tolower(gsub("[^[:alnum:]; ]+","",x)))
  year_pick <- pick_field("year",as.character)
  journal_pick <- pick_field("journal",function(x)tolower(gsub("[^[:alnum:]]+","",x)))
  volume_pick <- pick_field("volume")
  issue_pick <- pick_field("issue")
  pages_pick <- pick_field("pages")
  rec <- list(
    schema_version="living-evidence-map-canonical-v1",
    identity=list(record_id=cid,record_id_type="deduplication_cluster_id"),
    canonical=list(
      title=title_pick$value,
      abstract=abstract_pick$value,
      doi=doi_pick$value,
      authors=if(is.null(authors_pick$value)) character() else authors_pick$value,
      year=year_pick$value,
      journal=journal_pick$value,
      volume=volume_pick$value,
      issue=issue_pick$value,
      pages=pages_pick$value,
      field_provenance=list(
        title=title_pick$source_key,abstract=abstract_pick$source_key,doi=doi_pick$source_key,
        authors=authors_pick$source_key,year=year_pick$source_key,journal=journal_pick$source_key,
        volume=volume_pick$source_key,issue=issue_pick$source_key,pages=pages_pick$source_key
      ),
      field_selection=list(
        title=title_pick$selection,abstract=abstract_pick$selection,doi=doi_pick$selection,
        authors=authors_pick$selection,year=year_pick$selection,journal=journal_pick$selection,
        volume=volume_pick$selection,issue=issue_pick$selection,pages=pages_pick$selection
      )
    ),
    manifestations=mans,
    provenance=list(
      workflow01_run_id=as.character(run_id),
      generated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ"),
      source_manifestation_count=length(mans)
    ),
    abstract_enrichment=list(
      status="pending_workflow02",
      manifestations_missing_abstract=sum(vapply(mans,function(m)is.null(m$abstract),logical(1)))
    ),
    deduplication=list(
      status=if(length(mans)>1L)"reconciled" else "singleton",
      cluster_id=cid,
      member_count=length(mans),
      final=TRUE
    ),
    screening=list(status="pending"),
    species=list(),
    geography=list(),
    topics=list()
  )
  writeLines(toJSON(rec,auto_unbox=TRUE,null="null",na="null"),out,useBytes=TRUE)
}
close(out); on.exit(NULL,add=FALSE)

unapplied <- which(vapply(repair_application,function(z)!identical(z$status,"applied"),logical(1)))
dir.create(dirname(repair_audit_path),recursive=TRUE,showWarnings=FALSE)
ra <- file(repair_audit_path,"wt",encoding="UTF-8")
if(length(repair_application)) for(z in repair_application) writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null"),ra,useBytes=TRUE)
close(ra)
if(length(unapplied)) stop(sprintf("%d approved data-quality repairs were not applied",length(unapplied)),call.=FALSE)

manifest <- list(
  schema="living-evidence-map-canonical-manifest-v1",
  canonical_schema_version="living-evidence-map-canonical-v1",
  workflow="01",
  github_run_id=as.character(run_id),
  records=length(clusters),
  source_manifestations=manifestations_total,
  duplicate_clusters=duplicate_clusters,
  singleton_clusters=length(clusters)-duplicate_clusters,
  abstract_strip_actions=length(strip_keys),
  approved_data_quality_repairs=length(repairs),
  applied_data_quality_repairs=length(repair_application)-length(unapplied),
  repair_application_audit=basename(repair_audit_path),
  manifestations_missing_abstract=missing_abstract_manifestations,
  source_counts=as.list(source_counts),
  cluster_map_sha256=digest(file=cluster_map_path,algo="sha256",serialize=FALSE),
  canonical_jsonl_sha256=digest(file=output_path,algo="sha256",serialize=FALSE),
  canonical_jsonl_bytes=unname(file.info(output_path)$size),
  generated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null"),manifest_path,useBytes=TRUE)
cat(sprintf("PASS: canonical JSONL: %d work records from %d manifestations; %d approved repairs applied; %d strip actions\n",
            manifest$records,manifest$source_manifestations,manifest$applied_data_quality_repairs,manifest$abstract_strip_actions))
