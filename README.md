# Lost Meadows Predictions — Watershed Download Map

An interactive map that lets anyone click a HUC10 watershed and download the
Lost Meadows random-forest meadow predictions for it — high-confidence polygons,
medium-confidence polygons, and the raster prediction (plus local-model and
aggregate extras). Prediction files are hosted on Google Drive; the map is a
static site on GitHub Pages.

Two halves:

1. **R pipeline** (`R/`, `run_pipeline.R`) — scans the scattered source folders,
   de-duplicates, and stages clean, web-ready files into `staging/`, then builds
   `site/data/huc10.geojson` + `site/data/manifest.json`.
2. **Static site** (`site/`) — vanilla MapLibre GL JS; reads the boundary GeoJSON
   and the manifest of Drive links.

---

## One-time setup

- **R 4.4.x** with packages `sf, rmapshaper, dplyr, jsonlite, units, digest, zip`
  (`run_pipeline.R` installs any that are missing).
- **rclone** for the Drive upload — https://rclone.org/downloads/ — then
  `rclone config` to create a Google Drive remote named `gdrive`.

Paths to the source trees and the project live at the top of
[`R/00_config.R`](R/00_config.R). Edit them if your machine differs.

---

## Workflow

### 1. Aggregate + stage (R)

```sh
"C:/Program Files/R/R-4.4.1/bin/Rscript.exe" run_pipeline.R
```

What it does:
- **Scans** `Analysis/` (work) + `Model Data/` and `Analysis/` (backup) for
  `{HUC10}_{model}_predictions...` files. The HUC-prefixed filename filter
  ignores predictor/training rasters automatically.
- **De-duplicates** to one logical product per `(HUC10 × product)`:
  - drops `OldGlobal` and `Kappa` variants;
  - **SN (Sierra Nevada) beats Global regardless of file date** (model quality,
    not recency);
  - `local` is a separate family — a watershed can publish both its SN and local
    products;
  - ties broken by newest mtime, then size, then MD5.
- **Stages** winners into `staging/` with deterministic names
  (`{HUC10}_SN_high_conf.zip`, `{HUC10}_SN_prediction.tif`, `{HUC10}_local_...`).
  Shapefiles are zipped (bare sidecars); rasters copied as-is.
- **Grouped offerings** → `staging/`: forest GeoPackages (`forest_*.gpkg`,
  newest copy per forest), **smoothed** statewide merges
  (`statewide_SN_{high,medium}_conf.zip`), and the full database
  (`full_SN_database.gpkg`).
- **Boundaries** → `site/data/huc10.geojson`: fetched from the national USGS WBD
  HUC10 service for the exact set of published watersheds (covers OR/CO/WA
  outliers; offline fallback to `PredictedWatersheds.shp`). Each watershed is
  tagged with its National Forest (USFS service) so the popup can surface the
  forest GeoPackage.
- **Manifest** → `manifest.csv` (root, audit + Drive-ID join target) and
  `site/data/manifest.json` (website input, Drive URLs blank for now).

Review `logs/`:
- `dedup_audit.csv` — every candidate file and why it won/lost.
- `unmatched_files.csv` — files that didn't fit the naming grammar.
- `incomplete_shapefiles.csv`, `coverage_gaps.csv`, `drive_unmatched.csv`.

### 2. Upload to Google Drive (rclone)

```sh
rclone copy  staging/  gdrive:LostMeadowsRF/products/ -P
rclone lsjson gdrive:LostMeadowsRF/products/ > drive_files.json
```

Then share the `LostMeadowsRF/products/` folder once in the Drive UI as
**"Anyone with the link → Viewer"**.

### 3. Merge Drive links into the manifest (R)

```sh
"C:/Program Files/R/R-4.4.1/bin/Rscript.exe" R/09_merge_drive_ids.R
```

Joins each staged file to its Drive ID by name and writes download URLs into
`manifest.csv` + `site/data/manifest.json`. Files > 100 MB get the
`/file/d/{id}/view` link form (the small files get a direct `uc?export=download`
link) to dodge Drive's virus-scan interstitial. Idempotent — re-run any time
after re-uploading.

### 4. Preview locally

```sh
cd site && python -m http.server 8000     # or run site/serve.bat
```

Open http://localhost:8000 — click a watershed, confirm the popup links download.

### 5. Deploy

Create the GitHub repo and push; `.github/workflows/deploy.yml` publishes the
`site/` folder to GitHub Pages on every push to `main`. The multi-GB prediction
files live on Drive and never enter the repo (`staging/` is gitignored).

```sh
gh repo create lost-meadows-map --public --source . --push
```

Then enable Pages (Settings → Pages → Source: GitHub Actions).

---

## Layout

```
R/                 numbered pipeline steps (00 config … 09 drive-id merge)
run_pipeline.R     runs steps 00–08 end to end
staging/           web-ready files bound for Drive            (gitignored)
logs/              audit logs                                  (gitignored)
manifest.csv       long manifest / Drive-ID join target        (gitignored)
site/              the static website (deployed to Pages)
  index.html  app.js  style.css  serve.bat
  data/huc10.geojson   data/manifest.json   committed web assets
```

> The `site/data/*.json/geojson` currently committed are a small **sample**
> (a few watersheds, links pending) so the map renders before the first full
> run. `run_pipeline.R` + step 09 overwrite them with the real data.

---

## Notes & knobs (in `R/00_config.R`)

- `INCLUDE_LOCAL` (on), `INCLUDE_LOCAL_THRESH` (off — custom local cutoffs like
  `0-13`), `INCLUDE_GROUPED` (on).
- `STATEWIDE_SIMPLIFY_KEEP` / `BOUNDARY_SIMPLIFY_KEEP` — geometry simplification.
- `DRIVE_LARGEFILE_BYTES` — threshold for the view-page link form.
- Total staged volume is ~several GB (≈215 rasters × ~13 MB + zips + gpkgs +
  the 438 MB full database) — confirm the Drive account has quota.
