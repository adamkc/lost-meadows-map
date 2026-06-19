# ===========================================================================
# 07_manifest.R  --  long manifest.csv (audit + Drive-ID join target) and
#                    nested manifest.json (website input)
#
# build_manifest()  : called by the pipeline; writes both with blank Drive URLs.
# write_manifest_json(tbl): shared renderer; 09_merge_drive_ids.R reuses it once
#                    drive_file_id/drive_url are filled in.
# ===========================================================================

.coalesce <- function(x, alt) if (is.null(x) || length(x) == 0 || is.na(x)) alt else x

product_label <- function(product, model, threshold) {
  tmpl <- PRODUCTS[[product]]$label
  if (is.null(tmpl)) return(product)
  lab <- gsub("\\{model\\}", .coalesce(unname(MODEL_LABEL[model]), model), tmpl)
  gsub("\\{thresh\\}", ifelse(is.na(threshold), "", threshold), lab)
}

# Assemble the long manifest data.frame (no Drive columns yet).
build_manifest_table <- function(staged, grouped, huc_lookup) {
  # --- per-watershed rows ---
  s <- staged
  s$watershed_name <- huc_lookup$name[match(s$huc10, huc_lookup$huc10)]
  s$forest         <- huc_lookup$forest[match(s$huc10, huc_lookup$huc10)]
  s$label <- mapply(product_label, s$product, s$model, s$threshold)
  ws <- data.frame(
    huc10 = s$huc10, watershed_name = s$watershed_name, forest = s$forest,
    scope = "watershed", product = s$product, model = s$model, threshold = s$threshold,
    label = s$label, staged_name = s$staged_name, size_bytes = s$size_bytes,
    source_path = s$source_path, source_mtime = s$source_mtime,
    stringsAsFactors = FALSE)

  rows <- ws
  # --- grouped rows ---
  if (!is.null(grouped) && nrow(grouped)) {
    gr <- data.frame(
      huc10 = NA_character_, watershed_name = grouped$name, forest = NA_character_,
      scope = grouped$scope, product = ifelse(is.na(grouped$type), grouped$scope, grouped$type),
      model = NA_character_, threshold = NA_character_, label = grouped$label,
      staged_name = grouped$staged_name, size_bytes = grouped$size_bytes,
      source_path = grouped$source_path, source_mtime = grouped$source_mtime,
      stringsAsFactors = FALSE)
    rows <- rbind(ws, gr)
  }
  rows$drive_file_id <- NA_character_
  rows$drive_url     <- NA_character_
  rows
}

# Render the nested website JSON from a (possibly Drive-filled) manifest table.
write_manifest_json <- function(tbl) {
  ord <- vapply(tbl$product, function(p) as.numeric(.coalesce(PRODUCTS[[p]]$order, 99)), numeric(1))
  tbl <- tbl[order(tbl$huc10, ord), ]

  ws_rows <- tbl[tbl$scope == "watershed", ]
  watersheds <- list()
  for (h in unique(ws_rows$huc10)) {
    g <- ws_rows[ws_rows$huc10 == h, ]
    watersheds[[h]] <- list(
      name   = .coalesce(g$watershed_name[1], NULL),
      forest = .coalesce(g$forest[1], NULL),
      products = lapply(seq_len(nrow(g)), function(i) list(
        type = g$product[i], label = g$label[i],
        drive_url = .coalesce(g$drive_url[i], NULL),
        size = if (is.na(g$size_bytes[i])) NULL else as.numeric(g$size_bytes[i])))
    )
  }

  gx <- tbl[tbl$scope != "watershed", ]
  mk <- function(r) list(name = .coalesce(r$watershed_name, NULL), label = r$label,
                         drive_url = .coalesce(r$drive_url, NULL),
                         size = if (is.na(r$size_bytes)) NULL else as.numeric(r$size_bytes))
  grouped <- list(
    forests   = lapply(which(gx$scope == "forest"),    function(i) mk(gx[i, ])),
    statewide = lapply(which(gx$scope == "statewide"), function(i) c(list(type = gx$product[i]), mk(gx[i, ]))),
    full      = { fi <- which(gx$scope == "full"); if (length(fi)) mk(gx[fi[1], ]) else NULL }
  )

  out <- list(generated = as.character(Sys.Date()),
              watersheds = watersheds, grouped = grouped)
  ensure_dir(SITE_DATA)
  jsonlite::write_json(out, MANIFEST_JSON, auto_unbox = TRUE, pretty = TRUE, null = "null")
  cat(sprintf("  wrote %s (%d watersheds)\n", MANIFEST_JSON, length(watersheds)))
}

build_manifest <- function(staged, grouped, huc_lookup) {
  banner("07  MANIFEST")
  tbl <- build_manifest_table(staged, grouped, huc_lookup)
  utils::write.csv(tbl, MANIFEST_CSV, row.names = FALSE, na = "")
  cat(sprintf("  wrote %s (%d rows)\n", MANIFEST_CSV, nrow(tbl)))
  write_manifest_json(tbl)        # blank Drive URLs for now; 09 fills them in
  invisible(tbl)
}
