# ===========================================================================
# 01_scan.R  --  recursive inventory of the source trees
#
# Returns one row per physical file that (a) lives under a scan root and
# (b) has a HUC-prefixed name + a geospatial extension. The strict name
# prefilter drops predictor/training rasters (elev_net_350.tif, slope.tif, ...)
# before the expensive file.info() call.
# ===========================================================================

# Extensions we care about (shapefile sidecars + rasters + companions).
.SCAN_EXT_RE <- "\\.(shp|shx|dbf|prj|cpg|sbn|sbx|qmd|qpj|shp\\.xml|tif|tiff|tif\\.aux\\.xml|tfw)$"

scan_sources <- function(roots = SCAN_ROOTS) {
  banner("01  SCAN")
  roots <- roots[dir.exists(roots)]
  if (!length(roots)) stop("No scan roots exist. Check paths in 00_config.R.")
  for (r in roots) cat("  root:", r, "\n")

  all_files <- character(0)
  for (r in roots) {
    f <- list.files(r, recursive = TRUE, full.names = TRUE, all.files = FALSE)
    all_files <- c(all_files, f)
  }
  cat(sprintf("  raw file count: %d\n", length(all_files)))

  fname <- basename(all_files)
  # Prefilter: 10-digit HUC prefix + relevant extension. Cheap; cuts the set hard.
  keep <- grepl("^[0-9]{10}_", fname) &
          grepl(.SCAN_EXT_RE, fname, ignore.case = TRUE)
  files <- all_files[keep]
  cat(sprintf("  HUC-prefixed geospatial files: %d\n", length(files)))
  if (!length(files)) stop("Nothing matched the HUC prefix filter — check roots.")

  fi <- file.info(files)
  inv <- data.frame(
    path  = files,
    fname = basename(files),
    dir   = dirname(files),
    mtime = fi$mtime,
    size  = fi$size,
    stringsAsFactors = FALSE
  )
  # Tag source tree.
  inv$tree <- ifelse(startsWith(inv$path, WORK_ROOT), "work",
              ifelse(startsWith(inv$path, BACKUP_ROOT), "backup", "other"))
  inv
}
