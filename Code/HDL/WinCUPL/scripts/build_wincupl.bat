@echo off
setlocal

if "%~1"=="" (
  echo usage: %~nx0 source.pld [output-dir]
  exit /b 2
)

set "SOURCE=%~1"
set "OUTDIR=%~2"
if "%OUTDIR%"=="" set "OUTDIR=build\%~n1"

if not exist "%SOURCE%" (
  echo WinCUPL source not found: %SOURCE%
  exit /b 1
)

if "%CUPL%"=="" set "CUPL=cupl.exe"

if not exist "%OUTDIR%" mkdir "%OUTDIR%"

pushd "%~dp1"
"%CUPL%" %CUPLFLAGS% "%~nx1"
set "CUPL_STATUS=%ERRORLEVEL%"
popd

if not "%CUPL_STATUS%"=="0" exit /b %CUPL_STATUS%

for %%E in (jed lst doc abs so sim pin) do (
  if exist "%~dp1%~n1.%%E" copy /Y "%~dp1%~n1.%%E" "%OUTDIR%\" >nul
)

echo Generated WinCUPL output in %OUTDIR%
