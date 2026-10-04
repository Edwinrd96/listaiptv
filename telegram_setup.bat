@echo off
chcp 65001 >nul
set PYTHONUTF8=1
cd /d "%~dp0"
where py >nul 2>&1 && (set PY=py -3) || (set PY=python)
set /p TOKEN=Pega el token de tu bot (el que te dio @BotFather): 
%PY% iptv.py telegram setup --token "%TOKEN%"
pause
