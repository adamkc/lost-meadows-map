# ===========================================================================
# 03_group_sidecars.R  --  collapse physical files into logical items
#
# A logical item = all files sharing (dir, stem). For a polygon that's the
# .shp/.shx/.dbf/.prj set; for a raster the .tif (+ .tif.aux.xml/.tfw). The
# item's product class is derived from threshold + whether it's shp or tif.
# ===========================================================================

# Classify a group into a product code from its model/threshold/kappa/exts.
.classify <- function(model, threshold, kappa, has_shp, has_tif) {
  conf <-
    if (kappa)                         "kappa"
    else if (has_shp && identical(threshold, "0-5"))  "high"
    else if (has_shp && identical(threshold, "0-25")) "medium"
    else if (has_shp && !is.na(threshold))            "thresh"
    else if (has_shp)                                 "other_poly"
    else if (has_tif && is.na(threshold))             "raster"
    else if (has_tif)                                 "thresh_raster"
    else                                              "other"
  if (identical(model, "local")) paste0("local_", conf) else conf
}

group_sidecars <- function(inv) {
  banner("03  GROUP SIDECARS")
  inv$gkey <- paste(inv$dir, inv$stem, sep = "::")

  items <- lapply(split(seq_len(nrow(inv)), inv$gkey), function(ix) {
    g <- inv[ix, , drop = FALSE]
    has_shp <- any(g$ext == "shp")
    has_tif <- any(g$ext %in% c("tif", "tiff"))
    rep_i   <- if (has_shp) which(g$ext == "shp")[1]
               else if (has_tif) which(g$ext %in% c("tif", "tiff"))[1]
               else 1L
    product <- .classify(g$model[1], g$threshold[1], g$kappa[1], has_shp, has_tif)
    complete_shp <- !has_shp || all(c("shp", "shx", "dbf", "prj") %in% g$ext)
    data.frame(
      huc10     = g$huc10[1],
      model     = g$model[1],
      threshold = g$threshold[1],
      product   = product,
      kind      = if (has_shp) "shp" else if (has_tif) "raster" else "other",
      tree      = g$tree[1],
      dir       = g$dir[1],
      stem      = g$stem[1],
      rep_path  = g$path[rep_i],
      mtime     = g$mtime[rep_i],
      size      = g$size[rep_i],
      n_files   = nrow(g),
      complete  = complete_shp,
      files     = paste(g$path, collapse = "|"),   # member paths, |-joined
      stringsAsFactors = FALSE
    )
  })
  items <- do.call(rbind, items)
  rownames(items) <- NULL

  bad <- !items$complete
  if (any(bad)) {
    write_log(items[bad, c("huc10", "product", "stem", "dir", "n_files")],
              "incomplete_shapefiles.csv")
    cat(sprintf("  incomplete shapefile sets (logged, dropped): %d\n", sum(bad)))
  }
  items <- items[items$complete, , drop = FALSE]

  cat(sprintf("  logical items: %d\n", nrow(items)))
  print(table(items$product), zero.print = "")
  items
}
