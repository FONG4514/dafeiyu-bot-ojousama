@echo off
setlocal
cd /d "%~dp0"
set "NODE=%~dp0runtime\node.exe"
"%NODE%" "%~dp0runtime\napcat-setup.mjs" --prepare-only >nul || goto :fail
for /f "usebackq delims=" %%L in (`powershell -NoProfile -Command "$v=[Environment]::OSVersion.Version; if($v.Major -eq 10 -and $v.Build -lt 22000){'launcher-win10-user.bat'}else{'launcher-user.bat'}"`) do set "LAUNCH=%%L"
powershell -NoProfile -Command "exit ([int](-not (Test-NetConnection 127.0.0.1 -Port 3001 -InformationLevel Quiet -WarningAction SilentlyContinue)))" >nul 2>&1
if errorlevel 1 (
  start "NapCat" /d "%LOCALAPPDATA%\DaFeiYu\NapCat" cmd /c "%LAUNCH%"
  powershell -NoProfile -Command "$deadline=(Get-Date).AddSeconds(90); while((Get-Date) -lt $deadline){ if(Test-NetConnection 127.0.0.1 -Port 3001 -InformationLevel Quiet -WarningAction SilentlyContinue){ exit 0 }; Start-Sleep -Seconds 2 }; exit 1" >nul 2>&1
  if errorlevel 1 (
    echo NapCat 尚未在 3001 端口就绪。请在打开的 NapCat 窗口扫码，然后在面板点「扫码后自动读取配置」。
  )
)
"%NODE%" "%~dp0runtime\launch.mjs" client || goto :fail
exit /b 0
:fail
echo 启动失败：请确认安装完整，且已安装 Microsoft Visual C++ x64 运行库。
pause
exit /b 1
