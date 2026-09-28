#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(readr);library(digest)})

args <- commandArgs(trailingOnly=TRUE)
source_jsonl <- if(length(args)>=1L) args[[1L]] else stop("Missing canonical JSONL path",call.=FALSE)
out_csv <- if(length(args)>=2L) args[[2L]] else "docs/living_evidence_map.csv"
out_js <- if(length(args)>=3L) args[[3L]] else "docs/dashboard-data.js"
pointer_path <- if(length(args)>=4L) args[[4L]] else "docs/workflow08/zenodo/run-36329841121.json"

ontology_path <- Sys.getenv("TOPIC_ONTOLOGY_PATH","data/reference/topic_ontology_v3_6.csv")
iso_map_path <- Sys.getenv("ISO_NUMERIC_MAP_PATH","config/iso3_numeric_map.json")
gazetteer_path <- Sys.getenv("COUNTRY_GAZETTEER_PATH","config/global_country_gazetteer_v3.csv")
flow_counts_path <- Sys.getenv("WORKFLOW09_FLOW_COUNTS_PATH","docs/reporting/workflow_09/flow_counts.json")
expected_sha <- "ab5f10fd7b70c5a210c06770ab1f7548a5eac4b48cb9f0326fede6d751e8df67"

stopf <- function(...) stop(sprintf(...),call.=FALSE)
`%||%` <- function(x,y) if(is.null(x)||length(x)==0L)y else x
clean <- function(x){if(is.null(x)||length(x)==0L)return("");z<-as.character(x[[1L]]%||%"");if(is.na(z))"" else trimws(z)}
vec <- function(x){
  if(is.null(x)||length(x)==0L)return(character())
  z<-trimws(as.character(unlist(x,use.names=FALSE)))
  z<-z[!is.na(z)&nzchar(z)&!tolower(z)%in%c("na","n/a","nan","null","none","unknown")]
  unique(z)
}
safe_year <- function(x){z<-suppressWarnings(as.integer(substr(clean(x),1,4)));if(is.na(z)||z<1800L||z>2200L)"" else as.character(z)}

for(p in c(source_jsonl,pointer_path,ontology_path,flow_counts_path)) if(!file.exists(p)) stopf("Required input not found: %s",p)
if(!identical(tolower(digest(file=source_jsonl,algo="sha256",serialize=FALSE)),expected_sha)) stopf("Input is not the authoritative Workflow 08 canonical JSONL")

pointer <- fromJSON(pointer_path,simplifyVector=FALSE)
if(!identical(pointer$state,"corrected_final_adjudicated_canonical") ||
   as.character(pointer$zenodo_record_id)!="22998934" ||
   as.integer(pointer$canonical_records)!=19117L ||
   tolower(as.character(pointer$final_canonical_jsonl_sha256))!=expected_sha) stopf("Workflow 08 pointer validation failed")

ontology <- read_csv(ontology_path,show_col_types=FALSE,progress=FALSE)
ontology_problems <- problems(ontology)
if(nrow(ontology_problems)){
  print(ontology_problems,n=Inf)
  stopf("Ontology CSV has %d parsing problem(s)",nrow(ontology_problems))
} else {
  cat("PASS: ontology CSV parsed without problems\n")
}
required_ontology <- c("path_id","level_1","level_2","level_3","hierarchy_path","definition")
miss <- setdiff(required_ontology,names(ontology))
if(length(miss)) stopf("Ontology missing columns: %s",paste(miss,collapse=", "))
if(anyDuplicated(ontology$path_id)) stopf("Ontology path_id values are not unique")
onto_i <- setNames(seq_len(nrow(ontology)),as.character(ontology$path_id))

iso_numeric <- list()
if(file.exists(iso_map_path)){
  x<-fromJSON(iso_map_path,simplifyVector=TRUE)
  if(is.list(x)||is.vector(x)) iso_numeric<-as.list(x)
}
country_name_by_iso3 <- list()
if(file.exists(gazetteer_path)){
  g<-read_csv(gazetteer_path,show_col_types=FALSE,progress=FALSE)
  gazetteer_problems<-problems(g)
  if(nrow(gazetteer_problems)){
    print(gazetteer_problems,n=Inf)
    stopf("Country gazetteer CSV has %d parsing problem(s)",nrow(gazetteer_problems))
  } else {
    cat("PASS: country gazetteer CSV parsed without problems\n")
  }
  iso_col<-intersect(c("iso3","iso3c","alpha3","iso_a3"),names(g))
  name_col<-intersect(c("country_name","name","country","name_en"),names(g))
  if(length(iso_col)&&length(name_col)){
    for(j in seq_len(nrow(g))){
      k<-toupper(trimws(as.character(g[[iso_col[[1L]]]][[j]]%||%"")))
      v<-trimws(as.character(g[[name_col[[1L]]]][[j]]%||%""))
      if(nzchar(k)&&nzchar(v)) country_name_by_iso3[[k]]<-v
    }
  }
}

topic_definitions <- setNames(as.list(as.character(ontology$definition)),as.character(ontology$hierarchy_path))
topic_path_id_by_path <- setNames(as.list(as.character(ontology$path_id)),as.character(ontology$hierarchy_path))
species_counts<-list();country_counts<-list();country_species<-list();topic_tree<-list();dash_records<-list();flat_rows<-list();seen<-character()

inc <- function(lst,key){lst[[key]]<-as.integer(lst[[key]]%||%0L)+1L;lst}
tree_add <- function(tree,parts,rid){
  if(!length(parts))return(tree)
  nm<-parts[[1L]];node<-tree[[nm]]%||%list(count=0L,children=list(),ids=character())
  if(!(rid%in%node$ids)){node$ids<-c(node$ids,rid);node$count<-length(node$ids)}
  if(length(parts)>1L)node$children<-tree_add(node$children,parts[-1L],rid)
  tree[[nm]]<-node;tree
}
strip_tree <- function(tree){
  out<-list()
  for(nm in names(tree)){n<-tree[[nm]];out[[nm]]<-list(count=as.integer(n$count),children=strip_tree(n$children))}
  out
}

con<-file(source_jsonl,"rt",encoding="UTF-8");on.exit(close(con),add=TRUE)
line_no<-0L
repeat{
  lines<-readLines(con,n=500L,warn=FALSE)
  if(!length(lines))break
  for(line in lines){
    if(!nzchar(trimws(line)))next
    line_no<-line_no+1L
    rec<-tryCatch(fromJSON(line,simplifyVector=FALSE),error=function(e)stopf("Invalid JSON at record %d: %s",line_no,conditionMessage(e)))
    if(!identical(rec$schema_version,"living-evidence-map-canonical-v1")) stopf("Unexpected canonical schema at record %d",line_no)
    rid<-clean((rec$identity%||%list())$record_id)
    if(!nzchar(rid)||rid%in%seen) stopf("Invalid/duplicate record_id at record %d",line_no)
    seen<-c(seen,rid)
    if(!isTRUE((rec$screening%||%list())$final_included)) stopf("Final canonical contains non-included record %s",rid)

    can<-rec$canonical%||%list()
    spobj<-rec$species%||%list()
    geo<-rec$geography%||%list()
    top<-rec$topics%||%list()

    species<-vec(spobj$labels)
    if(!length(species)) stopf("Included record %s has no final species label",rid)
    isos<-toupper(vec(geo$iso3c))
    country_names<-vec(geo$country_names)

    assignments<-top$assignments%||%list()
    if(length(assignments)&&!is.list(assignments)) stopf("Topics are not structured for %s",rid)
    topic_ids<-character();paths<-character()
    if(length(assignments)){
      for(a in assignments){
        if(!is.list(a)) stopf("Malformed topic assignment for %s",rid)
        pid<-clean(a$path_id)
        if(!nzchar(pid)||is.null(onto_i[[pid]])) stopf("Unknown/missing topic path_id for %s",rid)
        opath<-as.character(ontology$hierarchy_path[[onto_i[[pid]]]])
        apath<-clean(a$hierarchy_path)
        if(nzchar(apath)&&!identical(apath,opath)) stopf("Topic hierarchy mismatch for %s / %s",rid,pid)
        topic_ids<-c(topic_ids,pid);paths<-c(paths,opath)
      }
    }
    if(anyDuplicated(topic_ids)) stopf("Duplicate topic path_id in %s",rid)

    topic_paths<-lapply(paths,function(p)trimws(strsplit(p,"\\s*>\\s*",perl=TRUE)[[1L]]))
    for(p in topic_paths) topic_tree<-tree_add(topic_tree,p,rid)
    for(s in species) species_counts<-inc(species_counts,s)
    for(z in isos){
      country_counts<-inc(country_counts,z)
      for(s in species){
        if(is.null(country_species[[s]]))country_species[[s]]<-list()
        country_species[[s]]<-inc(country_species[[s]],z)
      }
    }

    authors<-vec(can$authors)
    authors_text<-paste(authors,collapse="; ")
    dash_records[[length(dash_records)+1L]]<-list(
      record_id=rid,
      lens_id="",
      title=clean(can$title),
      abstract=clean(can$abstract),
      doi=clean(can$doi),
      year=safe_year(can$year),
      authors=authors_text,
      journal=clean(can$journal),
      volume=clean(can$volume),
      pages=clean(can$pages),
      lens_url="",
      species=as.list(species),
      countries=as.list(if(length(isos))isos else country_names),
      iso3=as.list(isos),
      topics=as.list(unique(unlist(topic_paths,use.names=FALSE))),
      topic_paths=lapply(topic_paths,as.list),
      topic_stars=list(),
      topic_path_ids=setNames(as.list(topic_ids),paths),
      topic_coded_at=clean(((rec$provenance%||%list())$workflow08%||%list())$finalised_at_utc)
    )
    flat_rows[[length(flat_rows)+1L]]<-data.frame(
      record_id=rid,title=clean(can$title),abstract=clean(can$abstract),doi=clean(can$doi),
      year=safe_year(can$year),authors=authors_text,journal=clean(can$journal),volume=clean(can$volume),
      issue=clean(can$issue),pages=clean(can$pages),species=paste(species,collapse="; "),
      iso3=paste(isos,collapse="; "),countries=paste(country_names,collapse="; "),
      topic_path_ids=paste(topic_ids,collapse="; "),topic_hierarchy_paths=paste(paths,collapse="; "),
      stringsAsFactors=FALSE
    )
  }
}
close(con);on.exit(NULL,add=FALSE)
if(length(dash_records)!=19117L) stopf("Expected 19117 final included records; built %d",length(dash_records))

flat<-do.call(rbind,flat_rows)
dir.create(dirname(out_csv),recursive=TRUE,showWarnings=FALSE)
write_csv(flat,out_csv,na="")

map_id_to_iso3<-list()
if(length(iso_numeric)){
  for(k in names(iso_numeric)){n<-suppressWarnings(as.integer(iso_numeric[[k]]));if(!is.na(n))map_id_to_iso3[[sprintf("%03d",n)]]<-toupper(k)}
}
flow_counts<-fromJSON(flow_counts_path,simplifyVector=FALSE)
screened_n<-as.integer((flow_counts$counts%||%list())$title_abstract_screened%||%NA_integer_)
if(is.na(screened_n)||screened_n!=32283L) stopf("Unexpected Workflow 09 screened count: %s",as.character(screened_n))
published_at<-clean(pointer$published_at_utc)
payload<-list(
  generated_at=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ"),
  source=list(
    workflow="08",
    canonical_jsonl="living_evidence_map_canonical_final.jsonl",
    zenodo_record_id=as.character(pointer$zenodo_record_id),
    doi=as.character(pointer$doi),
    canonical_sha256=expected_sha,
    source_github_run_id=as.character(pointer$source_github_run_id),
    ontology=ontology_path,
    ontology_version="3.6"
  ),
  metrics=list(
    total_records=length(dash_records),
    total_topics=nrow(ontology),
    total_countries=length(country_counts),
    total_species=length(species_counts),
    last_search=NULL,
    last_evidence_update=published_at,
    candidate_search_results_screened=screened_n
  ),
  species_display_order=c("Atlantic salmon","Chinook salmon","Chum salmon","Coho salmon","Masu salmon","Pink salmon","Sockeye salmon","Rainbow trout","Unspecified species"),
  species_counts=species_counts,
  country_iso3_counts=country_counts,
  country_iso3_species_counts=country_species,
  country_name_by_iso3=country_name_by_iso3,
  map_id_to_iso3=map_id_to_iso3,
  topic_tree=strip_tree(topic_tree),
  topic_definitions=topic_definitions,
  topic_path_id_by_path=topic_path_id_by_path,
  topic_level_labels=list("1"="High-level topic","2"="Topic","3"="Specific topic"),
  records=dash_records
)
dir.create(dirname(out_js),recursive=TRUE,showWarnings=FALSE)
writeLines(paste0("window.LIVING_EVIDENCE_MAP_DASHBOARD_DATA=",toJSON(payload,auto_unbox=TRUE,null="null",na="null",pretty=FALSE),";"),out_js,useBytes=TRUE)

topic_assignments<-sum(vapply(dash_records,function(r)length(r$topic_paths),integer(1)))
records_without_topics<-sum(vapply(dash_records,function(r)length(r$topic_paths)==0L,logical(1)))
manifest<-list(
  schema="living-evidence-map-workflow10-dashboard-v1",
  generated_at_utc=payload$generated_at,
  source_zenodo_record_id=as.character(pointer$zenodo_record_id),
  source_doi=as.character(pointer$doi),
  source_canonical_sha256=expected_sha,
  records=length(dash_records),
  topic_assignments=topic_assignments,
  records_without_topics=records_without_topics,
  countries=length(country_counts),
  species_categories=length(species_counts),
  output_csv=out_csv,
  output_js=out_js,
  output_js_sha256=digest(file=out_js,algo="sha256",serialize=FALSE)
)
write_json(manifest,file.path(dirname(out_js),"dashboard-data-manifest.json"),auto_unbox=TRUE,pretty=TRUE)
cat(sprintf("PASS: Workflow 10 dashboard projection: %d records; %d topic assignments; %d records without topics\n",length(dash_records),topic_assignments,records_without_topics))
