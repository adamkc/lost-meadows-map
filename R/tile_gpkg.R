# Tile a predicted-meadows GeoPackage to PMTiles in a FRESH R process. Invoked by
# process_inbox.R via Rscript: the GDAL MVT tiling is C-stack-heavy and overflows
# when run inside a long-lived session that already did geometry work (boundary
# fetch, forest lookup, cleaning). A clean process tiles fine.
#   Rscript R/tile_gpkg.R <gpkg> <pmtiles>
suppressMessages(library(sf))
source("C:/Users/adamk/Documents/Work/Lost Meadows RF/lost-meadows-map/R/00_config.R")
a <- commandArgs(trailingOnly = TRUE)
gpkg <- a[1]; pmtiles <- a[2]
if (file.exists(pmtiles)) file.remove(pmtiles)
sf::gdal_utils("vectortranslate", gpkg, pmtiles,
  options = c("-explodecollections", "-f", "PMTiles", "-nln", "predictions",
              "-dsco", paste0("MINZOOM=", VIZ_MINZOOM), "-dsco", paste0("MAXZOOM=", VIZ_MAXZOOM),
              "-dsco", "SIMPLIFICATION=8", "-dsco", "SIMPLIFICATION_MAX_ZOOM=4",
              "-dsco", "MAX_SIZE=500000", "-dsco", "MAX_FEATURES=100000"))
cat(sprintf("  tiled -> %s (%s)\n", basename(pmtiles), pretty_size(file.info(pmtiles)$size)))
