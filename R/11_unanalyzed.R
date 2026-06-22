# ===========================================================================
# 11_unanalyzed.R  --  "not yet analyzed" HUC10 layer (request-outputs UI)
#
# Fetches every HUC10 touching the western states from the national WBD REST
# service (server-side generalized via maxAllowableOffset, paginated), drops the
# analyzed watersheds, and tiles the remainder to PMTiles. On the map, clicking
# one of these watersheds opens a mailto link to request its outputs.
#
# Output: site/data/huc10_unanalyzed.pmtiles (committed); the merged GeoJSON is
# a gitignored intermediate.
# ===========================================================================

# Page through the WBD HUC10 layer for all HUC10s touching `states`. Geometry is
# generalized server-side (maxAllowableOffset) so the payload stays small.
.fetch_wbd_states <- function(states, offset) {
  suppressPackageStartupMessages(library(sf))
  # Explicit percent-encoding: URLencode mis-handles the LIKE '%XX%' wildcards
  # (it reads '%CA' as an already-encoded byte). Encode '%' FIRST, then quotes
  # and spaces, so the wildcards survive as %25 for the server.
  enc <- function(s) {
    s <- gsub("%", "%25", s, fixed = TRUE)
    s <- gsub("'", "%27", s, fixed = TRUE)
    gsub(" ", "%20", s, fixed = TRUE)
  }
  where <- enc(paste(sprintf("states LIKE '%%%s%%'", states), collapse = " OR "))
  page <- 2000L; start <- 0L; got <- list()
  repeat {
    url <- sprintf(paste0("%s?where=%s&outFields=huc10,name&returnGeometry=true",
                          "&maxAllowableOffset=%s&outSR=4326&resultOffset=%d",
                          "&resultRecordCount=%d&f=geojson"),
                   WBD_HUC10_QUERY, where, format(offset, scientific = FALSE), start, page)
    tmp <- tempfile(fileext = ".geojson")
    ok <- tryCatch({ utils::download.file(url, tmp, quiet = TRUE, mode = "wb"); TRUE },
                   error = function(e) { cat("  fetch failed at offset", start, ":", conditionMessage(e), "\n"); FALSE })
    x <- if (ok) tryCatch(st_read(tmp, quiet = TRUE), error = function(e) NULL) else NULL
    unlink(tmp)
    n <- if (is.null(x)) 0L else nrow(x)
    cat(sprintf("  page offset %d: %d features\n", start, n))
    if (n) got[[length(got) + 1]] <- x[, intersect(c("huc10", "name"), names(x))]
    if (n < page) break
    start <- start + page
  }
  if (!length(got)) return(NULL)
  out <- do.call(rbind, got)
  out$huc10 <- as.character(out$huc10)
  out[!duplicated(out$huc10), ]
}

.tile_unanalyzed <- function(geojson, pmtiles) {
  if (file.exists(pmtiles)) file.remove(pmtiles)
  sf::gdal_utils("vectortranslate", geojson, pmtiles,
    options = c("-f", "PMTiles", "-nln", "unanalyzed",
                "-dsco", paste0("MINZOOM=", UNANALYZED_MINZOOM),
                "-dsco", paste0("MAXZOOM=", UNANALYZED_MAXZOOM),
                "-dsco", "SIMPLIFICATION=8", "-dsco", "SIMPLIFICATION_MAX_ZOOM=4",
                "-dsco", "MAX_SIZE=500000"))
  cat(sprintf("  tiled -> %s (%s)\n", basename(pmtiles), pretty_size(file.info(pmtiles)$size)))
}

# analyzed_hucs: codes to EXCLUDE (already analyzed). NULL => read from the
# committed boundary GeoJSON.
build_unanalyzed_layer <- function(analyzed_hucs = NULL) {
  banner("11  UNANALYZED (request-outputs layer)")
  ensure_dir(SITE_DATA)
  suppressPackageStartupMessages(library(sf))

  if (is.null(analyzed_hucs)) {
    analyzed_hucs <- if (file.exists(BOUNDARY_GEOJSON))
      as.character(st_read(BOUNDARY_GEOJSON, quiet = TRUE)$huc10) else character(0)
  }
  analyzed_hucs <- unique(as.character(analyzed_hucs))
  cat(sprintf("  analyzed (to exclude): %d\n", length(analyzed_hucs)))

  w <- .fetch_wbd_states(UNANALYZED_STATES, UNANALYZED_OFFSET)
  if (is.null(w) || !nrow(w)) { cat("  no WBD features fetched — skipping\n"); return(invisible(NULL)) }
  cat(sprintf("  fetched: %d HUC10s touching %s\n", nrow(w), paste(UNANALYZED_STATES, collapse = "/")))

  w <- w[!(w$huc10 %in% analyzed_hucs), ]
  w <- st_make_valid(w)
  w <- w[!st_is_empty(w), ]
  cat(sprintf("  unanalyzed (after excluding analyzed): %d\n", nrow(w)))

  if (file.exists(UNANALYZED_GEOJSON)) file.remove(UNANALYZED_GEOJSON)
  st_write(w[, c("huc10", "name")], UNANALYZED_GEOJSON, driver = "GeoJSON", quiet = TRUE,
           layer_options = c("COORDINATE_PRECISION=5", "RFC7946=YES"))
  cat(sprintf("  wrote %s (%s)\n", basename(UNANALYZED_GEOJSON),
              pretty_size(file.info(UNANALYZED_GEOJSON)$size)))
  .tile_unanalyzed(UNANALYZED_GEOJSON, UNANALYZED_PMTILES)
  invisible(UNANALYZED_PMTILES)
}
