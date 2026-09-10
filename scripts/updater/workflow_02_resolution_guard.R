#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(jsonlite)
  library(stringi)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf('Missing value after %s', flag))
  args[[i+1L]]
}
input_path <- arg('--input')
candidates_path <- arg('--candidates')
output_dir <- arg('--output-dir','outputs/fresh_workflow02')
checkpoint_every <- as.integer(arg('--checkpoint-every','250'))
if (is.null(input_path) || is.null(candidates_path)) stop('--input and --candidates are required')
if (is.na(checkpoint_every) || checkpoint_every < 1L) stop('--checkpoint-every must be positive')

`%||%` <- function(x,y) if (is.null(x)) y else x
now_utc <- function() format(Sys.time(),tz='UTC',format='%Y-%m-%dT%H:%M:%SZ')
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)
checkpoint_dir <- file.path(output_dir,'checkpoints')
dir.create(checkpoint_dir,recursive=TRUE,showWarnings=FALSE)

read_jsonl <- function(path) {
  x <- readLines(path,warn=FALSE,encoding='UTF-8')
  x <- x[nzchar(trimws(x))]
  lapply(seq_along(x), function(i) tryCatch(fromJSON(x[[i]],simplifyVector=FALSE), error=function(e) stop(sprintf('Invalid JSONL %s line %d: %s',path,i,conditionMessage(e)))))
}
write_jsonl <- function(rows,path) {
  con <- file(path,'wt',encoding='UTF-8'); on.exit(close(con))
  for (x in rows) writeLines(toJSON(x,auto_unbox=TRUE,null='null',na='null',digits=NA),con)
}
norm <- function(x) {
  if (is.null(x) || !length(x)) return('')
  s <- tolower(stringi::stri_trans_general(as.character(x)[1],'NFKD; [:Nonspacing Mark:] Remove; NFC'))
  trimws(gsub('\\s+',' ',gsub('[^a-z0-9]+',' ',s,perl=TRUE),perl=TRUE))
}
payload <- function(r) { p <- r$lens$raw_payload %||% list(); if (!is.list(p)) list() else p }
canonical <- function(r) {
  if (is.list(r$canonical)) return(r$canonical)
  p <- payload(r); src <- p$source
  list(lens_id=r$identity$lens_id %||% p$lens_id,title=p$title,authors=p$authors,year=p$year_published %||% p$date_published,source=if(is.list(src))src$title else src,doi=NULL,abstract=p$abstract)
}
lens_id <- function(r) as.character(canonical(r)$lens_id %||% r$identity$lens_id %||% '')
extract_dois <- function(r) {
  vals <- character(); c <- canonical(r)
  if (!is.null(c$doi) && nzchar(norm(c$doi))) vals <- c(vals,norm(c$doi))
  ids <- payload(r)$external_ids %||% list()
  if (is.list(ids)) for (it in ids) if (is.list(it) && norm(it$type)=='doi' && nzchar(norm(it$value))) vals <- c(vals,norm(it$value))
  unique(vals)
}
year_int <- function(x) { m<-regexpr('(?:19|20)[0-9]{2}',as.character(x%||%''),perl=TRUE); if(m[1]<0) return(NA_integer_); as.integer(regmatches(as.character(x),m)[1]) }
author_values <- function(r) {
  a <- canonical(r)$authors %||% list(); out <- character()
  if (is.character(a) && length(a)==1L) return(Filter(nzchar,vapply(strsplit(a,'\\s*\\|\\s*|\\s*;\\s*',perl=TRUE)[[1]],norm,character(1))))
  if (!is.list(a)) return(out)
  for (x in a) {
    v <- if (is.list(x)) { z<-paste(Filter(nzchar,c(norm(x$last_name),norm(x$first_name))),collapse=' '); if(nzchar(z))z else norm(x$name) } else norm(x)
    if (nzchar(v)) out <- c(out,v)
  }
  out
}
source_title <- function(r) { c<-canonical(r); s<-payload(r)$source; raw<-if(is.list(s))s$title else s; as.character(c$source %||% raw %||% '') }
publication_type <- function(r) as.character(payload(r)$publication_type %||% '')
page_int <- function(x) { m<-regexpr('[0-9]+',as.character(x%||%''),perl=TRUE); if(m[1]<0)return(NA_integer_); as.integer(regmatches(as.character(x),m)[1]) }
PREPRINT_TERMS <- c('preprint','biorxiv','medrxiv','arxiv','repository','thesis','dissertation')
is_preprint_like <- function(r) { txt<-paste(norm(publication_type(r)),norm(source_title(r))); !nzchar(norm(source_title(r))) || any(vapply(PREPRINT_TERMS,function(t)grepl(t,txt,fixed=TRUE),logical(1))) }
compatible_authors <- function(a,b) { aa<-author_values(a);bb<-author_values(b);length(aa)>0&&length(bb)>0&&aa[1]==bb[1]&&length(intersect(aa,bb))>0 }
compatible_year <- function(a,b) { ya<-year_int(canonical(a)$year);yb<-year_int(canonical(b)$year);is.na(ya)||is.na(yb)||abs(ya-yb)<=2 }
page_ranges_nonoverlap <- function(a,b) { pa<-payload(a);pb<-payload(b);sa<-page_int(pa$start_page);sb<-page_int(pb$start_page);if(is.na(sa)||is.na(sb)||sa==sb)return(FALSE);ea<-page_int(pa$end_page);eb<-page_int(pb$end_page);if(is.na(ea))ea<-sa;if(is.na(eb))eb<-sb;ea<sb||eb<sa }
different_nonempty <- function(a,b) { na<-norm(a);nb<-norm(b);nzchar(na)&&nzchar(nb)&&na!=nb }

strong_distinct <- function(a,b,ca) {
  if (is_preprint_like(a) || is_preprint_like(b)) return(NULL)
  ta<-norm(canonical(a)$title);tb<-norm(canonical(b)$title)
  if (nzchar(ta)&&ta==tb) return(NULL)
  pa<-payload(a);pb<-payload(b);sa<-norm(source_title(a));sb<-norm(source_title(b))
  same_source<-nzchar(sa)&&sa==sb; diff_source<-nzchar(sa)&&nzchar(sb)&&sa!=sb
  same_volume<-nzchar(norm(pa$volume))&&norm(pa$volume)==norm(pb$volume)
  diff_volume<-different_nonempty(pa$volume,pb$volume)
  same_issue<-nzchar(norm(pa$issue))&&norm(pa$issue)==norm(pb$issue)
  diff_issue<-different_nonempty(pa$issue,pb$issue)
  spa<-page_int(pa$start_page);spb<-page_int(pb$start_page);diff_start<-!is.na(spa)&&!is.na(spb)&&spa!=spb
  nonoverlap<-page_ranges_nonoverlap(a,b); tsim<-as.numeric(ca$title_similarity%||%0)
  da<-extract_dois(a);db<-extract_dois(b);disjoint_doi<-length(da)>0&&length(db)>0&&length(intersect(da,db))==0
  if (diff_source&&disjoint_doi&&tsim<.985) return(list(rule='reject_different_journal_doi_title',evidence=c('different journal/source','different DOI values','materially different titles',if(diff_volume)'different volume',if(diff_start||nonoverlap)'different pagination')))
  if (same_source&&same_volume&&nonoverlap&&tsim<.985) return(list(rule='reject_distinct_pagination',evidence=c('same journal and volume','non-overlapping pagination','materially different titles',if(disjoint_doi)'different DOI values',if(diff_issue)'different issue')))
  if (same_source&&same_issue&&disjoint_doi&&diff_start&&tsim<.985) return(list(rule='reject_same_issue_distinct_article',evidence=c('same journal and issue','different DOI values','different start pages/article locations','materially different titles')))
  NULL
}

survivor_score <- function(r) {
  c<-canonical(r)
  c(if(nzchar(norm(source_title(r))))4 else 0,if(length(extract_dois(r)))3 else 0,if(nzchar(norm(payload(r)$volume)))2 else 0,if(nzchar(norm(payload(r)$start_page)))2 else 0,min(length(author_values(r)),10),min(nchar(norm(c$abstract)),5000),min(nchar(norm(c$title)),1000),ifelse(is.na(year_int(c$year)),0,year_int(c$year)))
}

records <- read_jsonl(input_path); candidates <- read_jsonl(candidates_path); n <- length(records)
ids<-vapply(records,lens_id,character(1)); if(any(!nzchar(ids))||anyDuplicated(ids))stop('Lens-ID invariant failed')
message(sprintf('Workflow 02 guarded resolution: %d records; %d reviewed candidate pairs',n,length(candidates)))

auto_pairs<-list();queued<-list();rejected<-list();rule_counts<-integer();names(rule_counts)<-character();reject_counts<-integer();names(reject_counts)<-character()
inc_count <- function(v,k){v[k]<-if(is.na(v[k]))1L else v[k]+1L;v}
for (ca in candidates) {
  ai<-as.integer(ca$record_index)+1L;bi<-as.integer(ca$matched_index)+1L
  if (is.na(ai)||is.na(bi)||ai<1||bi<1||ai>n||bi>n) { ca$resolution_rule<-'invalid_pair_indices';queued[[length(queued)+1]]<-ca;next }
  a<-records[[ai]];b<-records[[bi]]
  sd<-strong_distinct(a,b,ca)
  if (!is.null(sd)) { ca$resolution_rule<-sd$rule;ca$resolution_evidence<-Filter(Negate(is.null),sd$evidence);rejected[[length(rejected)+1]]<-ca;reject_counts<-inc_count(reject_counts,sd$rule);next }
  asim<-as.numeric(ca$abstract_similarity%||%0);tsim<-as.numeric(ca$title_similarity%||%0);manifest<-ca$manifestation_pattern%||%''
  rule<-NULL
  if (identical(ca$status,'duplicate')) rule<-'deterministic_duplicate'
  else if (manifest=='preprint_or_repository_to_later_manifestation'&&asim>=.90) rule<-'high_confidence_preprint_version'
  else if (manifest=='same_work_manifestation'&&asim>=.95&&tsim>=.85) rule<-'very_high_confidence_same_work_version'
  else if (asim>=.95&&tsim>=.90&&compatible_authors(a,b)&&compatible_year(a,b)) rule<-'high_abstract_title_similarity_compatible_bibliography'
  if (is.null(rule)) {ca$resolution_rule<-'requires_adjudication';queued[[length(queued)+1]]<-ca} else {ca$resolution_rule<-rule;auto_pairs[[length(auto_pairs)+1]]<-ca;rule_counts<-inc_count(rule_counts,rule)}
}
message(sprintf('Resolution dispositions: %d auto-duplicate; %d rejected as distinct; %d queued',length(auto_pairs),length(rejected),length(queued)))
write_jsonl(rejected,file.path(output_dir,'rejected_distinct_pairs.jsonl'))

parent<-seq_len(n)
find_root<-function(x){while(parent[x]!=x){parent[x]<<-parent[parent[x]];x<-parent[x]};x}
unionf<-function(a,b){ra<-find_root(a);rb<-find_root(b);if(ra!=rb)parent[rb]<<-ra}
for(ca in auto_pairs)unionf(ca$record_index+1L,ca$matched_index+1L)
touched<-unique(unlist(lapply(auto_pairs,function(ca)c(ca$record_index+1L,ca$matched_index+1L))))
groups<-if(length(touched))split(touched,vapply(touched,find_root,integer(1)))else list()
rep_by<-rep(NA_integer_,n);members<-vector('list',n);rules<-vector('list',n)
for(g in groups){vals<-lapply(g,function(i)survivor_score(records[[i]]));ord<-do.call(order,c(lapply(seq_len(length(vals[[1]])),function(k)-vapply(vals,`[`,numeric(1),k)),list(na.last=TRUE)));rep<-g[ord[1]];for(i in g)rep_by[i]<-rep;members[[rep]]<-setdiff(g,rep);rules[[rep]]<-unique(unlist(lapply(auto_pairs,function(ca)if((ca$record_index+1L)%in%g&&(ca$matched_index+1L)%in%g)ca$resolution_rule else NULL)))}
review_refs<-vector('list',n)
for(ca in queued){a<-ca$record_index+1L;b<-ca$matched_index+1L;if(a<1||b<1||a>n||b>n)next;link<-list(status=ca$status,basis=ca$basis,title_similarity=ca$title_similarity,abstract_similarity=ca$abstract_similarity,manifestation_pattern=ca$manifestation_pattern);review_refs[[a]]<-c(review_refs[[a]],list(c(link,list(other_index=b-1L,other_lens_id=lens_id(records[[b]])))));review_refs[[b]]<-c(review_refs[[b]],list(c(link,list(other_index=a-1L,other_lens_id=lens_id(records[[a]])))))}

partial_path<-file.path(checkpoint_dir,'annotated_records.partial.jsonl');if(file.exists(partial_path))file.remove(partial_path);con<-file(partial_path,'at',encoding='UTF-8');on.exit(close(con),add=TRUE)
counts<-c(unique=0L,canonical=0L,duplicate=0L,adjudication_required=0L)
for(i in seq_len(n)){
  r<-records[[i]]
  if(length(review_refs[[i]])) d<-list(workflow='02_deduplication',implementation_language='R',status='adjudication_required',downstream_eligible=FALSE,candidate_links=review_refs[[i]])
  else if(!is.na(rep_by[i])){rep<-rep_by[i];if(i==rep)d<-list(workflow='02_deduplication',implementation_language='R',status='canonical',downstream_eligible=TRUE,duplicate_members=vapply(members[[rep]],function(j)lens_id(records[[j]]),character(1)),resolution_rules=rules[[rep]])else d<-list(workflow='02_deduplication',implementation_language='R',status='duplicate',downstream_eligible=FALSE,duplicate_of=lens_id(records[[rep]]),representative_index=rep-1L,resolution_rules=rules[[rep]])}
  else d<-list(workflow='02_deduplication',implementation_language='R',status='unique',downstream_eligible=TRUE)
  r$deduplication<-d;counts[d$status]<-counts[d$status]+1L
  writeLines(toJSON(r,auto_unbox=TRUE,null='null',na='null',digits=NA),con);flush(con)
  if(i%%checkpoint_every==0L||i==n){writeLines(toJSON(list(phase='guarded_resolution',processed_records=i,total_records=n,status_counts=as.list(counts),updated_at=now_utc()),auto_unbox=TRUE,pretty=TRUE),file.path(checkpoint_dir,'checkpoint_manifest.json'));message(sprintf('Workflow 02 checkpoint: guarded resolution %d/%d',i,n))}
}
close(con)
file.copy(partial_path,file.path(output_dir,'annotated_records.jsonl'),overwrite=TRUE)
write_jsonl(queued,file.path(output_dir,'adjudication_queue.jsonl'))
summary<-list(input_records=n,output_records=n,records_removed=0,unique=unname(counts['unique']),canonical=unname(counts['canonical']),duplicates=unname(counts['duplicate']),adjudication_required=unname(counts['adjudication_required']),candidate_pairs=length(candidates),auto_duplicate_pairs=length(auto_pairs),rejected_distinct_pairs=length(rejected),queued_pairs=length(queued),auto_rule_counts=as.list(rule_counts),rejection_reason_counts=as.list(reject_counts),implementation_language='R')
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null='null'),file.path(output_dir,'resolution_summary.json'))
writeLines(toJSON(list(workflow='workflow_02_deduplication',created_at=now_utc(),summary=summary),auto_unbox=TRUE,pretty=TRUE,null='null'),file.path(output_dir,'resolution_audit.json'))
if(sum(counts)!=n)stop('Status count invariant failed')
message(toJSON(summary,auto_unbox=TRUE,pretty=TRUE))
message('PASS: Workflow 02 guarded R resolution complete; bibliographic contradiction guard applied; append-only checkpoint output complete.')
