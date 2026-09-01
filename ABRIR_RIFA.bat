@echo off
setlocal
cd /d "%~dp0"
start "" "http://localhost:8080/index.html"

where py >nul 2>nul
if %errorlevel%==0 (
  py -m http.server 8080
  exit /b
)

where python >nul 2>nul
if %errorlevel%==0 (
  python -m http.server 8080
  exit /b
)

echo Python nao encontrado. Abrindo index.html diretamente.
start "" "%~dp0index.html"
pause
