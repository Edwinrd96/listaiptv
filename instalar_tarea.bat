@echo off
chcp 65001 >nul
set PYTHONUTF8=1
cd /d "%~dp0"
where py >nul 2>&1 && (set PY=py -3) || (set PY=python)
schtasks /create /tn "IPTV Edwin" /tr "\"%~dp0actualizar.bat\" auto" /sc hourly /mo 2 /f
echo Listo: se verificara solo cada 2 horas mientras la PC este encendida.
echo Para quitarlo:  schtasks /delete /tn "IPTV Edwin" /f
pause
