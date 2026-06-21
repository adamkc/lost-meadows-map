# ===========================================================================
# 10_viz.R  --  all-watershed prediction products from the per-watershed polygons
#
# For each confidence (high/medium): merge EVERY published watershed's prediction
# polygons into one HUC10-tagged GeoJSON (gitignored intermediate), then derive:
#   * site/data/predictions_{high,medium}.pmtiles  — on-map overlay (vector tiles)
#   * staging/statewide_SN_{high,medium}.gpkg       — statewide download (Drive)
# Returns the statewide GeoPackage rows for the manifest "grouped" block.
#
# This replaces the stale ~27-watershed GroupedPredictions/Temp pre-merge as the
# source for BOTH the overlay and the statewide download.
# ===========================================================================

.merge_to_geojson <- function(rows, product, out_geojson) {
  suppressPackageStartupMessages({ library(sf); library(rmapshaper) })
  rows <- rows[rows$product == product & !is.na(rows$source_path) & nzchar(rows$source_path), ]
  pieces <- vector("list", nrow(rows)); k <- 0L
  for (i in seq_len(nrow(rows))) {
    shp <- rows$source_path[i]
    if (!file.exists(shp)) next
    x <- tryCatch(st_make_valid(st_read(shp, quiet = TRUE)), error = function(e) NULL)
    if (is.null(x) || !nrow(x)) next
    if (is.na(st_crs(x)$epsg) || st_crs(x)$epsg != 4326) x <- st_transform(x, 4326)
    g <- st_sf(geometry = st_geometry(x))
    g <- tryCatch(ms_simplify(g, keep = VIZ_SIMPLIFY_KEEP, method = "vis",
                              keep_shapes = TRUE, explode = FALSE), error = function(e) g)
    k <- k + 1L
    pieces[[k]] <- st_sf(huc10 = rows$huc10[i], geometry = st_geometry(g))
  }
  pieces <- pieces[seq_len(k)]
  if (!k) { cat("  no", product, "polygons found\n"); return(FALSE) }
  merged <- do.call(rbind, pieces)
  if (file.exists(out_geojson)) file.remove(out_geojson)
  st_write(merged, out_geojson, driver = "GeoJSON", quiet = TRUE,
           layer_options = c("COORDINATE_PRECISION=5", "RFC7946=YES"))
  cat(sprintf("  merged %s: %d watersheds, %d features (%s)\n",
              product, k, nrow(merged), pretty_size(file.info(out_geojson)$size)))
  TRUE
}

.tile <- function(geojson, pmtiles) {
  if (INCREMENTAL && file.exists(pmtiles) && isTRUE(file.info(pmtiles)$mtime >= file.info(geojson)$mtime)) {
    cat("  ", basename(pmtiles), ": up to date\n"); return(invisible())
  }
  if (file.exists(pmtiles)) file.remove(pmtiles)
  sf::gdal_utils("vectortranslate", geojson, pmtiles,
    options = c("-f", "PMTiles", "-nln", "predictions",
                "-dsco", paste0("MINZOOM=", VIZ_MINZOOM), "-dsco", paste0("MAXZOOM=", VIZ_MAXZOOM),
                "-dsco", "SIMPLIFICATION=8", "-dsco", "SIMPLIFICATION_MAX_ZOOM=4",
                "-dsco", "MAX_SIZE=500000", "-dsco", "MAX_FEATURES=100000"))
  cat(sprintf("  tiled -> %s (%s)\n", basename(pmtiles), pretty_size(file.info(pmtiles)$size)))
}

.write_gpkg <- function(geojson, gpkg_name) {
  ensure_dir(STAGING_DIR)
  out <- file.path(STAGING_DIR, gpkg_name)
  if (INCREMENTAL && file.exists(out) && isTRUE(file.info(out)$mtime >= file.info(geojson)$mtime)) {
    cat("  ", gpkg_name, ": up to date\n"); return(out)
  }
  if (file.exists(out)) file.remove(out)
  sf::gdal_utils("vectortranslate", geojson, out,
                 options = c("-f", "GPKG", "-nln", "predicted_meadows"))
  cat(sprintf("  gpkg  -> %s (%s)\n", gpkg_name, pretty_size(file.info(out)$size)))
  out
}

# Build one confidence layer's products; return its statewide-gpkg manifest row.
.build_layer <- function(rows, product, geojson, pmtiles, gpkg_name, label) {
  if (file.exists(geojson) && file.info(geojson)$size > 1e6) {
    cat("  reusing merged", basename(geojson), "\n")
  } else if (!.merge_to_geojson(rows, product, geojson)) {
    return(NULL)
  }
  .tile(geojson, pmtiles)
  out <- .write_gpkg(geojson, gpkg_name)
  data.frame(scope = "statewide", name = NA_character_, type = product, label = label,
             staged_name = gpkg_name, size_bytes = file.info(out)$size,
             source_path = geojson, source_mtime = file.info(out)$mtime,
             stringsAsFactors = FALSE)
}

# `staged` = table from 05_stage.R (in-pipeline); NULL => rebuild from manifest.csv.
build_viz_layers <- function(staged = NULL) {
  banner("10  VIZ + STATEWIDE (all watersheds)")
  ensure_dir(SITE_DATA)
  if (is.null(staged)) {
    if (!file.exists(MANIFEST_CSV)) { cat("  manifest.csv missing — run the pipeline first\n"); return(NULL) }
    staged <- utils::read.csv(MANIFEST_CSV, colClasses = "character")
  }
  rows <- rbind(
    .build_layer(staged, "high",   PRED_HIGH_GEOJSON, PRED_HIGH_PMTILES, STATEWIDE_HIGH_GPKG,
                 "All Sierra Nevada high-confidence polygons (GeoPackage)"),
    .build_layer(staged, "medium", PRED_MED_GEOJSON,  PRED_MED_PMTILES,  STATEWIDE_MED_GPKG,
                 "All Sierra Nevada medium-confidence polygons (GeoPackage)")
  )
  rows
}
