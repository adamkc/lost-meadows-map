@echo off
REM Local dev server for the Lost Meadows prediction map.
REM Serves this site/ folder on http://localhost:8000 and opens it in your browser.
REM Press Ctrl+C in this window to stop the server.

pushd "%~dp0"

echo.
echo   Lost Meadows prediction map - dev server
echo   ----------------------------------------
echo   Serving from: %CD%
echo   URL:          http://localhost:8000
echo   Stop:         Ctrl+C
echo.

start "" /b cmd /c "timeout /t 1 /nobreak >nul && start http://localhost:8000"

REM Python 3 ships as `python` on modern Windows; `py -3` is the fallback.
python -m http.server 8000 2>nul
if errorlevel 1 py -3 -m http.server 8000

popd
pause
