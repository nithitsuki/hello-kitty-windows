@echo off
rem Convenience launcher for hello-kitty.ps1 (no admin required)
rem Double-click  -> opens the tiny GUI wrapper (hello-kitty-gui.ps1)
rem With a command -> runs the console tool directly:
rem   hello-kitty.bat [toggle|apply|restore|on|off|status|install|themes|theme-save|savetheme|theme-restore|theme-switch]
if "%~1"=="" (
  powershell -NoProfile -Sta -ExecutionPolicy Bypass -File "%~dp0hello-kitty-gui.ps1"
) else (
  rem -Sta keeps COM calls to the native Windows theme manager on the right apartment.
  powershell -NoProfile -Sta -ExecutionPolicy Bypass -File "%~dp0hello-kitty.ps1" %*
)
