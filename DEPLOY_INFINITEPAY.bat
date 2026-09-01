@echo off
cd /d "%~dp0"
start "Rifa - Supabase Deploy" cmd /k call "%~dp0DEPLOY_INFINITEPAY_DEBUG.bat"
