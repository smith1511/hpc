@echo off

rem set recipe=NAMD-TCP
set recipe=NAMD-Infiniband-IntelMPI

set script_dir=%~dp0.
set shipyard_dir=%script_dir%\shipyard
set shipyard=%shipyard_dir%\shipyard.py
set python_dir=%shipyard_dir%\Python35
set python=%python_dir%\python.exe
set config_dir=%shipyard_dir%\recipes\%recipe%\config
set powershell=C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe

cmd /c where blobxfer.exe > nul 2>&1
if %errorlevel% neq 0 set PATH="%python_dir%;%python_dir%\Scripts;%PATH%"

%powershell% -exec bypass -file %script_dir%\shipyard.ps1 -namdConfFilePath %1 -namdArgs "%2" -recipe %recipe%
