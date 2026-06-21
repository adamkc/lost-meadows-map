# ===========================================================================
# run_pipeline.R  --  aggregate + de-duplicate Lost Meadows RF outputs into
# staging/ and generate site/data/{huc10.geojson, manifest.json}.
#
# Run from the project dir:
#   "C:/Program Files/R/R-4.4.1/bin/Rscript.exe" run_pipeline.R
#
# Reads the external source trees read-only; writes only under this project.
# After it finishes: upload staging/ to Drive, then run R/09_merge_drive_ids.R
# to fill in the download links. See README.md.
# ===========================================================================

R_DIR <- "C:/Users/adamk/Documents/Work/Lost Meadows RF/lost-meadows-map/R"

# --- dependencies ----------------------------------------------------------
.need <- c("sf", "rmapshaper", "dplyr", "jsonlite", "units", "digest", "zip")
.missing <- .need[!vapply(.need, requireNamespace, logical(1), quietly = TRUE)]
if (length(.missing)) {
  cat("Installing missing packages:", paste(.missing, collapse = ", "), "\n")
  install.packages(.missing, repos = "https://cloud.r-project.org")
}

# --- load steps ------------------------------------------------------------
for (f in sprintf("%02d_%s.R", c(0,1,2,3,4,5,6,8,7,10),
                  c("config","scan","parse","group_sidecars","dedup",
                    "stage","grouped","boundary","manifest","viz"))) {
  source(file.path(R_DIR, f))
}

t0 <- Sys.time()

# --- run -------------------------------------------------------------------
inv     <- scan_sources()
inv     <- parse_files(inv)
items   <- group_sidecars(inv)
winners <- dedup_items(items)
staged  <- stage_winners(winners)
grouped   <- build_grouped()                 # forests + full database
statewide <- build_viz_layers(staged)        # overlay PMTiles + statewide GeoPackages
grouped   <- do.call(rbind, Filter(Negate(is.null), list(grouped, statewide)))
core_hucs <- unique(staged$huc10[startsWith(staged$product, "local")])  # training watersheds
lookup    <- build_boundary(staged_hucs = unique(staged$huc10), core_hucs = core_hucs)
manifest <- build_manifest(staged, grouped, lookup)

# --- summary ---------------------------------------------------------------
banner("DONE")
cat(sprintf("  elapsed: %.1f min\n", as.numeric(difftime(Sys.time(), t0, units = "mins"))))
cat(sprintf("  watersheds published: %d\n", length(unique(staged$huc10))))
cat(sprintf("  per-watershed files:  %d (%s)\n", nrow(staged), pretty_size(sum(staged$size_bytes))))
if (!is.null(grouped)) cat(sprintf("  grouped files:        %d (%s)\n",
                                   nrow(grouped), pretty_size(sum(grouped$size_bytes, na.rm = TRUE))))
cat("\n  Staging dir: ", STAGING_DIR, "\n", sep = "")
cat("  Next steps:\n")
cat("    1) rclone copy  staging/  gdrive:LostMeadowsRF/products/ -P\n")
cat("    2) rclone lsjson gdrive:LostMeadowsRF/products/ > drive_files.json\n")
cat("    3) Rscript R/09_merge_drive_ids.R\n")
cat("  Review logs/: dedup_audit.csv, unmatched_files.csv, coverage_gaps.csv\n")
