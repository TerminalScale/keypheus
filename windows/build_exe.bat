@echo off
cd /d "%~dp0"
pip install -r requirements.txt pyinstaller
pyinstaller --onefile --noconsole --name Thock --add-data "packs;packs" thock.py
echo.
echo Done: dist\Thock.exe
