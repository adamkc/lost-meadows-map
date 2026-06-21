# ===========================================================================
# 08_boundary.R  --  watershed boundary GeoJSON + HUC10->forest lookup
#
# Primary source: national USGS WBD HUC10 layer (REST), fetched for the exact
# set of published HUC10s so OR/CO/WA outliers are covered uniformly. Offline
# fallback: PredictedWatersheds.shp (211, Sierra-only).
#
# Writes site/data/huc10.geojson (props: huc10, name, areasqkm) and returns a
# lookup data.frame (huc10, name, forest) for the manifest step.
# ===========================================================================

# Fetch HUC10 polygons from the national WBD REST service, in batches.
.fetch_wbd <- function(hucs) {
  suppressPackageStartupMessages(library(sf))
  got <- list()
  batches <- split(hucs, ceiling(seq_along(hucs) / WBD_BATCH))
  for (b in seq_along(batches)) {
    ids   <- paste(sprintf("'%s'", batches[[b]]), collapse = ",")
    where <- utils::URLencode(sprintf("huc10 IN (%s)", ids), reserved = TRUE)
    url   <- sprintf("%s?where=%s&outFields=huc10,name,areasqkm&returnGeometry=true&outSR=4326&f=geojson",
                     WBD_HUC10_QUERY, where)
    tmp <- tempfile(fileext = ".geojson")
    ok <- tryCatch({
      utils::download.file(url, tmp, quiet = TRUE, mode = "wb"); TRUE
    }, error = function(e) { cat("  WBD batch", b, "download failed:", conditionMessage(e), "\n"); FALSE })
    if (ok) {
      x <- tryCatch(st_read(tmp, quiet = TRUE), error = function(e) NULL)
      if (!is.null(x) && nrow(x)) got[[length(got) + 1]] <- x[, c("huc10", "name", "areasqkm")]
    }
    unlink(tmp)
    cat(sprintf("  WBD batch %d/%d: %d/%d requested\n", b, length(batches),
                if (ok && !is.null(x)) nrow(x) else 0L, length(batches[[b]])))
  }
  if (!length(got)) return(NULL)
  do.call(rbind, got)
}

# Offline fallback from the Sierra-only PredictedWatersheds shapefile.
.fallback_shp <- function(hucs) {
  if (!file.exists(PREDICTED_WATERSHEDS_SHP)) return(NULL)
  suppressPackageStartupMessages(library(sf))
  x <- st_read(PREDICTED_WATERSHEDS_SHP, quiet = TRUE)
  names(x) <- tolower(names(x))
  hcol <- intersect(c("huc10", "huc_10", "huc"), names(x))[1]
  if (is.na(hcol)) return(NULL)
  x$huc10 <- as.character(x[[hcol]])
  if (is.na(st_crs(x)$epsg) || st_crs(x)$epsg != 4326) x <- st_transform(x, 4326)
  x <- x[x$huc10 %in% hucs, ]
  ncol_ <- intersect(c("name"), names(x))[1]
  x$name <- if (is.na(ncol_)) NA_character_ else x[[ncol_]]
  acol  <- intersect(c("areasqkm"), names(x))[1]
  x$areasqkm <- if (is.na(acol)) NA_real_ else x[[acol]]
  x[, c("huc10", "name", "areasqkm")]
}

# Assign each watershed to a National Forest by centroid-in-polygon, using the
# USFS national Administrative Forest Boundaries (fetched once for the watershed
# bbox). Best-effort: returns all-NA if the service is unreachable.
.forest_lookup <- function(w) {
  suppressPackageStartupMessages(library(sf))
  na_out <- setNames(rep(NA_character_, nrow(w)), w$huc10)
  bb  <- st_bbox(w)
  env <- utils::URLencode(sprintf("%f,%f,%f,%f", bb["xmin"], bb["ymin"], bb["xmax"], bb["ymax"]),
                          reserved = TRUE)
  url <- sprintf(paste0("%s?where=1%%3D1&geometry=%s&geometryType=esriGeometryEnvelope",
                        "&inSR=4326&outSR=4326&spatialRel=esriSpatialRelIntersects",
                        "&outFields=FORESTNAME&returnGeometry=true&f=geojson"),
                 USFS_FOREST_QUERY, env)
  tmp <- tempfile(fileext = ".geojson")
  ok <- tryCatch({ utils::download.file(url, tmp, quiet = TRUE, mode = "wb"); TRUE },
                 error = function(e) FALSE)
  if (!ok) { cat("  forest lookup: USFS fetch failed — forests left blank\n"); return(na_out) }
  f <- tryCatch(st_make_valid(st_read(tmp, quiet = TRUE)), error = function(e) NULL); unlink(tmp)
  fcol <- if (is.null(f)) NA else names(f)[tolower(names(f)) == "forestname"][1]
  if (is.null(f) || !nrow(f) || is.na(fcol)) return(na_out)
  f <- f[, fcol]; names(f)[1] <- "forest"

  old <- sf::sf_use_s2(); sf::sf_use_s2(FALSE); on.exit(sf::sf_use_s2(old), add = TRUE)
  cen <- st_sf(huc10 = w$huc10, geometry = st_centroid(st_geometry(w)))
  j <- st_join(cen, f, join = st_within)
  j <- j[!duplicated(j$huc10), ]
  res <- setNames(j$forest[match(w$huc10, j$huc10)], w$huc10)
  cat(sprintf("  forest lookup: %d/%d watersheds matched a National Forest\n",
              sum(!is.na(res)), nrow(w)))
  res
}

build_boundary <- function(staged_hucs, core_hucs = character(0)) {
  banner("08  BOUNDARY")
  ensure_dir(SITE_DATA)
  suppressPackageStartupMessages({ library(sf); library(rmapshaper) })
  staged_hucs <- sort(unique(staged_hucs))
  cat(sprintf("  published HUC10s: %d\n", length(staged_hucs)))

  w <- .fetch_wbd(staged_hucs)
  have <- if (is.null(w)) character(0) else unique(w$huc10)
  missing <- setdiff(staged_hucs, have)
  if (length(missing)) {
    cat(sprintf("  %d not returned by WBD — trying offline shapefile fallback\n", length(missing)))
    fb <- .fallback_shp(missing)
    if (!is.null(fb)) w <- if (is.null(w)) fb else rbind(w, fb)
  }
  if (is.null(w) || !nrow(w)) stop("No boundary geometry obtained (WBD + fallback both empty).")
  w$huc10 <- as.character(w$huc10)
  w <- w[!duplicated(w$huc10), ]

  gaps <- setdiff(staged_hucs, w$huc10)
  if (length(gaps))
    write_log(data.frame(huc10 = gaps, issue = "no_boundary_geometry"), "coverage_gaps.csv")
  cat(sprintf("  boundaries: %d  |  missing geometry: %d\n", nrow(w), length(gaps)))

  forests <- .forest_lookup(w)

  # Model training watersheds (those with a local model) — the validated core.
  w$core <- w$huc10 %in% as.character(core_hucs)
  cat(sprintf("  core (training) watersheds: %d\n", sum(w$core)))

  w_simp <- ms_simplify(w, keep = BOUNDARY_SIMPLIFY_KEEP, method = "vis",
                        keep_shapes = TRUE, explode = FALSE)
  if (file.exists(BOUNDARY_GEOJSON)) file.remove(BOUNDARY_GEOJSON)
  st_write(w_simp, BOUNDARY_GEOJSON, driver = "GeoJSON", quiet = TRUE,
           layer_options = c("COORDINATE_PRECISION=5", "RFC7946=YES"))
  cat(sprintf("  wrote %s (%s)\n", BOUNDARY_GEOJSON, pretty_size(file.info(BOUNDARY_GEOJSON)$size)))

  data.frame(huc10 = w$huc10, name = w$name,
             forest = unname(forests[w$huc10]), stringsAsFactors = FALSE)
}
