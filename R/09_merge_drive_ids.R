# ===========================================================================
# 09_merge_drive_ids.R  --  join Google Drive file IDs into the manifest
#
# Run AFTER uploading staging/ to Drive and exporting the file listing:
#   rclone copy  staging/  gdrive:LostMeadowsRF/products/ -P
#   rclone lsjson gdrive:LostMeadowsRF/products/ > drive_files.json
#
# Then, from the project dir:
#   "C:/Program Files/R/R-4.4.1/bin/Rscript.exe" R/09_merge_drive_ids.R
#
# Idempotent: always rebuilds URLs from a fresh lsjson; never hand-edit IDs.
# ===========================================================================

local({
  here <- "C:/Users/adamk/Documents/Work/Lost Meadows RF/lost-meadows-map/R"
  source(file.path(here, "00_config.R"))
  source(file.path(here, "07_manifest.R"))
})

merge_drive_ids <- function(drive_json = file.path(PROJECT_DIR, "drive_files.json")) {
  banner("09  MERGE DRIVE IDS")
  if (!file.exists(MANIFEST_CSV)) stop("manifest.csv not found — run the pipeline first.")
  if (!file.exists(drive_json))   stop("drive listing not found: ", drive_json,
                                       "\n  run: rclone lsjson gdrive:LostMeadowsRF/products/ > drive_files.json")

  tbl <- utils::read.csv(MANIFEST_CSV, colClasses = "character")
  tbl$size_bytes <- suppressWarnings(as.numeric(tbl$size_bytes))

  dl <- jsonlite::fromJSON(drive_json)
  if (!nrow(dl)) stop("drive listing is empty.")
  ids <- setNames(dl$ID, dl$Name)                 # join key: staged_name == Drive Name

  tbl$drive_file_id <- unname(ids[tbl$staged_name])
  matched <- sum(!is.na(tbl$drive_file_id))
  cat(sprintf("  matched %d/%d staged files to Drive IDs\n", matched, nrow(tbl)))
  unmatched <- tbl$staged_name[is.na(tbl$drive_file_id)]
  if (length(unmatched)) {
    write_log(data.frame(staged_name = unmatched), "drive_unmatched.csv")
    cat(sprintf("  WARNING: %d staged files have no Drive match (logged)\n", length(unmatched)))
  }

  tbl$drive_url <- mapply(drive_url, tbl$drive_file_id, tbl$size_bytes)

  utils::write.csv(tbl, MANIFEST_CSV, row.names = FALSE, na = "")
  cat(sprintf("  updated %s\n", MANIFEST_CSV))
  write_manifest_json(tbl)
  invisible(tbl)
}

# Auto-run when invoked via Rscript.
if (sys.nframe() == 0L || identical(environment(), globalenv())) {
  if (!interactive()) merge_drive_ids()
}
