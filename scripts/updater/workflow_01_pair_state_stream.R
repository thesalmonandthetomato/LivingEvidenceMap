# Bounded-memory, full-fidelity W01 CSV pair-state transformations.
# Pair rows may contain quoted multiline abstracts; use readr's streaming CSV
# parser rather than readLines, shell cut, or a 17 GiB fread memory map.
# Persist every original field. Keep only pair IDs and per-row SHA-256 in RAM.
suppressPackageStartupMessages({
  library(data.table)
  library(digest)
})
if(!requireNamespace("readr",quietly=TRUE))
  stop("readr is required for W01 streaming pair operations",call.=FALSE)

w01_pair_columns <- function(path) {
  if(!file.exists(path)) stop(sprintf("Missing W01 pair CSV: %s",path),call.=FALSE)
  names(readr::read_csv(path,n_max=0L,col_types=readr::cols(.default=readr::col_character()),
                        show_col_types=FALSE,progress=FALSE))
}
w01_pair_stream <- function(path,callback,chunk_size=3000L) {
  readr::read_csv_chunked(
    path,callback=readr::DataFrameCallback$new(function(x,pos) {
      if(nrow(x)) callback(as.data.table(x))
      invisible(NULL)
    }),
    chunk_size=chunk_size,
    col_types=readr::cols(.default=readr::col_character()),
    na=c("","NA"),show_col_types=FALSE,progress=FALSE
  )
  invisible(NULL)
}
w01_pair_align <- function(dt,cols) {
  for(nm in setdiff(cols,names(dt))) dt[, (nm):=NA_character_]
  setcolorder(dt,cols)
  dt
}
w01_pair_rowhashes <- function(dt,cols) {
  if(!nrow(dt)) return(character())
  vals <- lapply(dt[,..cols],function(v){
    z <- as.character(v); z[is.na(z)] <- "<NA>"; z
  })
  vapply(seq_len(nrow(dt)),function(i)
    digest(paste(vapply(vals,function(v)v[[i]],character(1)),collapse="\\u001f"),
           algo="sha256",serialize=FALSE),character(1))
}
w01_pair_fingerprint <- function(keys,hashes,cols) {
  if(length(keys)!=length(hashes) || anyNA(keys) || anyDuplicated(keys))
    stop("Cannot fingerprint duplicate, missing or mismatched W01 pair keys",call.=FALSE)
  ord <- order(keys,method="radix")
  lines <- paste(keys[ord],hashes[ord],sep="\\u001f")
  digest(paste(c(paste(sort(cols),collapse="\\u001f"),lines),collapse="\\n"),
         algo="sha256",serialize=FALSE)
}
w01_pair_collect <- function(path,cols) {
  keys <- list(); hashes <- list()
  w01_pair_stream(path,function(dt){
    dt <- w01_pair_align(dt,cols)
    if(!"pair_key" %in% names(dt)) stop("W01 pair state lacks pair_key",call.=FALSE)
    if(anyNA(dt$pair_key)) stop("W01 pair keys contain NA",call.=FALSE)
    keys[[length(keys)+1L]] <<- as.character(dt$pair_key)
    hashes[[length(hashes)+1L]] <<- w01_pair_rowhashes(dt,cols)
  })
  list(keys=unlist(keys,use.names=FALSE),hashes=unlist(hashes,use.names=FALSE))
}
w01_pair_diff <- function(previous_path,current_path,upsert_path) {
  cols <- union(w01_pair_columns(previous_path),w01_pair_columns(current_path))
  if(!"pair_key" %in% cols) stop("W01 pair state lacks pair_key",call.=FALSE)
  previous <- w01_pair_collect(previous_path,cols)
  if(anyDuplicated(previous$keys)) stop("Duplicate historical W01 pair keys",call.=FALSE)
  lookup <- data.table(pair_key=previous$keys,signature=previous$hashes)
  setkey(lookup,pair_key)
  keys <- list(); hashes <- list()
  n_new <- 0L; n_changed <- 0L; n_up <- 0L; written <- FALSE
  if(file.exists(upsert_path)) unlink(upsert_path)
  w01_pair_stream(current_path,function(dt){
    dt <- w01_pair_align(dt,cols)
    key <- as.character(dt$pair_key)
    sig <- w01_pair_rowhashes(dt,cols)
    keys[[length(keys)+1L]] <<- key
    hashes[[length(hashes)+1L]] <<- sig
    prior <- lookup[.(key),on="pair_key",signature]
    fresh <- is.na(prior)
    changed <- !fresh & prior != sig
    update <- fresh | changed
    n_new <<- n_new+sum(fresh)
    n_changed <<- n_changed+sum(changed)
    n_up <<- n_up+sum(update)
    if(any(update)){
      fwrite(dt[update],upsert_path,append=written,col.names=!written,na="")
      written <<- TRUE
    }
  })
  if(!written) {
    # Retain the full original schema even for a zero-row delta.
    zero <- as.data.table(setNames(rep(list(character()),length(cols)),cols))
    fwrite(zero,upsert_path,na="")
  }
  current_keys <- unlist(keys,use.names=FALSE)
  current_hashes <- unlist(hashes,use.names=FALSE)
  if(anyDuplicated(current_keys)) stop("Duplicate current W01 pair keys",call.=FALSE)
  missing <- setdiff(previous$keys,current_keys)
  if(length(missing)) stop(sprintf("%d previous pair decisions disappeared",length(missing)),call.=FALSE)
  state_sha <- w01_pair_fingerprint(current_keys,current_hashes,cols)
  cat(sprintf("PASS: streaming W01 pair delta: %d current, %d new, %d changed, %d upserts\\n",
              length(current_keys),n_new,n_changed,n_up))
  list(new=n_new,changed=n_changed,upserts=n_up,state_sha256=state_sha,
       hash_method="row_sha256_sorted_v2")
}
w01_pair_replay <- function(previous_path,upsert_path,output_path,expected_sha) {
  cols <- union(w01_pair_columns(previous_path),w01_pair_columns(upsert_path))
  ups <- w01_pair_collect(upsert_path,cols)
  if(anyDuplicated(ups$keys)) stop("W01 pair upserts contain duplicate keys",call.=FALSE)
  # Only the upsert keys need to be resident to stream out unchanged history.
  up_set <- new.env(hash=TRUE,parent=emptyenv())
  for(k in ups$keys) assign(k,TRUE,envir=up_set)
  if(file.exists(output_path)) unlink(output_path)
  written <- FALSE; previous_seen <- list()
  w01_pair_stream(previous_path,function(dt){
    dt <- w01_pair_align(dt,cols)
    key <- as.character(dt$pair_key)
    previous_seen[[length(previous_seen)+1L]] <<- key
    keep <- !vapply(key,exists,logical(1),envir=up_set,inherits=FALSE)
    if(any(keep)){
      fwrite(dt[keep],output_path,append=written,col.names=!written,na="")
      written <<- TRUE
    }
  })
  prev_keys <- unlist(previous_seen,use.names=FALSE)
  if(anyDuplicated(prev_keys)) stop("Previous W01 pair keys are not unique",call.=FALSE)
  w01_pair_stream(upsert_path,function(dt){
    dt <- w01_pair_align(dt,cols)
    fwrite(dt,output_path,append=written,col.names=!written,na="")
    written <<- TRUE
  })
  if(!written) stop("W01 pair replay generated no rows",call.=FALSE)
  result <- w01_pair_collect(output_path,cols)
  actual <- w01_pair_fingerprint(result$keys,result$hashes,cols)
  if(!identical(tolower(actual),tolower(as.character(expected_sha))))
    stop(sprintf("Replayed W01 pair state hash mismatch: expected=%s actual=%s",
                 expected_sha,actual),call.=FALSE)
  cat(sprintf("PASS: replayed %d W01 pair rows with bounded memory and verified row SHA-256 state\\n",
              length(result$keys)))
  invisible(actual)
}
