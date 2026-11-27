@echo off
title Arcane Wilds - Spell & Combo Editor
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0editor\server.ps1" -ModDir "%~dp0."
if errorlevel 1 (
    echo.
    echo Editor server exited with an error.
    pause
)
