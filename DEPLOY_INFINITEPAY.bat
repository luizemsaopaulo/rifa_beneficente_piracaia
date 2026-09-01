@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Rifa - Deploy InfinitePay no Supabase
cd /d "%~dp0"

set "PROJECT_REF=qzpezwscmwfznzzbrxpb"
set "FUNCTION_NAME=infinitepay-gateway"
set "LOG=%~dp0deploy_infinitepay_log.txt"
set "TMP_OUT=%TEMP%\rifa_supabase_%RANDOM%_%RANDOM%.txt"

> "%LOG%" echo ============================================================
>>"%LOG%" echo RIFA - DEPLOY INFINITEPAY / SUPABASE
>>"%LOG%" echo Inicio: %DATE% %TIME%
>>"%LOG%" echo Pasta: %CD%
>>"%LOG%" echo Projeto: %PROJECT_REF%
>>"%LOG%" echo ============================================================

cls
echo ============================================================
echo  RIFA - DEPLOY INFINITEPAY / SUPABASE
echo ============================================================
echo.
echo Esta janela NAO fecha sozinha se der erro.
echo Log: %LOG%
echo.

echo [1/5] Verificando Node.js...
where node >nul 2>nul
if errorlevel 1 (
    echo.
    echo [ERRO] Node.js nao foi encontrado.
    echo Instale o Node.js LTS 20 ou superior.
    >>"%LOG%" echo [ERRO] Node.js nao encontrado.
    goto :ERRO
)

for /f "delims=" %%V in ('node -v') do set "NODE_VERSION=%%V"
for /f "delims=" %%M in ('node -p "process.versions.node.split('.')[0]"') do set "NODE_MAJOR=%%M"

echo Node: !NODE_VERSION!
>>"%LOG%" echo Node: !NODE_VERSION!

if !NODE_MAJOR! LSS 20 (
    echo.
    echo [ERRO] Node.js antigo: !NODE_VERSION!
    echo Atualize para Node.js 20 ou superior.
    >>"%LOG%" echo [ERRO] Node antigo: !NODE_VERSION!
    goto :ERRO
)

echo.
echo [2/5] Verificando npx...
where npx >nul 2>nul
if errorlevel 1 (
    echo [ERRO] npx nao foi encontrado.
    >>"%LOG%" echo [ERRO] npx nao encontrado.
    goto :ERRO
)

for /f "delims=" %%V in ('npx --version') do set "NPX_VERSION=%%V"
echo npx: !NPX_VERSION!
>>"%LOG%" echo npx: !NPX_VERSION!

echo.
echo [3/5] Carregando Supabase CLI...
echo Na primeira vez pode demorar alguns minutos.
call npx -y supabase@latest --version >"%TMP_OUT%" 2>&1
set "RC=!ERRORLEVEL!"
type "%TMP_OUT%"
type "%TMP_OUT%" >>"%LOG%"

if not "!RC!"=="0" (
    echo.
    echo [ERRO] Supabase CLI nao iniciou.
    goto :ERRO
)

echo.
echo [4/5] Verificando login...
call npx -y supabase@latest projects list >"%TMP_OUT%" 2>&1
set "RC=!ERRORLEVEL!"
type "%TMP_OUT%"
type "%TMP_OUT%" >>"%LOG%"

if not "!RC!"=="0" (
    echo.
    echo Voce ainda precisa entrar no Supabase CLI.
    echo O comando de login sera aberto agora.
    echo.
    call npx -y supabase@latest login
    set "RC=!ERRORLEVEL!"
    >>"%LOG%" echo Resultado login: !RC!

    if not "!RC!"=="0" (
        echo.
        echo [ERRO] Login nao concluido.
        goto :ERRO
    )
)

echo.
echo [5/5] Publicando funcao %FUNCTION_NAME%...
echo Projeto: %PROJECT_REF%
echo.

if not exist "%~dp0supabase\functions\%FUNCTION_NAME%\index.ts" (
    echo [ERRO] Nao encontrei:
    echo %~dp0supabase\functions\%FUNCTION_NAME%\index.ts
    echo.
    echo Este BAT precisa ficar na RAIZ da pasta da rifa,
    echo junto das pastas css, js e supabase.
    >>"%LOG%" echo [ERRO] Edge Function nao encontrada.
    goto :ERRO
)

call npx -y supabase@latest functions deploy %FUNCTION_NAME% --project-ref %PROJECT_REF% --no-verify-jwt --use-api --debug >"%TMP_OUT%" 2>&1
set "RC=!ERRORLEVEL!"
type "%TMP_OUT%"
type "%TMP_OUT%" >>"%LOG%"

if not "!RC!"=="0" (
    echo.
    echo ============================================================
    echo  DEPLOY FALHOU
    echo ============================================================
    echo.
    echo O erro completo ficou salvo em:
    echo %LOG%
    goto :ERRO
)

echo.
echo ============================================================
echo  SUCESSO!
echo ============================================================
echo.
echo A funcao %FUNCTION_NAME% foi publicada.
echo.
echo URL:
echo https://%PROJECT_REF%.supabase.co/functions/v1/%FUNCTION_NAME%
echo.
>>"%LOG%" echo SUCESSO em %DATE% %TIME%
if exist "%TMP_OUT%" del /q "%TMP_OUT%" >nul 2>nul
pause
exit /b 0

:ERRO
if exist "%TMP_OUT%" del /q "%TMP_OUT%" >nul 2>nul
echo.
echo ------------------------------------------------------------
echo A JANELA VAI FICAR ABERTA.
echo Me envie a foto do erro ou o arquivo:
echo deploy_infinitepay_log.txt
echo ------------------------------------------------------------
echo.
pause
exit /b 1
