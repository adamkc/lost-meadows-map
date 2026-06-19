# ===========================================================================
# 06_grouped.R  --  already-aggregated "grouped" offerings
#
#   forest    : LostMeadowsModel_<Forest>.gpkg (newest copy per forest wins)
#   statewide : PredictedMeadows_60SN_{High,Medium}Conf.shp, SMOOTHED then zipped
#   full      : KMP_FullCoverage_SNModel.gpkg, copied as-is (438 MB)
#
# Returns a table consumed by 07_manifest.R as the manifest "grouped" block.
# ===========================================================================

.grouped_row <- function(scope, name, type, label, staged_name, source_path, mtime) {
  spath <- file.path(STAGING_DIR, staged_name)
  data.frame(
    scope = scope, name = name, type = type, label = label,
    staged_name = staged_name,
    size_bytes  = if (file.exists(spath)) file.info(spath)$size else NA_real_,
    source_path = source_path, source_mtime = mtime,
    stringsAsFactors = FALSE
  )
}

.fresh <- function(dest, src) INCREMENTAL && file.exists(dest) &&
  file.exists(src) && isTRUE(file.info(dest)$mtime >= file.info(src)$mtime)

.stage_statewide <- function(in_shp, staged_zip, label) {
  if (!file.exists(in_shp)) { cat("  skip (missing):", in_shp, "\n"); return(NULL) }
  out <- file.path(STAGING_DIR, staged_zip)
  if (.fresh(out, in_shp)) {
    cat(sprintf("  statewide %s: up to date, reused\n", staged_zip))
    return(.grouped_row("statewide", NA, sub("statewide_SN_(.*)_conf\\.zip", "\\1", staged_zip),
                        label, staged_zip, in_shp, file.info(in_shp)$mtime))
  }
  suppressPackageStartupMessages({ library(sf); library(rmapshaper) })
  x  <- st_make_valid(st_read(in_shp, quiet = TRUE))
  if (is.na(st_crs(x)$epsg) || st_crs(x)$epsg != 4326) x <- st_transform(x, 4326)
  v0 <- sum(vapply(st_geometry(x), function(g) length(unlist(g)), integer(1)))
  x  <- ms_simplify(x, keep = STATEWIDE_SIMPLIFY_KEEP, method = "vis",
                    keep_shapes = TRUE, explode = FALSE)
  v1 <- sum(vapply(st_geometry(x), function(g) length(unlist(g)), integer(1)))

  tmp <- file.path(STAGING_DIR, ".tmp_statewide"); ensure_dir(tmp)
  unlink(file.path(tmp, "*"))
  shp_out <- file.path(tmp, sub("\\.zip$", ".shp", staged_zip))
  st_write(x, shp_out, quiet = TRUE, delete_dsn = TRUE)
  parts <- list.files(tmp, pattern = sub("\\.zip$", "", staged_zip), full.names = TRUE)
  if (file.exists(out)) file.remove(out)
  zip::zip(out, basename(parts), root = tmp)
  unlink(tmp, recursive = TRUE)
  cat(sprintf("  statewide %s: %d -> %d vertices, %s\n",
              staged_zip, v0, v1, pretty_size(file.info(out)$size)))
  .grouped_row("statewide", NA, sub("statewide_SN_(.*)_conf\\.zip", "\\1", staged_zip),
               label, staged_zip, in_shp, file.info(in_shp)$mtime)
}

build_grouped <- function() {
  banner("06  GROUPED")
  if (!INCLUDE_GROUPED) { cat("  grouped offerings disabled (INCLUDE_GROUPED=FALSE)\n"); return(NULL) }
  ensure_dir(STAGING_DIR)
  rows <- list()

  # --- forest-level GeoPackages (newest per forest) ---
  gpkgs <- unlist(lapply(FOREST_GPKG_DIRS[dir.exists(FOREST_GPKG_DIRS)], function(d)
    list.files(d, pattern = "^LostMeadowsModel_.*\\.gpkg$", full.names = TRUE)))
  if (length(gpkgs)) {
    nm  <- sub("\\.gpkg$", "", sub("^LostMeadowsModel_", "", basename(gpkgs)))
    mt  <- file.info(gpkgs)$mtime
    df  <- data.frame(path = gpkgs, key = nm, mtime = mt, stringsAsFactors = FALSE)
    df  <- df[order(df$key, -as.numeric(df$mtime)), ]
    df  <- df[!duplicated(df$key), ]                 # newest copy per forest
    for (i in seq_len(nrow(df))) {
      display <- gsub("_", " ", df$key[i])
      sname   <- paste0("forest_", df$key[i], ".gpkg")
      dest    <- file.path(STAGING_DIR, sname)
      if (!.fresh(dest, df$path[i]))
        file.copy(df$path[i], dest, overwrite = TRUE, copy.mode = FALSE)
      rows[[length(rows) + 1]] <- .grouped_row(
        "forest", display, NA, paste0(display, " (GeoPackage)"),
        sname, df$path[i], df$mtime[i])
    }
    cat(sprintf("  forests staged: %d\n", nrow(df)))
  } else cat("  no forest gpkgs found\n")

  # --- statewide merged, smoothed (Part E) ---
  rows[[length(rows) + 1]] <- .stage_statewide(
    STATEWIDE_HIGH_SHP, "statewide_SN_high_conf.zip",
    "All Sierra Nevada high-confidence polygons (smoothed)")
  rows[[length(rows) + 1]] <- .stage_statewide(
    STATEWIDE_MED_SHP, "statewide_SN_medium_conf.zip",
    "All Sierra Nevada medium-confidence polygons (smoothed)")

  # --- full database ---
  if (file.exists(FULL_DATABASE_GPKG)) {
    sname <- "full_SN_database.gpkg"
    dest  <- file.path(STAGING_DIR, sname)
    if (!.fresh(dest, FULL_DATABASE_GPKG))
      file.copy(FULL_DATABASE_GPKG, dest, overwrite = TRUE, copy.mode = FALSE)
    rows[[length(rows) + 1]] <- .grouped_row(
      "full", NA, NA, "Complete model database (GeoPackage)", sname,
      FULL_DATABASE_GPKG, file.info(FULL_DATABASE_GPKG)$mtime)
    cat("  full database staged\n")
  } else cat("  full database not found:", FULL_DATABASE_GPKG, "\n")

  res <- do.call(rbind, Filter(Negate(is.null), rows))
  if (!is.null(res)) cat(sprintf("  grouped items: %d (%s)\n",
                                 nrow(res), pretty_size(sum(res$size_bytes, na.rm = TRUE))))
  res
}
