source("R/publication_status.R")
library(dplyr)
library(readr)
library(lubridate)
corpus_file <- here::here("data", "master", "current", "living_evidence_map_master.csv")
cache_file <- here::here("data", "reference", "openalex_retraction_status.csv")
api_key <- Sys.getenv("OPENALEX_API_KEY")
if (!nzchar(api_key)) stop("OPENALEX_API_KEY was not found.")
corpus <- readr::read_csv(corpus_file, show_col_types = FALSE, progress = FALSE)
doi_col <- if ("doi_key" %in% names(corpus)) "doi_key" else "doi"
corpus_dois <- corpus |>
  transmute(record_id = as.character(record_id), doi_for_lookup = normalise_doi_for_openalex(.data[[doi_col]])) |>
  filter(nzchar(doi_for_lookup)) |>
  distinct(doi_for_lookup, .keep_all = TRUE)
if (file.exists(cache_file)) {
  cache <- readr::read_csv(cache_file, show_col_types = FALSE) |>
    mutate(last_checked_at = as.POSIXct(last_checked_at, tz = "UTC"), next_check_at = as.POSIXct(next_check_at, tz = "UTC"))
} else {
  cache <- tibble::tibble(doi_for_lookup=character(), openalex_id=character(), openalex_title=character(), openalex_is_retracted=logical(), openalex_lookup_status=character(), openalex_error=character(), last_checked_at=as.POSIXct(character(),tz="UTC"), next_check_at=as.POSIXct(character(),tz="UTC"))
}
old_retracted <- cache |> filter(openalex_is_retracted %in% TRUE) |> pull(doi_for_lookup)
now <- Sys.time()
limit <- nrow(corpus_dois)
due <- corpus_dois |> left_join(cache |> select(doi_for_lookup,next_check_at,openalex_is_retracted),by="doi_for_lookup") |> filter(!coalesce(openalex_is_retracted,FALSE)) |> arrange(is.na(next_check_at),next_check_at) |> slice_head(n=limit)
message(sprintf("Retraction sweep: %d corpus DOIs; checking %d.",nrow(corpus_dois),nrow(due)))
if(nrow(due)){
  r <- lookup_openalex_dois(due$doi_for_lookup,api_key=api_key,batch_size=50L) |> mutate(last_checked_at=now)
  r <- r |> mutate(next_check_at=case_when(openalex_is_retracted~as.POSIXct(NA,tz="UTC"),openalex_lookup_status=="failed"~now+days(1),TRUE~now+days(90))) |> select(doi_for_lookup,openalex_id,openalex_title,openalex_is_retracted,openalex_lookup_status,openalex_error,last_checked_at,next_check_at)
  cache <- cache |> filter(!doi_for_lookup %in% due$doi_for_lookup) |> bind_rows(r)
}
cache <- cache |> semi_join(corpus_dois,by="doi_for_lookup") |> arrange(doi_for_lookup)
current <- cache |> filter(openalex_is_retracted %in% TRUE) |> inner_join(corpus_dois,by="doi_for_lookup")
new <- current |> filter(!doi_for_lookup %in% old_retracted) |> mutate(detected_at=format(now,tz="UTC",usetz=TRUE))
readr::write_csv(cache,cache_file,na="")
readr::write_csv(new,here::here("data","reference","new_retractions_detected.csv"),na="")
readr::write_csv(tibble::tibble(swept_at=format(now,tz="UTC",usetz=TRUE),corpus_dois=nrow(corpus_dois),checked_dois=nrow(due),currently_retracted=nrow(current),newly_detected_retractions=nrow(new)),here::here("data","reference","retraction_sweep_audit.csv"),na="")
message(sprintf("Retraction sweep complete: %d currently retracted; %d newly detected.",nrow(current),nrow(new)))
