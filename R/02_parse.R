# ===========================================================================
# 02_parse.R  --  filename -> structured fields
#
# Grammar (all four naming generations):
#   {HUC10}_{60SN|60Global|OldGlobal|local}_predictions[_Kappa][_{thresh}].{ext}
#   thresh = digits-hyphen-digits (e.g. 0-5, 0-25, 0-13); raster = .tif, no thresh.
#
# Anything that doesn't match is written to logs/unmatched_files.csv (never
# silently dropped) and excluded from the returned table.
# ===========================================================================

.PARSE_RE <- paste0(
  "^([0-9]{10})_",                       # 1 huc10
  "(60SN|60Global|OldGlobal|local)_",    # 2 model token
  "predictions",
  "(?:_(Kappa))?",                       # 3 kappa (optional)
  "(?:_([0-9]+-[0-9]+))?",               # 4 threshold (optional)
  "\\.(.+)$"                             # 5 extension (greedy: tif.aux.xml etc.)
)

parse_files <- function(inv) {
  banner("02  PARSE")
  m <- regmatches(inv$fname, regexec(.PARSE_RE, inv$fname, perl = TRUE))
  ok <- vapply(m, length, integer(1)) == 6L

  if (any(!ok)) {
    write_log(inv[!ok, c("path", "fname", "tree")], "unmatched_files.csv")
    cat(sprintf("  unmatched (logged): %d\n", sum(!ok)))
  }

  inv <- inv[ok, , drop = FALSE]
  mm  <- do.call(rbind, m[ok])
  inv$huc10     <- mm[, 2]
  inv$model     <- unname(MODEL_MAP[mm[, 3]])
  inv$kappa     <- nzchar(mm[, 4])
  inv$threshold <- ifelse(nzchar(mm[, 5]), mm[, 5], NA_character_)
  inv$ext       <- tolower(mm[, 6])
  # stem = matched prefix (filename minus ".{ext}"); groups sidecars + raster
  # companions that share it (see 03).
  inv$stem <- substr(inv$fname, 1, nchar(inv$fname) - nchar(mm[, 6]) - 1L)

  cat(sprintf("  parsed files: %d  |  distinct HUC10: %d  |  models: %s\n",
              nrow(inv), length(unique(inv$huc10)),
              paste(sort(unique(inv$model)), collapse = ", ")))
  inv
}
