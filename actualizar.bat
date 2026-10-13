@echo off
chcp 65001 >nul
set PYTHONUTF8=1
cd /d "%~dp0"
where py >nul 2>&1 && (set PY=py -3) || (set PY=python)
echo ===== Sincronizando con GitHub =====
git pull --rebase --autostash
echo ===== Verificando desde TU red (RD): agregar.txt, check, repair, build =====
%PY% iptv.py run --no-epg
echo ===== Publicando =====
git rm --cached .env >nul 2>&1
git add -A
git diff --cached --quiet || git commit -m "local: verificacion %date% %time%"
git pull --rebase --autostash
git push
if /i not "%~1"=="auto" start "" "dist\REPORTE.html"
if /i not "%~1"=="auto" pause
