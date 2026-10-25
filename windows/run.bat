@echo off
cd /d "%~dp0"
pip show keyboard >nul 2>&1
if errorlevel 1 (
    pip install -r requirements.txt
)
start "" pythonw keypheus.py
