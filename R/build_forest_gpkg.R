# build_forest_gpkg.R -- rebuild a forest-level GeoPackage from current predictions.
#
#   Rscript R/build_forest_gpkg.R "<Forest Name>" <out.gpkg>
#
# Membership is every published watershed whose boundary intersects the forest at
# all (the rule the 2024 files used; two members overlap by less than 0.05%).
# Prediction polygons are then CLIPPED to the forest boundary and Area_acr is
# recomputed from the clipped shape, so the file contains exactly the predictions
# inside the forest. Watershed boundaries are kept whole, for context.
#   clip=FALSE gives whole watersheds instead (about 3x the content for Lassen).
# The 2024 files followed no single rule: most low-overlap watersheds look
# clipped, but Churn Creek-Sacramento River carries 28,139 acres with 0% of it
# inside the forest, so they cannot be reproduced exactly.
# Field names in PredictedWatersheds and ForestBoundary are mapped back to the
# 2024 spellings, because WBD and the USFS boundary service have both renamed
# their fields since (MetaSource -> metasourceid, FORESTNAME -> forestname, ...).
# Predictions come from staging/<huc>_SN_{high,medium}_conf.zip, i.e. exactly the
# per-watershed files the website serves, so the gpkg cannot drift from them.

suppressPackageStartupMessages({library(sf); library(units); library(httr)})
sf_use_s2(FALSE)

a <- commandArgs(trailingOnly = TRUE)
if (length(a) < 2) stop("usage: build_forest_gpkg.R <Forest Name> <out.gpkg> [clip=TRUE|FALSE]")
FOREST <- a[1]; OUT <- a[2]
CLIP <- if (length(a) >= 3) as.logical(sub("^clip=", "", a[3])) else TRUE
if (is.na(CLIP)) stop("clip= must be TRUE or FALSE")

REPO     <- "C:/Users/adamk/Documents/Work/Lost Meadows RF/lost-meadows-map"
STAGING  <- file.path(REPO, "staging")
HUCGEO   <- file.path(REPO, "site/data/huc10.geojson")
USFS     <- "https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_ForestSystemBoundaries_01/MapServer/0/query"
WBD      <- "https://hydro.nationalmap.gov/arcgis/rest/services/wbd/MapServer/5/query"
EPSG     <- 6414   # NAD83(2011) / California Albers, matching the 2024 files
TMP      <- file.path(tempdir(), "forest_gpkg"); dir.create(TMP, showWarnings = FALSE)

msg <- function(...) cat(sprintf(...), "\n", sep = "")

## ---- forest boundary ------------------------------------------------------
r <- GET(USFS, query = list(where = sprintf("FORESTNAME='%s'", FOREST),
                            outFields = "*", returnGeometry = "true",
                            outSR = "4326", f = "geojson"), timeout(300))
stop_for_status(r)
fb_raw <- st_read(content(r, "text", encoding = "UTF-8"), quiet = TRUE)
if (!nrow(fb_raw)) stop("no forest boundary returned for ", FOREST)
fb_raw <- st_transform(fb_raw, EPSG)
fb <- st_make_valid(st_union(fb_raw))
msg("forest boundary: %s  (%d feature(s), %.0f km2)", FOREST, nrow(fb_raw),
    as.numeric(st_area(fb)) / 1e6)

## ---- membership -----------------------------------------------------------
pub <- st_make_valid(st_transform(st_read(HUCGEO, quiet = TRUE), EPSG))
hit <- lengths(st_intersects(pub, fb)) > 0
hucs <- sort(pub$huc10[hit])
msg("published watersheds intersecting %s: %d   (clip to forest: %s)",
    FOREST, length(hucs), CLIP)

## ---- prediction layers ----------------------------------------------------
acres <- function(g) round(as.numeric(set_units(st_area(g), "acre")), 6)

build_layer <- function(kind, tag) {
  parts <- list()
  for (h in hucs) {
    z <- file.path(STAGING, sprintf("%s_SN_%s_conf.zip", h, kind))
    if (!file.exists(z)) { msg("  %s: no %s zip in staging -- skipped", h, kind); next }
    d <- file.path(TMP, paste0(h, "_", kind)); unlink(d, recursive = TRUE); dir.create(d)
    unzip(z, exdir = d)
    f <- list.files(d, pattern = "[.]shp$", full.names = TRUE)
    if (!length(f)) { msg("  %s: %s zip holds no shapefile -- skipped", h, kind); next }
    g <- st_make_valid(st_transform(st_read(f[1], quiet = TRUE), EPSG))
    if (CLIP) {
      g <- st_make_valid(suppressWarnings(st_intersection(g, fb)))
    }
    g <- g[!st_is_empty(g), ]
    if (!nrow(g)) next
    g <- g[as.numeric(st_area(g)) > 0, ]   # clipping can leave degenerate slivers
    if (!nrow(g)) next
    g <- st_cast(g, "MULTIPOLYGON", warn = FALSE)
    parts[[h]] <- st_sf(
      UID      = sprintf("%s_%d", h, seq_len(nrow(g))),
      HUC10    = h,
      Area_acr = acres(g),
      geometry = st_geometry(g))
  }
  if (!length(parts)) return(invisible(NULL))
  all <- do.call(rbind, parts)
  st_write(all, OUT, layer = tag, append = FALSE, quiet = TRUE)
  msg("wrote %-34s %6d polygons  %11.1f acres  (%d watersheds)",
      tag, nrow(all), sum(all$Area_acr), length(parts))
  invisible(all)
}

if (file.exists(OUT)) unlink(OUT)
hi <- build_layer("high",   "PredictedMeadows_60SN_HighConf")
me <- build_layer("medium", "PredictedMeadows_60SN_MediumConf")

## ---- watershed boundaries (whole, not clipped) ----------------------------
rename_to <- function(x, map) {
  for (from in names(map)) if (from %in% names(x)) names(x)[names(x) == from] <- map[[from]]
  keep <- c(unname(unlist(map)), attr(x, "sf_column"))
  x[, intersect(keep, names(x))]
}
WBD_MAP <- list(objectid = "OBJECTID", tnmid = "TNMID", metasourceid = "MetaSource",
                sourcedatadesc = "SourceData", sourceoriginator = "SourceOrig",
                sourcefeatureid = "SourceFeat", loaddate = "LoadDate",
                referencegnis_ids = "GNIS_ID", areaacres = "AreaAcres",
                areasqkm = "AreaSqKm", states = "States", huc10 = "HUC10",
                name = "Name", hutype = "HUType", humod = "HUMod",
                shape_Length = "Shape_Leng", shape_Area = "Shape_Area")
FB_MAP <- list(adminforestid = "ADMINFORES", region = "REGION",
               forestnumber = "FORESTNUMB", forestorgcode = "FORESTORGC",
               forestname = "FORESTNAME", gis_acres = "GIS_ACRES",
               st_area.shape. = "SHAPE_AREA", st_perimeter.shape. = "SHAPE_LEN")

ids <- paste(sprintf("'%s'", hucs), collapse = ",")
r <- GET(WBD, query = list(where = sprintf("huc10 IN (%s)", ids), outFields = "*",
                           returnGeometry = "true", outSR = "4326", f = "geojson"),
         timeout(300))
stop_for_status(r)
ws <- st_transform(st_read(content(r, "text", encoding = "UTF-8"), quiet = TRUE), EPSG)
ws <- st_make_valid(ws)
miss_h <- setdiff(hucs, ws$huc10)
ws <- rename_to(ws, WBD_MAP)
st_write(ws, OUT, layer = "PredictedWatersheds", append = FALSE, quiet = TRUE)
msg("wrote %-34s %6d watersheds", "PredictedWatersheds", nrow(ws))
if (length(miss_h)) msg("  WBD returned nothing for: %s", paste(miss_h, collapse = ", "))

st_write(rename_to(fb_raw, FB_MAP), OUT, layer = "ForestBoundary", append = FALSE, quiet = TRUE)
msg("wrote %-34s %6d feature(s)", "ForestBoundary", nrow(fb_raw))

msg("")
msg("gpkg:   %s  (%.1f MB)", OUT, file.info(OUT)$size / 1e6)
msg("layers: %s", paste(st_layers(OUT)$name, collapse = ", "))
