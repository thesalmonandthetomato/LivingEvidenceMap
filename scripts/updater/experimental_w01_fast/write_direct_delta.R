#!/usr/bin/env Rscript
# Experimental direct W01-Fast delta. No publication; fail-closed.
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
a<-commandArgs(trailingOnly=TRUE)
arg<-function(k){i<-match(k,a);if(is.na(i)||i==length(a))stop('Missing ',k);a[[i+1L]]}
prev<-arg('--previous-root');seed<-arg('--current-seed-root');final<-arg('--current-final-root')
canonical<-arg('--current-canonical');cm_path<-arg('--current-canonical-manifest')
pointer<-arg('--previous-pointer');scored_path<-arg('--new-decisions')
affected_map<-arg('--affected-map');changes<-arg('--canonical-changes')
affected_works<-arg('--affected-works');out<-arg('--output-dir');rid<-arg('--run-id')
if(file.exists(out)||dir.exists(out))stop('Refuse overwrite')
pmap<-file.path(prev,'workflow01_full_five_source','manifestation_cluster_map.csv')
ppairs<-file.path(prev,'workflow01_full_five_source','final_pair_decisions.csv')
fmap<-file.path(final,'manifestation_cluster_map.csv')
fpairs<-file.path(final,'final_pair_decisions.csv')
required<-c(pmap,ppairs,fmap,fpairs,canonical,cm_path,pointer,scored_path,affected_map,changes,affected_works,file.path(prev,'canonical','records.jsonl'))
if(any(!file.exists(required))||!dir.exists(seed))stop('Missing authoritative inputs')
ptr<-fromJSON(pointer,simplifyVector=FALSE)
if(!identical(ptr$status,'published')||!ptr$state%in%c('final','delta'))stop('Prior state not published')
cm<-fromJSON(cm_path,simplifyVector=FALSE)
sha<-function(p)digest(file=p,algo='sha256',serialize=FALSE)
lines<-function(p){x<-if(file.exists(p))readLines(p,warn=FALSE,encoding='UTF-8')else character();x[nzchar(trimws(x))]}
wlines<-function(x,p){dir.create(dirname(p),recursive=TRUE,showWarnings=FALSE);if(length(x))writeLines(x,p,useBytes=TRUE)else file.create(p)}
thash<-function(dt,key,exclude=character()){
 x<-copy(dt);setorderv(x,key);cols<-sort(setdiff(names(x),exclude))
 z<-lapply(x[,..cols],function(v){w<-as.character(v);w[is.na(w)]<-'<NA>';w})
 rows<-if(nrow(x))do.call(paste,c(z,sep='\u001f'))else character()
 digest(paste(c(paste(cols,collapse='\u001f'),rows),collapse='\n'),algo='sha256',serialize=FALSE)
}
# Read complete current tables only for end-state hash verification, not to rediscover changes.
pairs<-fread(fpairs,na.strings=c('','NA'),colClasses='character')
map<-fread(fmap,na.strings=c('','NA'),colClasses='character')
if(anyDuplicated(pairs$pair_key)||anyDuplicated(map[,.(source,source_record_id)]))stop('Duplicate final identity')
scored<-fread(scored_path)
if(!all(c('record_i','record_j')%in%names(scored)))stop('Missing incremental pair identities')
if(anyNA(scored$record_i)||anyNA(scored$record_j)||
 !all(grepl('^[1-9][0-9]*$',as.character(scored$record_i)))||
 !all(grepl('^[1-9][0-9]*$',as.character(scored$record_j)))||
 any(as.character(scored$record_i)==as.character(scored$record_j)))
 stop('Invalid incremental pair indices')
keys<-paste(pmin(scored$record_i,scored$record_j),pmax(scored$record_i,scored$record_j),sep='::')
oldkeys<-fread(ppairs,select='pair_key',colClasses='character')$pair_key
if(anyNA(keys)||anyDuplicated(keys)||anyDuplicated(oldkeys)||any(keys%in%oldkeys))stop('Historic pair overlap or invalid incremental pairs')
setkey(pairs,pair_key)
up<-pairs[J(keys)]
if(nrow(up)!=length(keys)||anyNA(up$pair_key))stop('New pair absent from final ledger')
af<-fread(affected_map,colClasses='character')
if(!all(c('source','source_record_id')%in%names(af))||anyDuplicated(af[,.(source,source_record_id)]))stop('Invalid affected map')
oldmap<-fread(pmap,select=c('source','source_record_id'),colClasses='character')
if(anyDuplicated(oldmap))stop('Invalid historical manifestation identity')
oldid<-paste(oldmap$source,oldmap$source_record_id,sep='\u001f')
if(anyNA(oldmap$source)||anyNA(oldmap$source_record_id)||
 any(!nzchar(oldmap$source))||any(!nzchar(oldmap$source_record_id)))
 stop('Invalid historical manifestation identity')
currentid<-paste(map$source,map$source_record_id,sep='\u001f')
if(anyNA(map$source)||anyNA(map$source_record_id)||
 any(!nzchar(map$source))||any(!nzchar(map$source_record_id))||
 any(!oldid%in%currentid))stop('Historical manifestation disappeared or invalid final identity')
setkeyv(map,c('source','source_record_id'))
mu<-map[af,on=.(source,source_record_id),nomatch=0L][,names(map),with=FALSE]
if(nrow(mu)!=nrow(af))stop('Affected identity missing')
fresh<-map[!paste(source,source_record_id,sep='\u001f')%in%oldid]
mu<-unique(rbindlist(list(mu,fresh),fill=TRUE),by=c('source','source_record_id'))
# A direct delta must cover every changed historic cluster assignment as well as new rows.
prior_map_full<-fread(pmap,na.strings=c('','NA'),colClasses='character')
# Numeric indices are only safe when each historical stable identity retains its index.
if('idx'%in%names(prior_map_full)&&'idx'%in%names(map)){
 if(anyNA(map$idx)||anyDuplicated(map$idx)||any(!nzchar(map$idx)))
  stop('Invalid final manifestation indices')
 old_indices<-prior_map_full[,.(source,source_record_id,previous_idx=idx)]
 mapped_indices<-map[old_indices,on=.(source,source_record_id),nomatch=0L]
 if(nrow(mapped_indices)!=nrow(prior_map_full)||
  any(as.character(mapped_indices$idx)!=as.character(mapped_indices$previous_idx)))
  stop('Historical manifestation indices were reassigned')
}
setkeyv(prior_map_full,c('source','source_record_id'))
common<-map[prior_map_full,on=.(source,source_record_id),nomatch=0L][,names(map),with=FALSE]
prior_for_current<-prior_map_full[common,on=.(source,source_record_id)]
changed_cols<-intersect(names(prior_map_full),names(map))
changed_cols<-setdiff(changed_cols,c('source','source_record_id'))
diff<-rep(FALSE,nrow(common))
for(col in changed_cols){
 x<-as.character(common[[col]]);y<-as.character(prior_for_current[[col]])
 diff<-diff | (is.na(x)!=is.na(y)) | (!is.na(x)&!is.na(y)&x!=y)
}
changed_historic<-common[diff]
included<-paste(mu$source,mu$source_record_id,sep='\u001f')
required_changed<-paste(changed_historic$source,changed_historic$source_record_id,sep='\u001f')
if(any(!required_changed%in%included))stop('Affected map omitted changed historical cluster assignments')
# Canonical-only repairs require a canonical upsert, not a redundant unchanged map upsert.
# Preserve every new manifestation and every genuinely changed historic map row.
new_ids<-paste(fresh$source,fresh$source_record_id,sep='\u001f')
upsert_ids<-unique(c(required_changed,new_ids))
mu<-mu[paste(source,source_record_id,sep='\u001f')%in%upsert_ids]

setcolorder(mu,names(map))
if('idx'%in%names(mu))setorder(mu,idx)
# New and affected rows must be all that the replay changes.
recordid<-function(x)as.character(fromJSON(x,simplifyVector=FALSE)$identity$record_id)
oldcanonical<-lines(file.path(prev,'canonical','records.jsonl'))
curcanonical<-lines(canonical);changed<-lines(changes)
oldids<-vapply(oldcanonical,recordid,character(1));ids<-vapply(curcanonical,recordid,character(1))
uids<-if(length(changed))vapply(changed,recordid,character(1))else character()
if(anyDuplicated(oldids)||anyDuplicated(ids)||anyDuplicated(uids))stop('Duplicate canonical ID')
works<-fread(affected_works,colClasses='character')
if(!all(c('stage','cluster_id')%in%names(works)))stop('Invalid affected works manifest')
if(!setequal(uids,works[stage=='successor',cluster_id]))stop('Changed canonical works incomplete')
o<-order(uids);uids<-uids[o];changed<-changed[o]
if(!identical(unname(changed),unname(curcanonical[match(uids,ids)])))stop('Canonical changes do not match current state')
retired<-sort(setdiff(oldids,ids))
dir.create(out,recursive=TRUE);dir.create(file.path(out,'source_manifestations'))
pattern<-'_records_for_deduplication\\.jsonl$'
cur<-list.files(seed,pattern=pattern,full.names=TRUE);names(cur)<-sub(pattern,'',basename(cur))
base<-file.path(prev,'workflow01_seed')
prior<-if(dir.exists(base))list.files(base,pattern=pattern,full.names=TRUE)else character()
names(prior)<-sub(pattern,'',basename(prior))
if(!length(cur)||length(setdiff(names(prior),names(cur))))stop('Previous source dropped')
counts<-list();targets<-list()
for(src in sort(names(cur))){
 b<-if(src%in%names(prior))lines(prior[[src]])else character();z<-lines(cur[[src]])
 if(length(b)>length(z)||!identical(b,head(z,length(b))))stop('Source prefix changed: ',src)
 delta<-if(length(z)>length(b))tail(z,length(z)-length(b))else character()
 dest<-file.path(out,'source_manifestations',paste0(src,'_new.jsonl'));wlines(delta,dest)
 counts[[src]]<-length(delta)
 targets[[src]]<-list(filename=basename(cur[[src]]),previous_records=length(b),current_records=length(z),
  added_records=length(delta),current_sha256=sha(cur[[src]]),delta_sha256=sha(dest))
}
fwrite(up,file.path(out,'pair_decision_upserts.csv'),na='')
fwrite(mu,file.path(out,'cluster_map_upserts.csv'),na='')
aliases<-file.path(final,'cluster_id_aliases.csv')
if(file.exists(aliases))file.copy(aliases,file.path(out,'cluster_id_aliases.csv'))else
 fwrite(data.table(retired_cluster_id=character(),surviving_cluster_id=character(),reason=character()),file.path(out,'cluster_id_aliases.csv'))
wlines(changed,file.path(out,'canonical_upserts.jsonl'))
wlines(retired,file.path(out,'canonical_retired_ids.txt'))
if(!file.copy(file.path(final,'summary.json'),file.path(out,'target_summary.json'))||
 !file.copy(cm_path,file.path(out,'target_canonical_manifest.json')))stop('Cannot stage target contract')
# Provenance upserts use the exact identity keys implemented by production replay.
# Preserve existing bytes and reject deletions or modified historical approvals.
key_repair<-function(line){
 z<-fromJSON(line,simplifyVector=FALSE)
 paste(as.character(if(is.null(z$review_case_id))'' else z$review_case_id),
  as.character(z$source),as.character(z$source_record_id),as.character(z$action),sep='|')
}
key_strip<-function(line){
 z<-fromJSON(line,simplifyVector=FALSE)
 paste(as.character(z$source),as.character(z$source_record_id),sep='::')
}
stage_provenance<-function(old_path,current_path,filename,key_fun){
 historical<-lines(old_path);current<-lines(current_path)
 hk<-if(length(historical))vapply(historical,key_fun,character(1))else character()
 ck<-if(length(current))vapply(current,key_fun,character(1))else character()
 if(anyNA(hk)||anyNA(ck)||anyDuplicated(hk)||anyDuplicated(ck)||
  any(!nzchar(hk))||any(!nzchar(ck)))stop('Invalid or duplicate provenance identity: ',filename)
 if(any(!hk%in%ck))stop('Historical provenance entry disappeared: ',filename)
 hm<-setNames(historical,hk);cm<-setNames(current,ck)
 if(any(unname(hm[hk])!=unname(cm[hk])))stop('Historical provenance entry was altered: ',filename)
 added<-sort(setdiff(ck,hk))
 wlines(unname(cm[added]),file.path(out,filename))
 length(added)
}
repair_n<-stage_provenance(file.path(prev,'provenance','cumulative_data_quality_repairs.jsonl'),
 file.path(final,'cumulative_data_quality_repairs.jsonl'),'data_quality_repair_upserts.jsonl',key_repair)
strip_n<-stage_provenance(file.path(prev,'workflow01_full_five_source','abstract_strip_actions.jsonl'),
 file.path(final,'abstract_strip_actions.jsonl'),'abstract_strip_action_upserts.jsonl',key_strip)
audit<-file.path(final,'data_quality_repair_application.jsonl')
if(file.exists(audit))file.copy(audit,file.path(out,'data_quality_repair_application.jsonl'))
delta<-list(schema='living-evidence-map-workflow01-delta-v1',workflow='01',state='delta',github_run_id=rid,
 previous=list(github_run_id=as.character(ptr$github_run_id),zenodo_record_id=as.character(ptr$zenodo_record_id),doi=as.character(ptr$doi),manifest_sha256=as.character(ptr$manifest_sha256)),
 target=list(source_manifestations=as.integer(cm$source_manifestations),canonical_records=as.integer(cm$records),
 canonical_jsonl_sha256=as.character(cm$canonical_jsonl_sha256),canonical_jsonl_bytes=as.numeric(cm$canonical_jsonl_bytes),
 pair_decisions_state_sha256=thash(pairs,'pair_key',c('title_i','title_j')),
 cluster_map_state_sha256=thash(map,c('source','source_record_id')),
 pair_decisions_hash_excluded_descriptive_columns=c('title_i','title_j'),source_files=targets),
 delta=list(new_source_manifestations=sum(unlist(counts)),new_source_manifestations_by_source=counts,
 pair_decision_upserts=nrow(up),new_pair_decisions=nrow(up),changed_pair_decisions=0L,
 cluster_map_upserts=nrow(mu),new_manifestations=nrow(fresh),
 changed_existing_manifestations=nrow(mu)-nrow(fresh),
 canonical_upserts=length(changed),canonical_retired_ids=length(retired),
 data_quality_repair_upserts=repair_n,abstract_strip_action_upserts=strip_n),
 files=list(pair_decision_upserts_sha256=sha(file.path(out,'pair_decision_upserts.csv')),
 cluster_map_upserts_sha256=sha(file.path(out,'cluster_map_upserts.csv')),
 cluster_id_aliases_sha256=sha(file.path(out,'cluster_id_aliases.csv')),
 canonical_upserts_sha256=sha(file.path(out,'canonical_upserts.jsonl')),
 canonical_retired_ids_sha256=sha(file.path(out,'canonical_retired_ids.txt')),
 data_quality_repair_upserts_sha256=sha(file.path(out,'data_quality_repair_upserts.jsonl')),
 abstract_strip_action_upserts_sha256=sha(file.path(out,'abstract_strip_action_upserts.jsonl'))),
 created_at_utc=format(Sys.time(),tz='UTC',format='%Y-%m-%dT%H:%M:%SZ'))
writeLines(toJSON(delta,auto_unbox=TRUE,pretty=TRUE,null='null',na='null'),file.path(out,'delta_manifest.json'))
cat('PASS: experimental direct W01 delta staged without publication\n')
