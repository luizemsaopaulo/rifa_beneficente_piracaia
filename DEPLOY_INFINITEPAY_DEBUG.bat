@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Rifa - Deploy InfinitePay / Supabase
cd /d "%~dp0"

set "PROJECT_REF=qzpezwscmwfznzzbrxpb"
set "FUNCTION_NAME=infinitepay-gateway"
set "LOG=%~dp0deploy_infinitepay_log.txt"
set "TMP_OUT=%TEMP%\rifa_supabase_deploy_%RANDOM%_%RANDOM%.txt"

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
echo Esta janela NAO vai fechar sozinha.
echo Tudo tambem sera salvo em:
echo %LOG%
echo.

echo [1/5] Verificando Node.js...
where node >nul 2>nul
if errorlevel 1 (
    echo.
    echo [ERRO] Node.js nao foi encontrado.
    echo O Supabase CLI via npx exige Node.js 20 ou superior.
    echo Instale o Node.js LTS e execute este BAT novamente.
    >>"%LOG%" echo [ERRO] Node.js nao encontrado.
    goto :fim_erro
)

for /f "usebackq delims=" %%V in (`node -v`) do set "NODE_VERSION=%%V"
for /f "usebackq delims=" %%M in (`node -p "process.versions.node.split('.')[0]"`) do set "NODE_MAJOR=%%M"

echo Node encontrado: !NODE_VERSION!
>>"%LOG%" echo Node: !NODE_VERSION!

if !NODE_MAJOR! LSS 20 (
    echo.
    echo [ERRO] Seu Node.js e antigo: !NODE_VERSION!
    echo O Supabase CLI atual exige Node.js 20 ou superior.
    >>"%LOG%" echo [ERRO] Node antigo: !NODE_VERSION!
    goto :fim_erro
)

echo.
echo [2/5] Verificando npx...
where npx >nul 2>nul
if errorlevel 1 (
    echo [ERRO] npx nao foi encontrado.
    echo Reinstale/atualize o Node.js LTS.
    >>"%LOG%" echo [ERRO] npx nao encontrado.
    goto :fim_erro
)
for /f "usebackq delims=" %%V in (`npx --version`) do set "NPX_VERSION=%%V"
echo npx encontrado: !NPX_VERSION!
>>"%LOG%" echo npx: !NPX_VERSION!

echo.
echo [3/5] Carregando Supabase CLI...
echo Isso pode demorar um pouco na primeira vez.
call npx -y supabase@latest --version >"%TMP_OUT%" 2>&1
set "RC=!ERRORLEVEL!"
type "%TMP_OUT%"
type "%TMP_OUT%" >>"%LOG%"
if not "!RC!"=="0" (
    echo.
    echo [ERRO] O Supabase CLI nao conseguiu iniciar.
    echo Veja o erro acima e no arquivo de log.
    goto :fim_erro
)

echo.
echo [4/5] Conferindo login no Supabase...
call npx -y supabase@latest projects list >"%TMP_OUT%" 2>&1
set "RC=!ERRORLEVEL!"
type "%TMP_OUT%"
type "%TMP_OUT%" >>"%LOG%"

if not "!RC!"=="0" (
    echo.
    echo Parece que o Supabase CLI ainda nao esta autenticado.
    echo Vou abrir o login agora.
    echo.
    >>"%LOG%" echo Login necessario. Executando supabase login...
    call npx -y supabase@latest login
    set "RC=!ERRORLEVEL!"
    >>"%LOG%" echo Resultado do login: !RC!
    if not "!RC!"=="0" (
        echo.
        echo [ERRO] O login do Supabase nao foi concluido.
        echo Execute novamente este BAT depois de concluir o login.
        goto :fim_erro
    )
)

echo.
echo [5/5] Publicando a Edge Function %FUNCTION_NAME%...
echo Projeto: %PROJECT_REF%
echo.
echo Aguarde. O modo DEBUG esta ativo para mostrar qualquer erro.
echo.

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
    echo A janela vai permanecer aberta.
    echo O erro completo esta em:
    echo %LOG%
    echo.
    echo Tire uma foto desta tela ou me envie o arquivo
    echo deploy_infinitepay_log.txt que eu corrijo o erro exato.
    goto :fim_erro
)

echo.
echo ============================================================
echo  SUCESSO
echo ============================================================
echo.
echo A funcao %FUNCTION_NAME% foi publicada.
echo Endereco esperado:
echo https://%PROJECT_REF%.supabase.co/functions/v1/%FUNCTION_NAME%
echo.
>>"%LOG%" echo SUCESSO: funcao publicada em %DATE% %TIME%
goto :fim_ok

:fim_erro
if exist "%TMP_OUT%" del /q "%TMP_OUT%" >nul 2>nul
echo.
echo ------------------------------------------------------------
echo NAO FECHE ESTA JANELA ANTES DE LER O ERRO.
echo ------------------------------------------------------------
echo.
pause
exit /b 1

:fim_ok
if exist "%TMP_OUT%" del /q "%TMP_OUT%" >nul 2>nul
echo Pressione qualquer tecla para fechar.
pause >nul
exit /b 0
