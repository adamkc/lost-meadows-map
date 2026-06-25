@echo off
REM ===========================================================================
REM  process_inbox.bat  --  add new predicted watersheds INCREMENTALLY.
REM
REM  Usage: drop a watershed's prediction output files into _inbox\ (the standard
REM  {HUC10}_{model}_predictions[_thresh].{shp,tif,...} files; any folder layout),
REM  then run this. It:
REM    1. processes ONLY the new watersheds         (R\process_inbox.R)
REM         - stages + zips their files into staging\
REM         - appends their boundaries to huc10.geojson
REM         - cleans + re-tiles the high/medium overlay PMTiles (from the gpkgs)
REM         - drops them out of the gray "request" layer
REM         - appends their rows to manifest.csv
REM         - archives the processed inputs to _inbox\_done\
REM    2. uploads new/changed files to Drive         (rclone copy, incremental)
REM    3. reads back Drive file IDs                   (rclone lsjson)
REM    4. fills the manifest download links           (R\09_merge_drive_ids.R)
REM    5. shows a summary and asks before publishing  (git push)
REM
REM  Incremental by design: it never re-runs the full pipeline, so it is fast and
REM  avoids the flaky full-medium-merge crash. Re-running is safe (idempotent).
REM ===========================================================================

setlocal enabledelayedexpansion
set "RSCRIPT=C:\Program Files\R\R-4.4.1\bin\Rscript.exe"
set "REMOTE=gdrive:LostMeadowsRF/products"
cd /d "%~dp0"

echo.
echo [1/4] Processing new watersheds from _inbox\ ...
"%RSCRIPT%" R\process_inbox.R
if errorlevel 1 goto :err

REM ---- read how many new watersheds were processed --------------------------
set "NEWCOUNT=0"
set "HUCS="
for /f "usebackq tokens=2 delims==" %%a in (`findstr /b "new="  logs\inbox_result.txt`) do set "NEWCOUNT=%%a"
for /f "usebackq tokens=2 delims==" %%a in (`findstr /b "hucs=" logs\inbox_result.txt`) do set "HUCS=%%a"

if "%NEWCOUNT%"=="0" (
  echo.
  echo No new watersheds found in _inbox\ . Nothing to upload or publish.
  goto :end
)

echo.
echo [2/4] Uploading new/changed files to Drive (incremental)...
rclone copy staging "%REMOTE%" -P --transfers 8
if errorlevel 1 goto :err

echo.
echo [3/4] Reading Drive file IDs...
rclone lsjson "%REMOTE%" > drive_files.json
if errorlevel 1 goto :err

echo.
echo [4/4] Filling manifest download links...
"%RSCRIPT%" R\09_merge_drive_ids.R
if errorlevel 1 goto :err

echo.
echo ============================================================
echo  Processed %NEWCOUNT% watershed(s): %HUCS%
echo  Local site data + Drive are updated. Review locally if you like:
echo      python devserve.py    (then open http://localhost:8001)
echo ============================================================
set "ANS="
set /p ANS="Publish to the live site now (git commit + push)? (y/N): "
if /i "%ANS%"=="y" (
  echo Publishing...
  git add site/data
  git commit -m "Add watershed(s) via inbox: %HUCS%"
  if errorlevel 1 goto :err
  git push
  if errorlevel 1 goto :err
  echo Published. The GitHub Pages deploy will go live in ~1 minute.
) else (
  echo Skipped publishing. When ready, run:  git add site/data ^&^& git commit -m "Add watersheds" ^&^& git push
)
goto :end

:err
echo.
echo ERROR: step failed (exit %errorlevel%). Stopping; nothing published.
echo Your _inbox inputs that were already processed are in _inbox\_done\ ; staging\ holds the staged copies.
exit /b 1

:end
echo.
pause
