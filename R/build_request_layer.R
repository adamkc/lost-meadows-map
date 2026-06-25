# Rebuild the "not yet analyzed" request PMTiles in a FRESH R process (its tiling
# is C-stack-heavy too). Invoked by process_inbox.R after the analyzed set changes
# so the now-analyzed HUCs drop out of the request layer.
#   Rscript R/build_request_layer.R
suppressMessages(library(sf))
R_DIR <- "C:/Users/adamk/Documents/Work/Lost Meadows RF/lost-meadows-map/R"
source(file.path(R_DIR, "00_config.R"))
source(file.path(R_DIR, "11_unanalyzed.R"))
build_unanalyzed_layer()
