# ===========================================================================
# 05_stage.R  --  copy/zip winners into staging/ with flat, deterministic names
#
# Shapefiles -> one self-contained .zip per logical shapefile (junk paths, so
# the archive holds bare .shp/.shx/.dbf/.prj). Rasters -> copied as-is .tif.
# The staged_name is the join key the Drive-ID merge (09) uses, so it must be
# deterministic.
# ===========================================================================

staged_basename <- function(huc, product, model, threshold) {
  # Main-family products always present as "SN" (the model's current name);
  # "Global" winners are the same model under its original name.
  switch(product,
    high         = sprintf("%s_SN_high_conf",   huc),
    medium       = sprintf("%s_SN_medium_conf", huc),
    raster       = sprintf("%s_SN_prediction",  huc),
    local_high   = sprintf("%s_local_high_conf",   huc),
    local_medium = sprintf("%s_local_medium_conf", huc),
    local_raster = sprintf("%s_local_prediction",  huc),
    local_thresh = sprintf("%s_local_t%s", huc, gsub("-", "to", threshold)),
    stop("unknown product: ", product)
  )
}

.make_zip <- function(out_path, member_paths) {
  if (file.exists(out_path)) file.remove(out_path)
  root <- dirname(member_paths[1])
  zip::zip(zipfile = out_path, files = basename(member_paths), root = root)
}

stage_winners <- function(winners) {
  banner("05  STAGE")
  ensure_dir(STAGING_DIR)
  out <- vector("list", nrow(winners))
  skipped <- 0L

  for (i in seq_len(nrow(winners))) {
    w <- winners[i, ]
    base <- staged_basename(w$huc10, w$product, w$model, w$threshold)
    members <- strsplit(w$files, "\\|")[[1]]
    sname <- paste0(base, if (w$kind == "raster") ".tif" else ".zip")
    spath <- file.path(STAGING_DIR, sname)

    fresh <- INCREMENTAL && file.exists(spath) && isTRUE(file.info(spath)$mtime >= w$mtime)
    if (fresh) {
      skipped <- skipped + 1L
    } else if (w$kind == "raster") {
      file.copy(w$rep_path, spath, overwrite = TRUE, copy.mode = FALSE)
    } else {
      .make_zip(spath, members)
    }

    out[[i]] <- data.frame(
      scope        = "watershed",
      huc10        = w$huc10,
      product      = w$product,
      model        = w$model,
      threshold    = w$threshold,
      kind         = w$kind,
      staged_name  = sname,
      size_bytes   = file.info(spath)$size,
      source_path  = w$rep_path,
      source_mtime = w$mtime,
      stringsAsFactors = FALSE
    )
  }
  res <- do.call(rbind, out)
  cat(sprintf("  staged %d files (%s)  [%d reused, %d (re)written]\n",
              nrow(res), pretty_size(sum(res$size_bytes)), skipped, nrow(res) - skipped))
  res
}
