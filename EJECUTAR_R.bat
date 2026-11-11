@echo off
title Recomendador RBM - corrida en R
cd /d "%~dp0"
set "RS="
for /f "delims=" %%i in ('where Rscript 2^>nul') do if not defined RS set "RS=%%i"
if not defined RS for /d %%d in ("%ProgramFiles%\R\R-*") do if exist "%%d\bin\Rscript.exe" set "RS=%%d\bin\Rscript.exe"
if not defined RS (
  echo No se encontro R. Instalelo desde https://cran.r-project.org
  pause
  exit /b 1
)
"%RS%" "R\ejecutar.R" %*
pause
