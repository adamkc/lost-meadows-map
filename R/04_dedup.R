# ===========================================================================
# 04_dedup.R  --  resolve one logical product per (HUC10 x product)
#
# Precedence, in order:
#   1. Drop model == OldGlobal and any non-published product (kappa, custom
#      thresholds unless enabled) entirely.
#   2. Main family (high/medium/raster): SN beats Global REGARDLESS of mtime
#      (model quality, not recency).
#   3. local_* is a separate family — never competes with main; a watershed
#      can publish both its SN and its local products.
#   4. Tie-break remaining copies of the same (huc, model, product) by newest
#      mtime, then larger size, then (only on exact ties) MD5 of the rep file.
# Every candidate + the reason it won/lost is written to logs/dedup_audit.csv.
# ===========================================================================

.rep_md5 <- function(path) {
  tryCatch(digest::digest(file = path, algo = "md5"), error = function(e) NA_character_)
}

dedup_items <- function(items) {
  banner("04  DEDUP")
  items$id <- seq_len(nrow(items))
  items$publishable <- items$product %in% KEEP_PRODUCTS & items$model != "OldGlobal"

  reason    <- rep(NA_character_, nrow(items))
  is_winner <- rep(FALSE, nrow(items))
  reason[items$model == "OldGlobal"] <- "deprecated_oldglobal"
  reason[is.na(reason) & !items$publishable] <- "not_published_product"

  pub <- items[items$publishable, , drop = FALSE]
  key <- paste(pub$huc10, pub$product, sep = "::")

  for (k in unique(key)) {
    rows  <- which(key == k)          # indices into pub
    grp   <- pub[rows, , drop = FALSE]
    ids   <- grp$id
    main  <- !startsWith(grp$product[1], "local_")

    cand <- seq_len(nrow(grp))
    if (main) {
      rnk  <- MODEL_RANK[grp$model]; rnk[is.na(rnk)] <- 0
      best <- which(rnk == max(rnk))
      reason[match(ids[setdiff(cand, best)], items$id)] <- "superseded_by_better_model"
      cand <- best
    }

    cg  <- grp[cand, , drop = FALSE]
    ord <- order(cg$mtime, cg$size, decreasing = TRUE)
    # Exact tie on mtime+size among the top contenders -> disambiguate by MD5
    # (true byte-duplicate => keep first; differing => keep first deterministically).
    win <- cand[ord[1]]
    losers <- setdiff(cand, win)
    if (length(losers)) {
      w <- cg[ord[1], ]
      for (li in losers) {
        l <- grp[li, ]
        same_stamp <- isTRUE(l$mtime == w$mtime) && isTRUE(l$size == w$size)
        reason[match(ids[li], items$id)] <-
          if (same_stamp && identical(.rep_md5(l$rep_path), .rep_md5(w$rep_path)))
            "byte_duplicate" else "older_duplicate"
      }
    }
    is_winner[match(ids[win], items$id)] <- TRUE
    reason[match(ids[win], items$id)]    <- "winner"
  }

  items$is_winner <- is_winner
  items$reason    <- reason

  write_log(
    items[order(items$huc10, items$product, -as.numeric(items$mtime)),
          c("huc10", "product", "model", "threshold", "is_winner", "reason",
            "tree", "mtime", "size", "rep_path")],
    "dedup_audit.csv"
  )

  winners <- items[items$is_winner, , drop = FALSE]
  cat(sprintf("  winners: %d  |  distinct HUC10: %d\n",
              nrow(winners), length(unique(winners$huc10))))
  cat("  winners by product:\n"); print(table(winners$product), zero.print = "")
  winners
}
