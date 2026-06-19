# ===========================================================================
# 10_viz.R  --  lightweight on-map visualization layers
#
# Writes site/data/predictions_{high,medium}.geojson from the statewide merged
# prediction polygons (which carry a HUC10 field per polygon). The website
# lazy-loads these and filters to a clicked watershed for "View polygons".
# Simplified more aggressively than the download products — it's a visual layer.
# ===========================================================================

.write_viz <- function(in_shp, out_geojson) {
  if (!file.exists(in_shp)) { cat("  skip (missing):", in_shp, "\n"); return(invisible()) }
  if (INCREMENTAL && file.exists(out_geojson) &&
      isTRUE(file.info(out_geojson)$mtime >= file.info(in_shp)$mtime)) {
    cat("  ", basename(out_geojson), ": up to date\n"); return(invisible())
  }
  suppressPackageStartupMessages({ library(sf); library(rmapshaper) })
  x <- st_make_valid(st_read(in_shp, quiet = TRUE))
  if (is.na(st_crs(x)$epsg) || st_crs(x)$epsg != 4326) x <- st_transform(x, 4326)
  hcol <- names(x)[tolower(names(x)) == "huc10"][1]
  x$huc10 <- if (is.na(hcol)) NA_character_ else as.character(x[[hcol]])
  x <- x[, "huc10"]                                  # keep only the filter key
  x <- ms_simplify(x, keep = VIZ_SIMPLIFY_KEEP, method = "vis",
                   keep_shapes = TRUE, explode = FALSE)
  if (file.exists(out_geojson)) file.remove(out_geojson)
  st_write(x, out_geojson, driver = "GeoJSON", quiet = TRUE,
           layer_options = c("COORDINATE_PRECISION=5", "RFC7946=YES"))
  cat(sprintf("  wrote %s (%s, %d features)\n",
              basename(out_geojson), pretty_size(file.info(out_geojson)$size), nrow(x)))
}

build_viz_layers <- function() {
  banner("10  VIZ LAYERS")
  ensure_dir(SITE_DATA)
  .write_viz(STATEWIDE_HIGH_SHP, PRED_HIGH_GEOJSON)
  .write_viz(STATEWIDE_MED_SHP,  PRED_MED_GEOJSON)
}
