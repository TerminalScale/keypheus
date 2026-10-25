@echo off
cd /d "%~dp0"
pip install -r requirements.txt pyinstaller
pyinstaller --onefile --noconsole --name Keypheus --add-data "packs;packs" keypheus.py
echo.
echo Done: dist\Keypheus.exe
