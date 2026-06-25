# ===========================================================================
# process_inbox.R  --  INCREMENTAL add of new predicted watersheds.
#
# Drop a watershed's full prediction output (the standard
# {HUC10}_{model}_predictions[_thresh].{shp,tif,...} files, any folder layout)
# into _inbox/ and run process_inbox.bat. This script touches ONLY the new
# watersheds and appends them to the live site data — it does NOT re-run the
# whole pipeline (which re-scans 45k files and hits the flaky full-medium-merge
# crash). It reuses the pipeline's functions over just the inbox set:
#
#   scan/parse/group/dedup/stage  -> stage new per-watershed files
#   08 .fetch_wbd / .forest_lookup -> append new boundaries to huc10.geojson
#   10 .clean_watershed            -> clean + append polys to the statewide gpkgs,
#                                     re-tile predictions_{high,medium}.pmtiles
#   11 build_unanalyzed_layer      -> drop now-analyzed HUCs from the request layer
#   07 build_manifest_table        -> append new rows to manifest.csv
#
# It leaves staging/ + site/data updated. The .bat then does rclone (upload +
# IDs), runs 09 to fill manifest.json links, and prompts before deploying.
#
# Idempotent: re-running re-processes the same inbox cleanly (each new HUC's rows
# are rebuilt, never duplicated). Handles re-drops (updated predictions) the same
# way. Memory-flat: only the handful of new watersheds are cleaned in R.
# ===========================================================================

R_DIR <- "C:/Users/adamk/Documents/Work/Lost Meadows RF/lost-meadows-map/R"
for (f in sprintf("%02d_%s.R", c(0, 1, 2, 3, 4, 5, 8, 7, 10, 11),
                  c("config", "scan", "parse", "group_sidecars", "dedup",
                    "stage", "boundary", "manifest", "viz", "unanalyzed")))
  source(file.path(R_DIR, f))
suppressPackageStartupMessages({ library(sf); library(rmapshaper) })

# Heavy PMTiles tiling must run in a FRESH R process — the GDAL MVT tiler is
# C-stack-heavy and overflows when run in this long-lived session after the
# boundary/forest/clean geometry work. run_fresh() shells out to a clean Rscript.
RSCRIPT_BIN <- file.path(R.home("bin"), if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript")
run_fresh <- function(script, ...) {
  args <- c(shQuote(file.path(R_DIR, script)), vapply(list(...), shQuote, character(1)))
  st <- system2(RSCRIPT_BIN, args = args)
  if (st != 0) stop("subprocess ", script, " failed (exit ", st, ")")
}

INBOX_DIR  <- file.path(PROJECT_DIR, "_inbox")
INBOX_DONE <- file.path(INBOX_DIR, "_done")
RESULT_TXT <- file.path(LOGS_DIR, "inbox_result.txt")   # marker the .bat reads
ensure_dir(INBOX_DIR); ensure_dir(LOGS_DIR)
writeLines(c("new=0", "hucs="), RESULT_TXT)             # default: nothing processed

banner("PROCESS INBOX (incremental)")

# ---- 1. Inventory just the inbox (excluding the _done archive) -------------
raw <- list.files(INBOX_DIR, recursive = TRUE, full.names = TRUE)
raw <- raw[!grepl("/_done/", gsub("\\\\", "/", raw), fixed = TRUE)]
hits <- grepl("^[0-9]{10}_", basename(raw)) & grepl("\\.(shp|shx|dbf|prj|cpg|tif|tiff|tfw|aux\\.xml|qmd|qpj)$", basename(raw), ignore.case = TRUE)
if (!any(hits)) { cat("  _inbox holds no HUC-prefixed prediction files — nothing to do.\n"); quit(status = 0) }

inv <- scan_sources(roots = INBOX_DIR)
inv <- inv[!grepl("/_done/", gsub("\\\\", "/", inv$path), fixed = TRUE), , drop = FALSE]
if (!nrow(inv)) { cat("  nothing new in _inbox.\n"); quit(status = 0) }

inv     <- parse_files(inv)
items   <- group_sidecars(inv)
winners <- dedup_items(items)
staged  <- stage_winners(winners)
new_hucs <- sort(unique(staged$huc10))
cat(sprintf("\n  >>> new/updated watersheds in this batch: %d  (%s)\n",
            length(new_hucs), paste(new_hucs, collapse = ", ")))

# ---- 2. Boundaries: append truly-new HUCs to huc10.geojson -----------------
# An `added` ISO date drives the front-end "recently added" border (it auto-
# expires there after a set number of days). Every watershed in this batch (new
# OR re-dropped/updated) gets stamped with today.
TODAY <- as.character(Sys.Date())
B <- st_read(BOUNDARY_GEOJSON, quiet = TRUE)
B$huc10 <- as.character(B$huc10)
keepcols <- c("huc10", "name", "areasqkm", "core", "added")
for (c0 in setdiff(keepcols, names(B))) B[[c0]] <- NA   # add `added` (etc.) if absent
to_fetch <- setdiff(new_hucs, B$huc10)
new_lookup <- data.frame(huc10 = character(0), name = character(0), forest = character(0))
old_man <- if (file.exists(MANIFEST_CSV)) utils::read.csv(MANIFEST_CSV, colClasses = "character") else NULL

if (length(to_fetch)) {
  cat(sprintf("  fetching %d new boundary polygon(s) from WBD...\n", length(to_fetch)))
  w <- .fetch_wbd(to_fetch)
  if (is.null(w) || !nrow(w)) stop("WBD returned no geometry for new HUCs: ", paste(to_fetch, collapse = ", "))
  w$huc10 <- as.character(w$huc10)
  w$core  <- FALSE                                   # new watersheds are not training
  forests <- .forest_lookup(w)
  w_simp  <- ms_simplify(w, keep = BOUNDARY_SIMPLIFY_KEEP, method = "vis", keep_shapes = TRUE, explode = FALSE)
  for (c0 in setdiff(keepcols, names(w_simp))) w_simp[[c0]] <- NA   # align columns
  B <- rbind(B[, keepcols], w_simp[, keepcols])
  new_lookup <- rbind(new_lookup,
    data.frame(huc10 = w$huc10, name = w$name, forest = unname(forests[w$huc10]), stringsAsFactors = FALSE))
}
# Re-drops (HUC already mapped): reuse existing name (geojson) + forest (manifest).
for (h in setdiff(new_hucs, new_lookup$huc10)) {
  nm <- as.character(B$name[match(h, B$huc10)])
  fo <- if (!is.null(old_man)) old_man$forest[match(h, old_man$huc10)] else NA_character_
  new_lookup <- rbind(new_lookup, data.frame(huc10 = h, name = nm, forest = fo, stringsAsFactors = FALSE))
}

B$added[B$huc10 %in% new_hucs] <- TODAY            # flag this batch as recently added
if (file.exists(BOUNDARY_GEOJSON)) file.remove(BOUNDARY_GEOJSON)
st_write(B, BOUNDARY_GEOJSON, driver = "GeoJSON", quiet = TRUE,
         layer_options = c("COORDINATE_PRECISION=5", "RFC7946=YES"))
cat(sprintf("  huc10.geojson: %d features; %d stamped added=%s\n", nrow(B), length(new_hucs), TODAY))

# ---- 3. Overlay: rebuild each statewide gpkg = (existing - new) + new, tile -
.tile_from_gpkg <- function(gpkg, pmtiles) run_fresh("tile_gpkg.R", gpkg, pmtiles)
update_overlay <- function(product, gpkg_name, pmtiles) {
  rows <- staged[staged$product == product, , drop = FALSE]
  gpkg <- file.path(STAGING_DIR, gpkg_name)
  if (!nrow(rows)) return(if (file.exists(gpkg)) file.info(gpkg)$size else NA_real_)
  hucs <- unique(rows$huc10)
  tmp  <- tempfile(fileext = ".gpkg")
  if (file.exists(gpkg)) {
    inlist <- paste(sprintf("'%s'", hucs), collapse = ",")
    sf::gdal_utils("vectortranslate", gpkg, tmp,
      options = c("-f", "GPKG", "-nln", "predicted_meadows", "-where", sprintf("huc10 NOT IN (%s)", inlist)))
  }
  first <- !file.exists(tmp)
  for (i in seq_len(nrow(rows))) {
    shp <- rows$source_path[i]; huc <- rows$huc10[i]
    x <- tryCatch(st_make_valid(st_read(shp, quiet = TRUE)), error = function(e) NULL)
    if (is.null(x) || !nrow(x)) { cat("    ", huc, product, "unreadable\n"); next }
    geom <- tryCatch(.clean_watershed(x), error = function(e) NULL)
    if (is.null(geom) || all(st_is_empty(geom))) { cat("    ", huc, product, "no-geom (skipped)\n"); next }
    st_write(st_sf(huc10 = huc, geometry = geom), tmp, layer = "predicted_meadows", append = !first, quiet = TRUE)
    first <- FALSE
  }
  file.copy(tmp, gpkg, overwrite = TRUE); unlink(tmp)
  .tile_from_gpkg(gpkg, pmtiles)
  cat(sprintf("  %s overlay rebuilt: gpkg %s, %s\n", product,
              pretty_size(file.info(gpkg)$size), pretty_size(file.info(pmtiles)$size)))
  file.info(gpkg)$size
}
high_size <- update_overlay("high",   STATEWIDE_HIGH_GPKG, PRED_HIGH_PMTILES)
med_size  <- update_overlay("medium", STATEWIDE_MED_GPKG,  PRED_MED_PMTILES)

# ---- 4. Manifest.csv: drop new HUCs' old rows, append fresh ----------------
new_rows <- build_manifest_table(staged, grouped = NULL, huc_lookup = new_lookup)
if (!is.null(old_man)) {
  keep <- old_man[!(old_man$scope == "watershed" & old_man$huc10 %in% new_hucs), , drop = FALSE]
  if (!is.na(high_size)) keep$size_bytes[keep$staged_name == STATEWIDE_HIGH_GPKG] <- as.character(high_size)
  if (!is.na(med_size))  keep$size_bytes[keep$staged_name == STATEWIDE_MED_GPKG]  <- as.character(med_size)
  for (cc in names(new_rows)) new_rows[[cc]] <- as.character(new_rows[[cc]])
  for (cc in setdiff(names(keep), names(new_rows))) new_rows[[cc]] <- NA_character_
  tbl <- rbind(keep[, names(keep)], new_rows[, names(keep)])
} else tbl <- new_rows
utils::write.csv(tbl, MANIFEST_CSV, row.names = FALSE, na = "")
cat(sprintf("  manifest.csv updated (%d rows)\n", nrow(tbl)))

# ---- 5. Request layer: re-tile so now-analyzed HUCs drop out ----------------
# Only the analyzed set changing matters; a pure re-drop (HUC already mapped)
# leaves it unchanged, so skip the WBD fetch + re-tile in that case.
if (length(to_fetch)) run_fresh("build_request_layer.R") else
  cat("  request layer unchanged (no brand-new HUCs)\n")

# ---- 6. Record result for the .bat -----------------------------------------
writeLines(c(paste0("new=", length(new_hucs)), paste0("hucs=", paste(new_hucs, collapse = " "))), RESULT_TXT)

# ---- 7. Archive processed inputs so the inbox is clear next time ------------
stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
dest  <- file.path(INBOX_DONE, stamp); ensure_dir(dest)
moved <- 0L
to_archive <- raw[grepl("^[0-9]{10}_", basename(raw))]   # only the inputs; leave README etc.
for (f in to_archive) {
  if (!file.exists(f)) next
  ok <- tryCatch(file.rename(f, file.path(dest, basename(f))), warning = function(w) FALSE, error = function(e) FALSE)
  if (isTRUE(ok)) moved <- moved + 1L
}
for (d in rev(list.dirs(INBOX_DIR, recursive = TRUE))) {       # prune emptied folders
  if (!grepl("/_done", gsub("\\\\", "/", d)) && d != INBOX_DIR && !length(list.files(d, recursive = TRUE)))
    unlink(d, recursive = TRUE)
}
cat(sprintf("  archived %d input file(s) -> _inbox/_done/%s/\n", moved, stamp))

banner("INBOX PROCESSED (local) — staging/ + site/data updated")
cat("  Next (handled by the .bat): rclone upload, manifest links (09), deploy prompt.\n")
