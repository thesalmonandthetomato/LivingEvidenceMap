#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(data.table)
  library(jsonlite)
  library(stringdist)
  library(stringi)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){
  i<-match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

manual_path <- arg("--manual-review")
metadata_path <- arg("--metadata")
output_dir <- arg("--output-dir")
if(any(vapply(list(manual_path,metadata_path,output_dir),is.null,logical(1)))) {
  stop("Required: --manual-review --metadata --output-dir",call.=FALSE)
}
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

manual <- fread(manual_path,na.strings=c("","NA"))
meta <- fread(metadata_path,na.strings=c("","NA"))
stopifnot(nrow(manual)==285L)

norm <- function(x){
  if(is.na(x)||!nzchar(trimws(x))) return(NA_character_)
  z <- stri_trans_tolower(stri_trans_nfkc(x))
  z <- stri_replace_all_regex(z,"[\\p{P}\\p{S}\\p{Z}\\s]+","")
  if(!nzchar(z)) NA_character_ else z
}
trim_quotes_versions <- function(x){
  if(is.na(x)) return(NA_character_)
  z <- trimws(x)
  z <- stri_replace_all_regex(z,'^[\\"“”\'’]+|[\\"“”\'’]+$',"")
  z <- stri_replace_first_regex(z,"(?i)\\s*\\(v[0-9]+(?:\\.[0-9]+)*\\)\\s*$","")
  trimws(stri_replace_all_regex(z,'^[\\"“”\'’]+|[\\"“”\'’]+$',""))
}

strip_wrapper <- function(x){
  if(is.na(x)||!nzchar(trimws(x))) return(list(type=NA_character_,stripped=NA_character_))
  z <- trimws(x)

  # Additional file often carries a descriptor before "of <article title>".
  if(stri_detect_regex(z,"(?i)^additional\\s+file\\s*[0-9]+[a-z]?\\s*:")) {
    rem <- stri_replace_first_regex(z,"(?i)^additional\\s+file\\s*[0-9]+[a-z]?\\s*:\\s*","")
    if(stri_detect_regex(rem,"(?i)(?:^|\\.\\s+|\\s+)of\\s+.+$")) {
      rem <- stri_replace_first_regex(rem,"(?is)^.*?(?:^|\\.\\s+|\\s+)of\\s+","")
    }
    return(list(type="additional_file",stripped=trim_quotes_versions(rem)))
  }

  pats <- list(
    peer_review="(?i)^peer\\s*review\\s*#?\\s*[0-9]+\\s*(?:of|for)\\s*",
    supplementary_material="(?i)^supplementary\\s+(?:material|materials)\\s+from\\s*",
    supporting_information="(?i)^supporting\\s+information\\s+(?:for|of)\\s*:?\\s*",
    decision_letter="(?i)^decision\\s+letter\\s*(?:for|on|of|to)?\\s*:?\\s*",
    author_response="(?i)^author\\s+(?:response|reply)\\s*(?:for|to|on|of)?\\s*:?\\s*",
    dataset="(?i)^(?:data|dataset|data\\s*set)\\s+(?:from|for|of)\\s*:?\\s*"
  )
  for(nm in names(pats)){
    if(stri_detect_regex(z,pats[[nm]])){
      rem <- stri_replace_first_regex(z,pats[[nm]],"")
      return(list(type=nm,stripped=trim_quotes_versions(rem)))
    }
  }
  list(type=NA_character_,stripped=NA_character_)
}

generic_attachment_type <- function(x){
  if(is.na(x)) return(NA_character_)
  pats <- c(
    supplementary_file="(?i)^\\s*supplement(?:ary)?\\s+file\\s*[0-9]+[a-z]?\\.(?:xlsx?|docx?|csv|pdf|txt|zip)\\s*$",
    table="(?i)^\\s*table\\s*[0-9]+[a-z]?\\.(?:xlsx?|docx?|csv|pdf|txt)\\s*$",
    image="(?i)^\\s*image\\s*[0-9]+[a-z]?\\.(?:jpe?g|png|tiff?|gif)\\s*$"
  )
  for(nm in names(pats)) if(stri_detect_regex(x,pats[[nm]])) return(nm)
  NA_character_
}

supplement_doi_relation <- function(a,b){
  if(is.na(a)||is.na(b)||!nzchar(a)||!nzchar(b)) return(FALSE)
  a<-tolower(trimws(a)); b<-tolower(trimws(b))
  stri_detect_regex(a,paste0("^",stri_escape_regex(b),"\\.s[0-9]+$")) ||
    stri_detect_regex(b,paste0("^",stri_escape_regex(a),"\\.s[0-9]+$"))
}

# Full-corpus wrapper census.
full <- meta[,.(idx,title)]
for(side in c("type","stripped")) full[, (side):=NA_character_]
for(i in seq_len(nrow(full))){
  z<-strip_wrapper(full$title[[i]])
  full$type[[i]]<-z$type
  full$stripped[[i]]<-z$stripped
}
full[,generic_attachment:=vapply(title,generic_attachment_type,character(1))]
wrapper_counts <- full[!is.na(type),.(n=.N),by=type][order(-n)]
generic_counts <- full[!is.na(generic_attachment),.(n=.N),by=generic_attachment][order(-n)]
fwrite(wrapper_counts,file.path(output_dir,"full_corpus_wrapper_counts.csv"))
fwrite(generic_counts,file.path(output_dir,"full_corpus_generic_attachment_counts.csv"))

# Manual-review audit.
rows <- vector("list",nrow(manual))
for(i in seq_len(nrow(manual))){
  r<-manual[i]
  wi<-strip_wrapper(r$title_i); wj<-strip_wrapper(r$title_j)
  gi<-generic_attachment_type(r$title_i); gj<-generic_attachment_type(r$title_j)

  stripped_side <- NA_character_; wrapper_type <- NA_character_
  stripped_title <- NA_character_; other_title <- NA_character_
  if(!is.na(wi$type) && !is.na(wi$stripped) && nchar(norm(wi$stripped)%||%"")>=20L){
    stripped_side<-"i"; wrapper_type<-wi$type; stripped_title<-wi$stripped; other_title<-r$title_j
  } else if(!is.na(wj$type) && !is.na(wj$stripped) && nchar(norm(wj$stripped)%||%"")>=20L){
    stripped_side<-"j"; wrapper_type<-wj$type; stripped_title<-wj$stripped; other_title<-r$title_i
  }

  stripped_exact <- !is.na(stripped_title) && !is.na(other_title) &&
    identical(norm(stripped_title),norm(other_title))
  stripped_similarity <- if(!is.na(stripped_title) && !is.na(other_title)) {
    as.numeric(stringsim(norm(stripped_title),norm(other_title),method="jw",p=0.1))
  } else NA_real_

  generic_side <- if(!is.na(gi)) "i" else if(!is.na(gj)) "j" else NA_character_
  generic_type <- if(!is.na(gi)) gi else gj
  attachment_strong <- !is.na(generic_side) &&
    isTRUE(r$exact_abstract) &&
    isTRUE(r$first_author_match) &&
    !is.na(r$year_diff_vec) && r$year_diff_vec<=1 &&
    supplement_doi_relation(r$doi_i,r$doi_j)

  proposed_rule <- fifelse(
    stripped_exact,
    "wrapper_stripped_exact_title",
    fifelse(
      attachment_strong,
      "generic_attachment_exact_abstract_author_year_parent_doi",
      NA_character_
    )
  )

  rows[[i]]<-data.table(
    pair_key=r$pair_key,
    record_i=r$record_i,record_j=r$record_j,
    title_i=r$title_i,title_j=r$title_j,
    wrapper_side=stripped_side,wrapper_type=wrapper_type,
    stripped_title=stripped_title,other_title=other_title,
    stripped_exact_title=stripped_exact,
    stripped_title_similarity=stripped_similarity,
    generic_attachment_side=generic_side,
    generic_attachment_type=generic_type,
    exact_abstract=r$exact_abstract,
    first_author_match=r$first_author_match,
    year_diff=r$year_diff_vec,
    doi_i=r$doi_i,doi_j=r$doi_j,
    supplement_doi_relation=supplement_doi_relation(r$doi_i,r$doi_j),
    proposed_deterministic_rule=proposed_rule,
    proposed_duplicate=!is.na(proposed_rule)
  )
}
audit <- rbindlist(rows,use.names=TRUE,fill=TRUE)
fwrite(audit,file.path(output_dir,"manual_review_wrapper_audit.csv"))
fwrite(audit[proposed_duplicate==TRUE],file.path(output_dir,"manual_review_proposed_deterministic_duplicates.csv"))

summary <- list(
  schema="living-evidence-map-w01-wrapper-title-audit-v1",
  status="success",
  manual_review_pairs=nrow(manual),
  full_corpus_manifestations=nrow(meta),
  wrappers_in_full_corpus=sum(wrapper_counts$n),
  generic_attachments_in_full_corpus=sum(generic_counts$n),
  manual_pairs_with_substantive_wrapper=sum(!is.na(audit$wrapper_type)),
  manual_pairs_with_generic_attachment=sum(!is.na(audit$generic_attachment_type)),
  deterministic_duplicate_candidates=sum(audit$proposed_duplicate),
  by_rule=as.list(table(audit$proposed_deterministic_rule,useNA="no")),
  note="Read-only audit. No pair decisions or clusters modified."
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),
           file.path(output_dir,"summary.json"))
cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),"\n")
