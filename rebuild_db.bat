@echo off
REM ===========================================================================
REM  rebuild_db.bat  --  one-click refresh of the watershed download map.
REM
REM  Run this whenever you add/replace model outputs. It:
REM    1. re-aggregates + stages outputs       (run_pipeline.R)
REM    2. uploads only new/changed files        (rclone copy, incremental)
REM    3. reads back every file's Drive ID       (rclone lsjson, fast listing)
REM    4. rebuilds the manifest with links        (09_merge_drive_ids.R)
REM
REM  Prereq once: `rclone config` -> create a Google Drive remote named below.
REM  Nothing here re-downloads or re-hashes files; steps 2-3 are metadata-only
REM  for files already on Drive, so repeat runs are fast even with 2000+ files.
REM ===========================================================================

setlocal
REM ---- config (edit if your setup differs) ----
set "RSCRIPT=C:\Program Files\R\R-4.4.1\bin\Rscript.exe"
set "REMOTE=gdrive:LostMeadowsRF/products"
cd /d "%~dp0"

echo.
echo [1/4] Aggregating + staging outputs (run_pipeline.R)...
"%RSCRIPT%" run_pipeline.R
if errorlevel 1 goto :err

echo.
echo [2/4] Uploading new/changed files to Drive (incremental)...
rclone copy staging "%REMOTE%" -P --transfers 8
if errorlevel 1 goto :err

echo.
echo [3/4] Reading Drive file IDs...
rclone lsjson "%REMOTE%" > drive_files.json
if errorlevel 1 goto :err

echo.
echo [4/4] Rebuilding manifest with download links...
"%RSCRIPT%" R\09_merge_drive_ids.R
if errorlevel 1 goto :err

echo.
echo ============================================================
echo  Done. Review logs\ then publish the updated map:
echo     git add site\data ^&^& git commit -m "Refresh data" ^&^& git push
echo ============================================================
REM Uncomment once the GitHub repo + remote exist to auto-publish:
REM git add site\data && git commit -m "Refresh data" && git push
goto :end

:err
echo.
echo ERROR: step failed (exit %errorlevel%). Stopping; nothing published.
exit /b 1

:end
pause
