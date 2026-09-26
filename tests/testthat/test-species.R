testthat::test_that("named species beats overlapping generic salmon terms", {
  dictionary <- data.frame(
    species_id = c("SAL_SALAR", "UNSPEC_SALMON", "UNSPEC_SALMON"),
    preferred_name = c("Atlantic salmon", "Unspecified species", "Unspecified species"),
    scientific_name = c("Salmo salar", NA, NA),
    synonym = c("Atlantic salmon", "salmon", "salmon aquaculture"),
    synonym_type = c("common", "generic", "generic"),
    is_farmed_candidate = c(TRUE, TRUE, TRUE),
    default_group = c("salmon", "salmon", "salmon"),
    stringsAsFactors = FALSE
  )
  hits <- detect_species_mentions("Atlantic salmon aquaculture", "", dictionary)
  testthat::expect_true(any(hits$species_id == "SAL_SALAR"))
  testthat::expect_false(any(hits$species_id == "UNSPEC_SALMON"))
})

testthat::test_that("short named species survives longer overlapping generic phrase", {
  dictionary <- data.frame(
    species_id = c("ONC_KISUTCH", "UNSPEC_SALMON"),
    preferred_name = c("Coho salmon", "Unspecified species"),
    scientific_name = c("Oncorhynchus kisutch", NA),
    synonym = c("Coho salmon", "salmon aquaculture"),
    synonym_type = c("common", "generic"),
    is_farmed_candidate = c(TRUE, TRUE),
    default_group = c("salmon", "salmon"),
    stringsAsFactors = FALSE
  )
  hits <- detect_species_mentions("Coho salmon aquaculture in Japan", "", dictionary)
  testthat::expect_true(any(hits$species_id == "ONC_KISUTCH"))
  testthat::expect_false(any(hits$species_id == "UNSPEC_SALMON"))
})

testthat::test_that("hyphenated species names and scientific names are detected", {
  dictionary <- data.frame(
    species_id = c("ONC_MYKISS", "ONC_MYKISS"),
    preferred_name = c("Rainbow trout", "Rainbow trout"),
    scientific_name = c("Oncorhynchus mykiss", "Oncorhynchus mykiss"),
    synonym = c("Rainbow trout", "Salmo gairdneri"),
    synonym_type = c("common", "scientific"),
    is_farmed_candidate = c(TRUE, TRUE),
    default_group = c("trout", "trout"),
    stringsAsFactors = FALSE
  )
  hits <- detect_species_mentions("RAINBOW-TROUT (SALMO-GAIRDNERI)", "", dictionary)
  testthat::expect_true(any(tolower(hits$matched_term) == "rainbow-trout"))
  testthat::expect_true(any(tolower(hits$matched_term) == "salmo-gairdneri"))
})

testthat::test_that("scientific abbreviations tolerate omitted full stop", {
  dictionary <- data.frame(
    species_id = c("SAL_SALAR", "ONC_MYKISS"),
    preferred_name = c("Atlantic salmon", "Rainbow trout"),
    scientific_name = c("Salmo salar", "Oncorhynchus mykiss"),
    synonym = c("S. salar", "O. mykiss"),
    synonym_type = c("abbreviation", "abbreviation"),
    is_farmed_candidate = c(TRUE, TRUE),
    default_group = c("salmon", "trout"),
    stringsAsFactors = FALSE
  )
  hits <- detect_species_mentions("", "S salar and O mykiss were examined.", dictionary)
  testthat::expect_setequal(hits$species_id, c("SAL_SALAR", "ONC_MYKISS"))
})

testthat::test_that("specific farmed salmon suppresses generic assignment", {
  mentions <- data.frame(
    species_id = c("UNSPEC_SALMON", "ATL_SALMO"),
    preferred_name = c("Unspecified farmed salmon", "Atlantic salmon"),
    scientific_name = c(NA, "Salmo salar"),
    matched_term = c("salmon", "Atlantic salmon"),
    synonym_type = c("generic", "common"), source = c("abstract", "abstract"),
    match_start = c(1L, 20L), match_end = c(6L, 34L),
    is_farmed_candidate = c(TRUE, TRUE), default_group = c("farmed_salmon", "farmed_salmon"),
    stringsAsFactors = FALSE
  )
  result <- assign_farmed_species(mentions)
  testthat::expect_equal(result$farmed_species, "Atlantic salmon")
  testthat::expect_equal(nrow(result), 1L)
})

testthat::test_that("target validation rejects duplicated identifiers", {
  records <- data.frame(record_sequence = c(1L, 2L), record_id = c("A", "A"), title = c("a", "b"), abstract = c("a", "b"))
  testthat::expect_error(validate_target_records(records, "TEST"), "record_id")
})


testthat::test_that("HTML and JATS markup are stripped before matching", {
  dictionary <- data.frame(
    species_id = c("SAL_SALAR", "ONC_MYKISS"),
    preferred_name = c("Atlantic salmon", "Rainbow trout"),
    scientific_name = c("Salmo salar", "Oncorhynchus mykiss"),
    synonym = c("Salmo salar", "Oncorhynchus mykiss"),
    synonym_type = c("scientific", "scientific"),
    is_farmed_candidate = c(TRUE, TRUE),
    default_group = c("salmon", "trout"),
    stringsAsFactors = FALSE
  )
  hits <- detect_species_mentions(
    "<jats:italic>Salmo</jats:italic> <italic>salar</italic>",
    "&lt;i&gt;Oncorhynchus&lt;/i&gt;&lt;i&gt; mykiss&lt;/i&gt;",
    dictionary
  )
  testthat::expect_setequal(hits$species_id, c("SAL_SALAR", "ONC_MYKISS"))
})

testthat::test_that("OCR spacing inside scientific names is tolerated", {
  dictionary <- data.frame(
    species_id = c("SAL_SALAR", "ONC_MYKISS"),
    preferred_name = c("Atlantic salmon", "Rainbow trout"),
    scientific_name = c("Salmo salar", "Oncorhynchus mykiss"),
    synonym = c("Salmo salar", "Oncorhynchus mykiss"),
    synonym_type = c("scientific", "scientific"),
    is_farmed_candidate = c(TRUE, TRUE),
    default_group = c("salmon", "trout"),
    stringsAsFactors = FALSE
  )
  hits <- detect_species_mentions("S almo salar", "O ncorhynchus mykiss", dictionary)
  testthat::expect_setequal(hits$species_id, c("SAL_SALAR", "ONC_MYKISS"))
})

testthat::test_that("English common-name pluralisations are detected", {
  dictionary <- data.frame(
    species_id = c("ONC_MYKISS", "UNSPEC_SALMON"),
    preferred_name = c("Rainbow trout", "Unspecified species"),
    scientific_name = c("Oncorhynchus mykiss", NA),
    synonym = c("Rainbow trout", "Salmon"),
    synonym_type = c("common", "generic"),
    is_farmed_candidate = c(TRUE, TRUE),
    default_group = c("trout", "salmon"),
    stringsAsFactors = FALSE
  )
  hits <- detect_species_mentions("Rainbow trouts were compared with salmons.", "", dictionary)
  testthat::expect_setequal(hits$species_id, c("ONC_MYKISS", "UNSPEC_SALMON"))
})

testthat::test_that("generic trout and salmonid remain ignored", {
  dictionary <- data.frame(
    species_id = c("ONC_MYKISS", "UNSPEC_SALMON"),
    preferred_name = c("Rainbow trout", "Unspecified species"),
    scientific_name = c("Oncorhynchus mykiss", NA),
    synonym = c("Rainbow trout", "Salmon"),
    synonym_type = c("common", "generic"),
    is_farmed_candidate = c(TRUE, TRUE),
    default_group = c("trout", "salmon"),
    stringsAsFactors = FALSE
  )
  hits <- detect_species_mentions("Farmed trout and salmonids were studied.", "", dictionary)
  testthat::expect_equal(nrow(hits), 0L)
})

testthat::test_that("salmon in salmon louse or lice context remains eligible", {
  dictionary <- data.frame(
    species_id = "UNSPEC_SALMON",
    preferred_name = "Unspecified species",
    scientific_name = NA,
    synonym = "Salmon",
    synonym_type = "generic",
    is_farmed_candidate = TRUE,
    default_group = "salmon",
    stringsAsFactors = FALSE
  )
  hits <- detect_species_mentions("Salmon lice burden", "salmon louse infection", dictionary)
  testthat::expect_true(nrow(hits) >= 2L)
  testthat::expect_true(all(hits$species_id == "UNSPEC_SALMON"))
})


testthat::test_that("absence of an eligible species term is NONE rather than review", {
  mentions <- data.frame(
    species_id = character(),
    preferred_name = character(),
    scientific_name = character(),
    matched_term = character(),
    synonym_type = character(),
    source = character(),
    match_start = integer(),
    match_end = integer(),
    is_farmed_candidate = logical(),
    default_group = character(),
    stringsAsFactors = FALSE
  )
  result <- assign_farmed_species(mentions)
  testthat::expect_false(result$review_required)
  testthat::expect_equal(result$assignment_role, "none")
  testthat::expect_true(is.na(result$farmed_species_id))
})

testthat::test_that("generic trout and salmonid-only records remain NONE", {
  dictionary <- data.frame(
    species_id = c("ONC_MYKISS", "UNSPEC_SALMON"),
    preferred_name = c("Rainbow trout", "Unspecified species"),
    scientific_name = c("Oncorhynchus mykiss", NA),
    synonym = c("Rainbow trout", "Salmon"),
    synonym_type = c("common", "generic"),
    is_farmed_candidate = c(TRUE, TRUE),
    default_group = c("trout", "salmon"),
    stringsAsFactors = FALSE
  )
  hits <- detect_species_mentions("Farmed trout and salmonids were studied.", "", dictionary)
  result <- assign_farmed_species(hits)
  testthat::expect_false(result$review_required)
  testthat::expect_equal(result$assignment_role, "none")
})
