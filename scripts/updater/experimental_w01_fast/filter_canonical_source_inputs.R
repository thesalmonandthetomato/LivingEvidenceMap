#!/usr/bin/env Rscript
# Isolated input adapter for the unmodified W01 canonical JSONL builder.
# Filters source streams by stable identities from an affected cluster map.
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(x){i<-match(x,args);if(is.na(i)||i==length(args))stop(paste("Missing",x));args[[i+1L]]}
map_path<-arg("--affected-cluster-map");manifest_path<-arg("--input-manifest")
out<-arg("--output-dir")
if(file.exists(out)||dir.exists(out))stop("Refusing to overwrite output directory")
m<-fread(map_path,colClasses=list(character=c("source","source_record_id")))
if(!all(c("source","source_record_id","cluster_id","cluster_size")%in%names(m)))
 stop("Affected cluster map lacks canonical builder fields")
if(anyNA(m[,.(source,source_record_id)])||
 any(!nzchar(m$source)|!nzchar(m$source_record_id))||
 anyDuplicated(m[,.(source,source_record_id)]))stop("Invalid source identity")
# Production builder uses '::' concatenation: reject ambiguous keys rather
# than treating that concatenation as a reliable authoritative identifier.
if(any(grepl("::",m$source,fixed=TRUE)|grepl("::",m$source_record_id,fixed=TRUE)))
 stop("Unrepresentable source identity for legacy canonical builder")
key<-function(src,id)paste0(nchar(src,type="bytes"),":",src,nchar(id,type="bytes"),":",id)
wanted<-key(m$source,m$source_record_id)
im<-fromJSON(manifest_path,simplifyVector=FALSE)
if(!identical(im$schema,"living-evidence-map-workflow01-source-inputs-v1")||
 is.null(names(im$sources))||!length(im$sources))stop("Unsupported input manifest")
get_kind<-function(r){
 if(is.list(r$lens))return("lens")
 p<-r$source$provider
 if(is.null(p))stop("Missing provider")
 p<-as.character(p[[1L]])
 if(identical(p,"agricola_via_europe_pmc"))return("agricola")
 if(identical(p,"wos_starter"))return("wos")
 p
}
get_id<-function(r,src){
 if(src=="lens")return(as.character(r$identity$lens_id %||% r$identity$record_id %||% ""))
 as.character(r$sidecar_identity$sidecar_record_id %||% "")
}
`%||%`<-function(x,y)if(is.null(x))y else x
dir.create(out,recursive=TRUE)
selected<-character();sources<-list();counts<-list()
for(src in names(im$sources)){
 path<-as.character(im$sources[[src]][[1L]])
 if(!file.exists(path))stop(paste("Missing input stream",src),call.=FALSE)
 dest<-file.path(out,paste0(src,".jsonl"))
 input<-file(path,"rt",encoding="UTF-8")
 output<-file(dest,"wt",encoding="UTF-8")
 total<-0L
 repeat{
  lines<-readLines(input,n=500L,warn=FALSE)
  if(!length(lines))break
  for(line in lines){
   if(!nzchar(trimws(line)))next
   r<-fromJSON(line,simplifyVector=FALSE)
   kind<-get_kind(r);if(!identical(kind,src))stop("Source provider mismatch")
   id<-get_id(r,src)
   if(!nzchar(id))stop("Missing source record ID")
   if(grepl("::",id,fixed=TRUE))stop("Legacy key delimiter ambiguity")
   k<-key(src,id)
   if(k%in%wanted){
    if(k%in%selected)stop("Repeated affected source identity")
    writeLines(line,output,useBytes=TRUE)
    selected<-c(selected,k);total<-total+1L
   }
  }
 }
 close(input);close(output)
 sources[[src]]<-list(dest);counts[[src]]<-total
}
if(!setequal(selected,wanted)||length(selected)!=length(wanted))
 stop("Failed to select exactly the affected source identities")
writeLines(toJSON(list(schema=im$schema,sources=sources),
 pretty=TRUE,auto_unbox=TRUE),file.path(out,"filtered_source_inputs.json"))
writeLines(toJSON(list(schema="experimental-w01-fast-filtered-canonical-inputs-v1",
 selected_manifestations=length(selected),counts=counts,
 affected_map_sha256=digest(file=map_path,algo="sha256"),
 original_manifest_sha256=digest(file=manifest_path,algo="sha256"),
 production_publication_allowed=FALSE),pretty=TRUE,auto_unbox=TRUE),
 file.path(out,"filter_audit.json"))
cat(sprintf("PASS: selected exactly %d affected source identities\n",length(selected)))
