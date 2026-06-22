# ===========================================================================
# 00_config.R  --  paths, rules, product definitions, shared helpers
#
# Edit the paths below if your machine differs. Everything else in the
# pipeline reads from this file; sourced first by run_pipeline.R.
# ===========================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(jsonlite)
})

# ---- Project root (this repo) ---------------------------------------------
# All outputs are written under here. The R scripts read the external source
# trees read-only.
PROJECT_DIR <- "C:/Users/adamk/Documents/Work/Lost Meadows RF/lost-meadows-map"

STAGING_DIR <- file.path(PROJECT_DIR, "staging")   # gitignored; rclone upload source
LOGS_DIR    <- file.path(PROJECT_DIR, "logs")      # gitignored audit logs
SITE_DATA   <- file.path(PROJECT_DIR, "site", "data")
MANIFEST_CSV  <- file.path(PROJECT_DIR, "manifest.csv")      # audit + Drive-ID join target
MANIFEST_JSON <- file.path(SITE_DATA, "manifest.json")       # website input
BOUNDARY_GEOJSON <- file.path(SITE_DATA, "huc10.geojson")
PRED_HIGH_GEOJSON <- file.path(SITE_DATA, "predictions_high.geojson")    # merged intermediates (gitignored)
PRED_MED_GEOJSON  <- file.path(SITE_DATA, "predictions_medium.geojson")
PRED_HIGH_PMTILES <- file.path(SITE_DATA, "predictions_high.pmtiles")    # committed vector tiles the site loads
PRED_MED_PMTILES  <- file.path(SITE_DATA, "predictions_medium.pmtiles")
# Statewide download GeoPackages (ALL watersheds), staged for Drive. Built from
# the same all-watershed merge as the overlay (10_viz.R), replacing the stale
# ~27-watershed GroupedPredictions/Temp/PredictedMeadows_*.shp aggregates.
STATEWIDE_HIGH_GPKG <- "statewide_SN_high.gpkg"
STATEWIDE_MED_GPKG  <- "statewide_SN_medium.gpkg"

# "Not yet analyzed" request layer: every HUC10 touching the western states,
# minus the analyzed set, server-side generalized and tiled to PMTiles. Clicking
# one on the map opens a mailto to request that watershed's outputs.
UNANALYZED_STATES  <- c("CA", "OR", "WA", "NV", "ID", "WY", "CO")
UNANALYZED_GEOJSON <- file.path(SITE_DATA, "huc10_unanalyzed.geojson")   # gitignored intermediate
UNANALYZED_PMTILES <- file.path(SITE_DATA, "huc10_unanalyzed.pmtiles")   # committed vector tiles
UNANALYZED_OFFSET  <- 0.002    # WBD maxAllowableOffset (degrees, ~200 m generalization)
UNANALYZED_MINZOOM <- 3
UNANALYZED_MAXZOOM <- 10
UNANALYZED_EMAIL   <- "acummings@thewatershedcenter.com"   # request contact

# ---- Source trees ----------------------------------------------------------
WORK_ROOT   <- "C:/Users/adamk/Documents/Work/Lost Meadows RF"          # newer "60SN"
BACKUP_ROOT <- "D:/My Documents Backup/Lost Meadow RF"                  # older "60Global/local"

# Roots scanned for PER-WATERSHED prediction files ({HUC}_{model}_predictions...).
# The filename regex (02_parse.R) is the real filter, so predictor/training
# rasters (elev_net_350.tif, slope.tif, ...) are ignored automatically.
SCAN_ROOTS <- c(
  file.path(WORK_ROOT,   "Analysis"),
  file.path(BACKUP_ROOT, "Model Data"),
  file.path(BACKUP_ROOT, "Analysis")
)

# Already-aggregated inputs handled explicitly by 06_grouped.R (not the parser).
FOREST_GPKG_DIRS <- c(                      # forest-level GeoPackages (newest wins)
  file.path(WORK_ROOT,   "GroupedPredictions"),
  file.path(BACKUP_ROOT, "GroupedPredictions")
)
STATEWIDE_HIGH_SHP <- file.path(WORK_ROOT, "GroupedPredictions/Temp/PredictedMeadows_60SN_HighConf.shp")
STATEWIDE_MED_SHP  <- file.path(WORK_ROOT, "GroupedPredictions/Temp/PredictedMeadows_60SN_MediumConf.shp")
FULL_DATABASE_GPKG <- file.path(WORK_ROOT, "KMP_FullCoverage_SNModel.gpkg")

# Boundary inputs.
PREDICTED_WATERSHEDS_SHP <- file.path(WORK_ROOT, "GroupedPredictions/Temp/PredictedWatersheds.shp")  # offline fallback (211, Sierra)
# HUC10 -> National Forest assignment: USFS national Administrative Forest
# Boundaries (REST). FORESTNAME values match the forest GeoPackage display names
# (e.g. "Tahoe National Forest"), so a clicked watershed can surface its forest gpkg.
USFS_FOREST_QUERY <- "https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_ForestSystemBoundaries_01/MapServer/0/query"
# National WBD HUC10 layer (ArcGIS REST, layer 5 = "10-digit HU (Watershed)";
# fields huc10/name/areasqkm/states). Used to fetch boundaries for the exact set
# of published HUC10s, incl. non-Sierra outliers (OR/CO/WA). No extra package.
WBD_HUC10_QUERY <- "https://hydro.nationalmap.gov/arcgis/rest/services/wbd/MapServer/5/query"
WBD_BATCH       <- 75      # HUC10s per REST request (keeps URL length safe)

# ---- Feature toggles -------------------------------------------------------
INCLUDE_LOCAL        <- TRUE    # ~63 watersheds also have a per-watershed "local" model
INCLUDE_LOCAL_THRESH <- FALSE   # custom local cutoffs (0-13, 0-11, ...) — niche; off by default
INCLUDE_GROUPED      <- TRUE    # forest gpkgs + statewide merges + full database
INCREMENTAL          <- TRUE    # skip re-staging a file whose staged copy is already up to date
                                # (staged mtime >= source mtime). Makes repeat runs fast.
# Watersheds that have a local model but are NOT part of the canonical 60-watershed
# study area — excluded from the purple "training watersheds" outline.
CORE_EXCLUDE         <- c("1801021101", "1801021102", "1801021103", "1801021104", "1801021105")

# Statewide-merge smoothing (Part E). Visvalingam keep ratio: lower = smaller file.
STATEWIDE_SIMPLIFY_KEEP <- 0.15
# Boundary polygon simplification for the web map.
BOUNDARY_SIMPLIFY_KEEP  <- 0.04
# Prediction overlay/statewide cleanup of raster-derived polygons: morphological
# closing (buffer +d then -d) merges adjacent speckles into neighbors and fills
# pinholes; then drop only truly-isolated tiny parts; then simplify. Distances in
# metres (geometry is reprojected to EPSG:5070 for these ops).
VIZ_CLOSE_M          <- 20     # closing distance
VIZ_MIN_ISOLATED_M2  <- 500    # drop isolated parts smaller than this (0.05 ha)
VIZ_SIMPLIFY_M       <- 10     # post-closing Douglas-Peucker tolerance
# Vector-tile (PMTiles) zoom range for the prediction overlay. MINZOOM low
# enough that the "show all" overlay is visible at the multi-state overview.
VIZ_MINZOOM <- 3
VIZ_MAXZOOM <- 11
# Google Drive virus-scan interstitial breaks naive direct-download links above
# this size; such files get the /file/d/{id}/view link form instead.
DRIVE_LARGEFILE_BYTES <- 100 * 1024^2

# ---- Model + product vocabulary -------------------------------------------
# Filename model tokens -> internal model code.
MODEL_MAP <- c("60SN" = "SN", "60Global" = "Global", "OldGlobal" = "OldGlobal", "local" = "local")
# Human label per resolved model. "Global" was the model's original name before it
# was renamed "Sierra Nevada"; both are the same model, so both label as SN.
MODEL_LABEL <- c("SN" = "Sierra Nevada model", "Global" = "Sierra Nevada model", "local" = "local model")
# Within a watershed, a newer/better main model supersedes an older one
# REGARDLESS of file mtime. Higher rank wins. OldGlobal is dropped entirely.
MODEL_RANK <- c("SN" = 2, "Global" = 1)

# Products we publish, with display order and label templates. {model} is filled
# from MODEL_LABEL at manifest time.
PRODUCTS <- list(
  high         = list(order = 1, kind = "shp",    label = "High-confidence polygons ({model})"),
  medium       = list(order = 2, kind = "shp",    label = "Medium-confidence polygons ({model})"),
  raster       = list(order = 3, kind = "raster", label = "Prediction raster (GeoTIFF, {model})"),
  local_high   = list(order = 4, kind = "shp",    label = "High-confidence polygons (local model)"),
  local_medium = list(order = 5, kind = "shp",    label = "Medium-confidence polygons (local model)"),
  local_raster = list(order = 6, kind = "raster", label = "Prediction raster (GeoTIFF, local model)"),
  local_thresh = list(order = 7, kind = "shp",    label = "Polygons, local cutoff {thresh}")
)
KEEP_PRODUCTS <- {
  k <- c("high", "medium", "raster")
  if (INCLUDE_LOCAL)        k <- c(k, "local_high", "local_medium", "local_raster")
  if (INCLUDE_LOCAL_THRESH) k <- c(k, "local_thresh")
  k
}

# Shapefile sidecar extensions worth carrying into the zip (anything sharing a
# stem is grouped regardless; this list is only used for completeness checks).
SHP_SIDECARS <- c("shp", "shx", "dbf", "prj", "cpg", "sbn", "sbx", "qmd", "qpj", "shp.xml")

# ---- Shared helpers --------------------------------------------------------
banner <- function(msg) {
  cat("\n", strrep("=", 70), "\n", msg, "\n", strrep("=", 70), "\n", sep = "")
}

ensure_dir <- function(d) {
  if (!dir.exists(d)) dir.create(d, recursive = TRUE, showWarnings = FALSE)
  invisible(d)
}

pretty_size <- function(bytes) {
  b <- as.numeric(bytes)
  ifelse(is.na(b), "",
  ifelse(b >= 1024^3, sprintf("%.1f GB", b / 1024^3),
  ifelse(b >= 1024^2, sprintf("%.1f MB", b / 1024^2),
  ifelse(b >= 1024,   sprintf("%.0f KB", b / 1024),
                      sprintf("%d B", as.integer(b))))))
}

# Build a Google Drive direct-download (or view-page for large files) URL.
drive_url <- function(file_id, size_bytes) {
  if (is.na(file_id) || file_id == "") return(NA_character_)
  if (!is.na(size_bytes) && size_bytes > DRIVE_LARGEFILE_BYTES) {
    sprintf("https://drive.google.com/file/d/%s/view", file_id)
  } else {
    sprintf("https://drive.google.com/uc?export=download&id=%s", file_id)
  }
}

write_log <- function(df, name) {
  ensure_dir(LOGS_DIR)
  p <- file.path(LOGS_DIR, name)
  utils::write.csv(df, p, row.names = FALSE, na = "")
  cat(sprintf("  log: %s (%d rows)\n", p, nrow(df)))
  invisible(p)
}
