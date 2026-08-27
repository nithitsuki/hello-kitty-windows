@echo off
rem Convenience launcher for hello-kitty.ps1 (no admin required)
rem Usage: hello-kitty.bat [toggle|apply|restore|on|off|status|install|themes|theme-save|theme-restore|theme-switch]
rem -Sta keeps COM calls to the native Windows theme manager on the right apartment.
powershell -NoProfile -Sta -ExecutionPolicy Bypass -File "%~dp0hello-kitty.ps1" %*