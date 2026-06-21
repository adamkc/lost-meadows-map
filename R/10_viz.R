# ===========================================================================
# 10_viz.R  --  on-map "view polygons" overlay as PMTiles vector tiles
#
# For each confidence (high/medium): merge the per-watershed prediction polygons
# for ALL published watersheds into one HUC10-tagged GeoJSON (the intermediate,
# gitignored), then tile it to a compact .pmtiles the site loads via range
# requests. Vector tiles handle ~600k polygons that a single GeoJSON cannot.
#
# Built from the staged winners (in-pipeline) or from manifest.csv (standalone).
# NB: the GroupedPredictions/Temp/PredictedMeadows_*.shp pre-merge is only ~27
# watersheds — do NOT use it as the overlay source.
# ===========================================================================

# Merge every per-watershed source shapefile for `product` into one sf, each
# feature tagged with its huc10, simplified for the web.
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
  suppressPackageStartupMessages(library(sf))
  if (file.exists(pmtiles)) file.remove(pmtiles)
  sf::gdal_utils("vectortranslate", geojson, pmtiles,
    options = c("-f", "PMTiles", "-nln", "predictions",
                "-dsco", paste0("MINZOOM=", VIZ_MINZOOM),
                "-dsco", paste0("MAXZOOM=", VIZ_MAXZOOM),
                "-dsco", "SIMPLIFICATION=8", "-dsco", "SIMPLIFICATION_MAX_ZOOM=4",
                "-dsco", "MAX_SIZE=500000", "-dsco", "MAX_FEATURES=100000"))
  cat(sprintf("  tiled -> %s (%s)\n", basename(pmtiles), pretty_size(file.info(pmtiles)$size)))
}

.build_layer <- function(rows, product, geojson, pmtiles) {
  # Reuse an existing merged GeoJSON (the slow per-watershed read) when present.
  if (file.exists(geojson) && file.info(geojson)$size > 1e6) {
    cat("  reusing merged", basename(geojson), "\n")
  } else if (!.merge_to_geojson(rows, product, geojson)) {
    return(invisible())
  }
  .tile(geojson, pmtiles)
}

# `staged` = table from 05_stage.R (in-pipeline); NULL => rebuild from manifest.csv.
build_viz_layers <- function(staged = NULL) {
  banner("10  VIZ LAYERS (PMTiles)")
  ensure_dir(SITE_DATA)
  if (is.null(staged)) {
    if (!file.exists(MANIFEST_CSV)) { cat("  manifest.csv missing — run the pipeline first\n"); return(invisible()) }
    staged <- utils::read.csv(MANIFEST_CSV, colClasses = "character")
  }
  .build_layer(staged, "high",   PRED_HIGH_GEOJSON, PRED_HIGH_PMTILES)
  .build_layer(staged, "medium", PRED_MED_GEOJSON,  PRED_MED_PMTILES)
}
