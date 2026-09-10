#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(jsonlite)
  library(stringi)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL) { i <- match(flag,args); if (is.na(i)) return(default); if (i==length(args)) stop(sprintf('Missing value after %s',flag)); args[[i+1L]] }
input_path <- arg('--input','canonical_store/data/canonical/current/repair/records.jsonl')
output_dir <- arg('--output-dir','outputs/fresh_workflow02')
reviewed_dup_path <- arg('--reviewed-duplicates','/tmp/workflow02/reviewed_duplicates.jsonl')
reviewed_not_path <- arg('--reviewed-not-duplicates','/tmp/workflow02/reviewed_not_duplicates.json')
checkpoint_every <- as.integer(arg('--checkpoint-every','250'))
if (is.na(checkpoint_every) || checkpoint_every < 1L) stop('--checkpoint-every must be a positive integer')

dir.create(output_dir, recursive=TRUE, showWarnings=FALSE)
checkpoint_dir <- file.path(output_dir,'checkpoints'); dir.create(checkpoint_dir, recursive=TRUE, showWarnings=FALSE)
now_utc <- function() format(Sys.time(),tz='UTC',format='%Y-%m-%dT%H:%M:%SZ')
`%||%` <- function(x,y) if (is.null(x)) y else x

FUZZY_THRESHOLD <- 0.965
PROBABLE_THRESHOLD <- 0.985
DOI_TITLE_COMPATIBILITY_THRESHOLD <- 0.90
ABSTRACT_PROBABLE_THRESHOLD <- 0.88
ABSTRACT_HIGH_THRESHOLD <- 0.94
ABSTRACT_POSSIBLE_THRESHOLD <- 0.82
MAX_PREPRINT_YEAR_GAP <- 2L
AUTO_ABSTRACT_THRESHOLD <- 0.95
AUTO_TITLE_THRESHOLD <- 0.90
PREPRINT_SOURCE_TERMS <- c('biorxiv','medrxiv','arxiv','preprint','research square','repository','institutional repository','thesis','dissertation')
PREPRINT_TERMS <- c('preprint','biorxiv','medrxiv','arxiv','repository','working paper','repec','ssrn','hal')
VERSION_TERMS <- c('peer review','reply','comment','supplement','corrigendum','erratum','editorial','response to','version')

read_jsonl <- function(path) {
  x <- readLines(path,warn=FALSE,encoding='UTF-8'); x <- x[nzchar(trimws(x))]
  lapply(seq_along(x), function(i) tryCatch(fromJSON(x[[i]],simplifyVector=FALSE), error=function(e) stop(sprintf('Invalid JSONL at line %d: %s',i,conditionMessage(e)))))
}
write_jsonl <- function(rows,path) { con <- file(path,'wt',encoding='UTF-8'); on.exit(close(con)); for (x in rows) writeLines(toJSON(x,auto_unbox=TRUE,null='null',na='null',digits=NA),con) }
norm <- function(x) {
  if (is.null(x) || !length(x)) return('')
  s <- tolower(stringi::stri_trans_general(as.character(x)[1],'NFKD; [:Nonspacing Mark:] Remove; NFC'))
  s <- gsub('[^a-z0-9]+',' ',s,perl=TRUE); trimws(gsub('\\s+',' ',s,perl=TRUE))
}
payload <- function(r) { p <- r$lens$raw_payload %||% list(); if (!is.list(p)) stop('lens.raw_payload is not an object'); p }
canonical <- function(r) {
  c <- r$canonical
  if (is.list(c)) return(c)
  p <- payload(r); src <- p$source
  list(record_id=r$identity$record_id %||% r$record_id, lens_id=r$identity$lens_id %||% p$lens_id, title=p$title, authors=p$authors,
       year=p$year_published %||% p$date_published, source=if(is.list(src)) src$title else src, doi=NULL, abstract=p$abstract)
}
lens_id <- function(r) as.character(canonical(r)$lens_id %||% r$identity$lens_id %||% '')
extract_dois <- function(r) {
  c <- canonical(r); vals <- character()
  if (!is.null(c$doi) && nzchar(norm(c$doi))) vals <- c(vals,norm(c$doi))
  ids <- payload(r)$external_ids %||% list()
  if (is.list(ids)) for (it in ids) if (is.list(it) && norm(it$type)=='doi' && nzchar(norm(it$value))) vals <- c(vals,norm(it$value))
  unique(vals)
}
year_int <- function(x) { m <- regexpr('(?:19|20)[0-9]{2}',as.character(x %||% ''),perl=TRUE); if (m[1]<0) return(NA_integer_); as.integer(regmatches(as.character(x),m)[1]) }
author_values <- function(r) {
  a <- canonical(r)$authors %||% list(); out <- character()
  if (is.character(a) && length(a)==1L) return(Filter(nzchar,vapply(strsplit(a,'\\s*\\|\\s*|\\s*;\\s*',perl=TRUE)[[1]],norm,character(1))))
  if (!is.list(a)) return(out)
  for (x in head(a,10)) {
    v <- if (is.list(x)) { z <- paste(Filter(nzchar,c(norm(x$last_name),norm(x$first_name))),collapse=' '); if (!nzchar(z)) norm(x$name) else z } else norm(x)
    if (nzchar(v)) out <- c(out,v)
  }; out
}
prepared <- function(r) {
  c <- canonical(r); tk <- norm(c$title); av <- author_values(r)
  list(lens_id=lens_id(r), record_id=as.character(c$record_id %||% ''), title=as.character(c$title %||% ''), title_key=tk,
       abstract_key=norm(c$abstract), doi_keys=extract_dois(r), year_key=norm(c$year), year=year_int(c$year), source_key=norm(c$source),
       first_author_key=if(length(av)) av[[1]] else '', title_prefix=substr(tk,1,24), title_token_key=paste(sort(unique(head(strsplit(tk,' +')[[1]],8))),collapse=' '))
}
# Python-compatible Jaro-Winkler-like title similarity.
jaro <- function(a,b) {
  if (identical(a,b)) return(if(nzchar(a)) 1 else 0); if(!nzchar(a)||!nzchar(b)) return(0)
  aa <- strsplit(a,'',fixed=TRUE)[[1]]; bb <- strsplit(b,'',fixed=TRUE)[[1]]; if(length(aa)>length(bb)){tmp<-aa;aa<-bb;bb<-tmp}
  d <- max(floor(length(bb)/2)-1,0); am<-rep(FALSE,length(aa)); bm<-rep(FALSE,length(bb)); matches<-0L
  for(i in seq_along(aa)){ lo<-max(1,i-d); hi<-min(length(bb),i+d); if(lo<=hi) for(j in lo:hi) if(!bm[j]&&aa[i]==bb[j]){am[i]<-TRUE;bm[j]<-TRUE;matches<-matches+1L;break} }
  if(matches==0) return(0); x<-aa[am]; y<-bb[bm]; trans<-sum(x!=y)/2; (matches/length(aa)+matches/length(bb)+(matches-trans)/matches)/3
}
title_similarity <- function(a,b) { if(!nzchar(a)||!nzchar(b)) return(0); j<-jaro(a,b); aa<-strsplit(a,'',fixed=TRUE)[[1]];bb<-strsplit(b,'',fixed=TRUE)[[1]]; p<-0L; for(k in seq_len(min(4,length(aa),length(bb)))){if(aa[k]!=bb[k])break;p<-p+1L}; j+p*0.1*(1-j) }
token_cosine <- function(a,b) { if(!nzchar(a)||!nzchar(b)) return(0); ca<-table(strsplit(a,' +')[[1]]); cb<-table(strsplit(b,' +')[[1]]); sh<-intersect(names(ca),names(cb)); if(!length(sh)) return(0); sum(ca[sh]*cb[sh])/sqrt(sum(ca^2)*sum(cb^2)) }
source_preprint_missing <- function(s) !nzchar(s) || any(vapply(PREPRINT_SOURCE_TERMS,function(t)grepl(t,s,fixed=TRUE),logical(1)))
pair_key <- function(a,b) paste(sort(c(as.character(a),as.character(b))),collapse='|')
pair_hash <- function(a,b) substr(digest(pair_key(a,b),algo='sha256',serialize=FALSE),1,16)

records <- read_jsonl(input_path); n <- length(records); prep <- lapply(records,prepared)
ids <- vapply(prep,`[[`,character(1),'lens_id'); if(any(!nzchar(ids))||anyDuplicated(ids)) stop('Lens-ID invariant failed before Workflow 02')
if(any(vapply(records,function(r)!is.null(r$screening)||!is.null(r$screening_history),logical(1)))) stop('Screening state found before deduplication')
message(sprintf('Workflow 02: loaded %d records; starting candidate classification',n))

idx_env <- function() new.env(hash=TRUE,parent=emptyenv())
addidx <- function(e,k,i){ if(!nzchar(k))return(); old<-if(exists(k,e,inherits=FALSE))get(k,e) else integer(); assign(k,c(old,i),e) }
by_title<-idx_env();by_doi<-idx_env();by_author<-idx_env();by_prefix<-idx_env();by_token<-idx_env()
for(i in seq_len(n)){p<-prep[[i]];addidx(by_title,p$title_key,i);for(d in p$doi_keys)addidx(by_doi,d,i);addidx(by_author,p$first_author_key,i);addidx(by_prefix,p$title_prefix,i);addidx(by_token,p$title_token_key,i)}
getidx<-function(e,k)if(nzchar(k)&&exists(k,e,inherits=FALSE))get(k,e)else integer()

candidate_payload <- function(status,basis,m,tsim,asim=0,manifestation=NULL){x<-list(status=status,basis=basis,matched_master_record_id=m$record_id,matched_master_lens_id=m$lens_id,matched_master_title=m$title,title_similarity=round(tsim,6),abstract_similarity=round(asim,6));if(!is.null(manifestation))x$manifestation_pattern<-manifestation;x}
best_candidate<-function(xs){if(!length(xs))return(NULL); pri<-vapply(xs,function(x)switch(x$status,duplicate=1,probable_duplicate=3,possible_duplicate=4,doi_conflict_review=6,5),numeric(1)); xs[[order(pri,-vapply(xs,function(x)x$abstract_similarity%||%0,numeric(1)),-vapply(xs,function(x)x$title_similarity%||%0,numeric(1)))[1]]]}
match_record <- function(inc, comps){
  exact<-Filter(function(m)nzchar(inc$title_key)&&inc$title_key==m$title_key,comps);if(length(exact))return(candidate_payload('duplicate','exact normalised title',exact[[1]],1))
  dc<-list();if(length(inc$doi_keys))for(m in comps)if(length(intersect(inc$doi_keys,m$doi_keys))){ts<-title_similarity(inc$title_key,m$title_key);as<-token_cosine(inc$abstract_key,m$abstract_key); if(ts>=.90){st<-'duplicate';ba<-'matching DOI plus compatible title'}else if(!nzchar(inc$title_key)||!nzchar(m$title_key)){st<-'possible_duplicate';ba<-'matching DOI but one title unavailable'}else{st<-'doi_conflict_review';ba<-'matching DOI but discordant titles'};dc[[length(dc)+1]]<-candidate_payload(st,ba,m,ts,as)}
  chosen<-best_candidate(dc);if(!is.null(chosen)&&chosen$status!='doi_conflict_review')return(chosen)
  cs<-list();for(m in comps){same<-nzchar(inc$first_author_key)&&inc$first_author_key==m$first_author_key; gap<-if(!is.na(inc$year)&&!is.na(m$year))abs(inc$year-m$year)else NA; compat<-is.na(gap)||gap<=2;ts<-title_similarity(inc$title_key,m$title_key)
    if(same&&compat&&nzchar(inc$abstract_key)&&nzchar(m$abstract_key)){as<-token_cosine(inc$abstract_key,m$abstract_key);pre<-source_preprint_missing(inc$source_key)||source_preprint_missing(m$source_key);if(as>=.94){cs[[length(cs)+1]]<-candidate_payload('probable_duplicate','very high abstract similarity plus same first author and compatible publication year',m,ts,as,if(pre)'preprint_or_repository_to_later_manifestation'else'same_work_manifestation');next};if(as>=.88&&(pre||ts>=.80)){cs[[length(cs)+1]]<-candidate_payload('probable_duplicate','high abstract similarity plus same first author, compatible publication year, and preprint/repository or compatible-title evidence',m,ts,as,if(pre)'preprint_or_repository_to_later_manifestation'else'same_work_manifestation');next};if(as>=.82)cs[[length(cs)+1]]<-candidate_payload('possible_duplicate','moderate-high abstract similarity plus same first author and compatible publication year',m,ts,as,'possible_same_work_manifestation')}
    bases<-character();if(nzchar(inc$year_key)&&inc$year_key==m$year_key)bases<-c(bases,'same year');if(same)bases<-c(bases,'same first author');if(nzchar(inc$title_prefix)&&inc$title_prefix==m$title_prefix)bases<-c(bases,'same title prefix');if(nzchar(inc$title_token_key)&&inc$title_token_key==m$title_token_key)bases<-c(bases,'same title-token key');if(length(bases)&&ts>=FUZZY_THRESHOLD){prob<-ts>=PROBABLE_THRESHOLD&&bases[1]%in%c('same first author','same title prefix','same title-token key');cs[[length(cs)+1]]<-candidate_payload(if(prob)'probable_duplicate'else'possible_duplicate',sprintf('%s title similarity plus %s',if(prob)'very high'else'high',bases[1]),m,ts)}}
  best_candidate(c(cs,if(is.null(chosen))list()else list(chosen)))
}

candidates<-list();seen<-new.env(hash=TRUE,parent=emptyenv())
for(i in seq_len(n)){p<-prep[[i]];idx<-unique(c(getidx(by_title,p$title_key),unlist(lapply(p$doi_keys,function(d)getidx(by_doi,d))),getidx(by_prefix,p$title_prefix),getidx(by_token,p$title_token_key))); if(nzchar(p$first_author_key)){jj<-getidx(by_author,p$first_author_key);jj<-jj[jj<i]; if(length(jj)){ok<-vapply(jj,function(j){q<-prep[[j]];is.na(p$year)||is.na(q$year)||abs(p$year-q$year)<=2},logical(1));idx<-unique(c(idx,jj[ok]))}};idx<-sort(idx[idx<i]);if(length(idx)){d<-match_record(p,prep[idx]);if(!is.null(d)){mi<-idx[match(d$matched_master_lens_id,vapply(prep[idx],`[[`,character(1),'lens_id'))];key<-pair_key(p$lens_id,d$matched_master_lens_id);if(nzchar(d$matched_master_lens_id)&&!exists(key,seen,inherits=FALSE)){assign(key,TRUE,seen);candidates[[length(candidates)+1]]<-c(list(record_index=i-1L,lens_id=p$lens_id,record_id=p$record_id,title=p$title,year=if(is.na(p$year))NULL else p$year,matched_index=mi-1L),d)}}}; if(i%%checkpoint_every==0L||i==n){writeLines(toJSON(list(phase='candidate_classification',processed_records=i,total_records=n,candidate_pairs=length(candidates),updated_at=now_utc()),auto_unbox=TRUE,pretty=TRUE),file.path(checkpoint_dir,'checkpoint_manifest.json'));message(sprintf('Workflow 02 checkpoint: candidate classification %d/%d; %d candidate pairs',i,n,length(candidates)))}}
write_jsonl(candidates,file.path(output_dir,'candidates.jsonl'))
writeLines(toJSON(list(record_count=n,unique_lens_ids=length(unique(ids)),candidate_pairs=length(candidates),audit_only=TRUE,canonical_modified=FALSE),auto_unbox=TRUE,pretty=TRUE),file.path(output_dir,'classification_summary.json'))

# Reviewed duplicate overrides and conservative augmentation.
reviewed_dup<-if(file.exists(reviewed_dup_path))read_jsonl(reviewed_dup_path)else list();review_map<-setNames(reviewed_dup,vapply(reviewed_dup,function(x)pair_key(x$lens_id_a,x$lens_id_b),character(1)))
author_jaccard<-function(a,b){aa<-unique(author_values(a));bb<-unique(author_values(b));if(!length(aa)||!length(bb))return(0);length(intersect(aa,bb))/length(union(aa,bb))}
title_jaccard<-function(a,b){aa<-unique(strsplit(norm(canonical(a)$title),' +')[[1]]);bb<-unique(strsplit(norm(canonical(b)$title),' +')[[1]]);if(!length(aa)||!length(bb))return(0);length(intersect(aa,bb))/length(union(aa,bb))}
is_preprint_like<-function(r){txt<-paste(norm(payload(r)$publication_type),norm(canonical(r)$source));any(vapply(PREPRINT_TERMS,function(t)grepl(t,txt,fixed=TRUE),logical(1)))}
has_version<-function(a,b){txt<-paste(norm(canonical(a)$title),norm(canonical(b)$title));any(vapply(VERSION_TERMS,function(t)grepl(t,txt,fixed=TRUE),logical(1)))}
aug<-lapply(candidates,function(ca){a<-records[[ca$record_index+1L]];b<-records[[ca$matched_index+1L]];k<-pair_key(lens_id(a),lens_id(b));if(k%in%names(review_map)){d<-review_map[[k]];ca$status<-'duplicate';ca$basis<-'human-reviewed duplicate adjudication';ca$reviewed_adjudication<-list(decision='duplicate',source='workflow02_reviewed_duplicate_pairs_2026-09-07',source_queue_row=d$source_queue_row,pattern=d$pattern);return(ca)};if(ca$status=='duplicate')return(ca);aj<-author_jaccard(a,b);tj<-title_jaccard(a,b);ya<-year_int(canonical(a)$year);yb<-year_int(canonical(b)$year);gap<-if(!is.na(ya)&&!is.na(yb))abs(ya-yb)else 0;ts<-as.numeric(ca$title_similarity%||%0);as<-as.numeric(ca$abstract_similarity%||%0); if(xor(is_preprint_like(a),is_preprint_like(b))&&gap<=2&&aj>=.60&&!has_version(a,b)&&((as>=.88&&tj>=.65)||ts>=.95)){ca$status<-'duplicate';ca$basis<-'conservative preprint/repository/working-paper manifestation rule';ca$automation_signal<-'preprint_repository_manifestation_v2'} else if((!nzchar(norm(canonical(a)$source))||!length(extract_dois(a))||!nzchar(norm(canonical(b)$source))||!length(extract_dois(b)))&&gap<=2&&aj>=.80&&ts>=.97&&!has_version(a,b)){ca$status<-'duplicate';ca$basis<-'conservative sparse-metadata duplicate rule';ca$automation_signal<-'sparse_metadata_duplicate_v1'};ca})
write_jsonl(aug,file.path(output_dir,'candidates_augmented.jsonl'))

# Remove reviewed not-duplicate pairs by the same SHA256 convention.
reviewed_not<-fromJSON(reviewed_not_path,simplifyVector=FALSE);if(reviewed_not$decision!='not_duplicate')stop('Reviewed not-duplicate decision file invalid');hashes<-vapply(reviewed_not$pairs,function(x)as.character(x$hash),character(1));if(length(unique(hashes))!=as.integer(reviewed_not$count))stop('Reviewed not-duplicate hash count mismatch')
rmflag<-vapply(aug,function(ca)pair_hash(ca$lens_id,ca$matched_master_lens_id)%in%hashes,logical(1));kept<-aug[!rmflag];removed<-aug[rmflag];write_jsonl(kept,file.path(output_dir,'candidates_reviewed.jsonl'));write_jsonl(removed,file.path(output_dir,'reviewed_not_duplicate_audit.jsonl'))
missing_hashes<-setdiff(hashes,vapply(removed,function(ca)pair_hash(ca$lens_id,ca$matched_master_lens_id),character(1)));writeLines(toJSON(list(input_candidates=length(aug),output_candidates=length(kept),reviewed_not_duplicate_pairs_loaded=length(hashes),reviewed_not_duplicate_pairs_removed=length(removed),reviewed_hashes_not_present_in_current_candidates=length(missing_hashes),missing_hashes=missing_hashes,canonical_modified=FALSE),auto_unbox=TRUE,pretty=TRUE),file.path(output_dir,'not_duplicate_filter_summary.json'))

# Conservative resolution. Reviewed/deterministic duplicate pairs collapse; all other non-reviewed candidates queue.
score<-function(r){c<-canonical(r);c(if(nzchar(norm(c$source)))4 else 0,if(length(extract_dois(r)))3 else 0,if(!is.null(payload(r)$volume)&&nzchar(as.character(payload(r)$volume)))2 else 0,if(!is.null(payload(r)$start_page)&&nzchar(as.character(payload(r)$start_page)))2 else 0,min(length(author_values(r)),10),min(nchar(norm(c$abstract)),5000),min(nchar(norm(c$title)),1000),ifelse(is.na(year_int(c$year)),0,year_int(c$year)))}
compat_auth<-function(a,b){aa<-author_values(a);bb<-author_values(b);length(aa)&&length(bb)&&aa[1]==bb[1]&&length(intersect(aa,bb))>0}
compat_year<-function(a,b){ya<-year_int(canonical(a)$year);yb<-year_int(canonical(b)$year);is.na(ya)||is.na(yb)||abs(ya-yb)<=2}
auto_pairs<-list();queued<-list()
for(ca in kept){a<-records[[ca$record_index+1L]];b<-records[[ca$matched_index+1L]];disp<-FALSE;rule<-NULL;if(ca$status=='duplicate'){disp<-TRUE;rule<-'deterministic_duplicate'}else if((ca$manifestation_pattern%||%'')=='preprint_or_repository_to_later_manifestation'&&as.numeric(ca$abstract_similarity%||%0)>=.90){disp<-TRUE;rule<-'high_confidence_preprint_version'}else if((ca$manifestation_pattern%||%'')=='same_work_manifestation'&&as.numeric(ca$abstract_similarity%||%0)>=.95&&as.numeric(ca$title_similarity%||%0)>=.85){disp<-TRUE;rule<-'very_high_confidence_same_work_version'}else if(as.numeric(ca$abstract_similarity%||%0)>=AUTO_ABSTRACT_THRESHOLD&&as.numeric(ca$title_similarity%||%0)>=AUTO_TITLE_THRESHOLD&&compat_auth(a,b)&&compat_year(a,b)){disp<-TRUE;rule<-'high_abstract_title_similarity_compatible_bibliography'};ca$resolution_rule<-rule%||%'requires_adjudication';if(disp)auto_pairs[[length(auto_pairs)+1]]<-ca else queued[[length(queued)+1]]<-ca}
# union-find
parent<-seq_len(n);find<-function(x){while(parent[x]!=x){parent[x]<<-parent[parent[x]];x<-parent[x]};x};unionf<-function(a,b){ra<-find(a);rb<-find(b);if(ra!=rb)parent[rb]<<-ra}
for(ca in auto_pairs)unionf(ca$record_index+1L,ca$matched_index+1L)
touched<-unique(unlist(lapply(auto_pairs,function(ca)c(ca$record_index+1L,ca$matched_index+1L))));groups<-split(touched,vapply(touched,find,integer(1)))
rep_by<-rep(NA_integer_,n);members<-vector('list',n);rules<-vector('list',n)
for(g in groups){vals<-lapply(g,function(i)score(records[[i]]));ord<-do.call(order,c(lapply(seq_len(length(vals[[1]])),function(k)-vapply(vals,`[`,numeric(1),k)),list(na.last=TRUE)));rep<-g[ord[1]];for(i in g)rep_by[i]<-rep;members[[rep]]<-setdiff(g,rep);rr<-unique(unlist(lapply(auto_pairs,function(ca)if((ca$record_index+1L)%in%g&&(ca$matched_index+1L)%in%g)ca$resolution_rule else NULL)));rules[[rep]]<-rr}
review_refs<-vector('list',n);for(ca in queued){a<-ca$record_index+1L;b<-ca$matched_index+1L;link<-list(status=ca$status,basis=ca$basis,title_similarity=ca$title_similarity,abstract_similarity=ca$abstract_similarity,manifestation_pattern=ca$manifestation_pattern);review_refs[[a]]<-c(review_refs[[a]],list(c(link,list(other_index=b-1L,other_lens_id=lens_id(records[[b]])))));review_refs[[b]]<-c(review_refs[[b]],list(c(link,list(other_index=a-1L,other_lens_id=lens_id(records[[a]])))))}
output<-vector('list',n);counts<-integer();names(counts)<-character()
for(i in seq_len(n)){r<-records[[i]];if(length(review_refs[[i]])){d<-list(workflow='02_deduplication',implementation_language='R',status='adjudication_required',downstream_eligible=FALSE,candidate_links=review_refs[[i]])}else if(!is.na(rep_by[i])){rep<-rep_by[i];if(i==rep)d<-list(workflow='02_deduplication',implementation_language='R',status='canonical',downstream_eligible=TRUE,duplicate_members=vapply(members[[rep]],function(j)lens_id(records[[j]]),character(1)),resolution_rules=rules[[rep]])else d<-list(workflow='02_deduplication',implementation_language='R',status='duplicate',downstream_eligible=FALSE,duplicate_of=lens_id(records[[rep]]),representative_index=rep-1L,resolution_rules=rules[[rep]])}else d<-list(workflow='02_deduplication',implementation_language='R',status='unique',downstream_eligible=TRUE);r$deduplication<-d;output[[i]]<-r;st<-d$status;counts[st]<-(counts[st]%||%0)+1L;if(i%%checkpoint_every==0L||i==n){write_jsonl(output[seq_len(i)],file.path(checkpoint_dir,'annotated_records.partial.jsonl'));writeLines(toJSON(list(phase='resolution',processed_records=i,total_records=n,status_counts=as.list(counts),updated_at=now_utc()),auto_unbox=TRUE,pretty=TRUE),file.path(checkpoint_dir,'checkpoint_manifest.json'));message(sprintf('Workflow 02 checkpoint: resolution %d/%d',i,n))}}
write_jsonl(output,file.path(output_dir,'annotated_records.jsonl'));write_jsonl(queued,file.path(output_dir,'adjudication_queue.jsonl'))
summary<-list(input_records=n,output_records=n,records_removed=0,unique=as.integer(counts['unique']%||%0),canonical=as.integer(counts['canonical']%||%0),duplicates=as.integer(counts['duplicate']%||%0),adjudication_required=as.integer(counts['adjudication_required']%||%0),candidate_pairs=length(candidates),reviewed_not_duplicate_pairs_removed=length(removed),auto_duplicate_pairs=length(auto_pairs),queued_pairs=length(queued),implementation_language='R')
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null='null'),file.path(output_dir,'resolution_summary.json'));writeLines(toJSON(list(workflow='workflow_02_deduplication',created_at=now_utc(),summary=summary),auto_unbox=TRUE,pretty=TRUE,null='null'),file.path(output_dir,'resolution_audit.json'))
if(length(output)!=n||anyDuplicated(vapply(output,lens_id,character(1))))stop('Workflow 02 output cardinality/Lens-ID invariant failed')
message(toJSON(summary,auto_unbox=TRUE,pretty=TRUE));message('PASS: Workflow 02 R deduplication audit complete; no records removed; checkpointed annotations written.')
