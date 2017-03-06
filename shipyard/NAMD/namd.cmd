@echo off

rem You can update the recipe to 'NAMD-Infiniband-IntelMPI' for MPI jobs
set recipe=NAMD-TCP

set script_dir=%~dp0.
set powershell=C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
set python=python.exe

rem Check for Python in path
cmd /c where %python% > nul 2>&1
if %errorlevel% neq 0 (
    rem Check for Python in PYTHONPATH
    set python=%PYTHONPATH%\python.exe
    cmd /c where %python% > nul 2>&1
    if %errorlevel% neq 0 (
        echo Please install python 3.5+
        exit /b 1
    )
)

cmd /c where pip3.exe > nul 2>&1
if %errorlevel% neq 0 (
    echo Please install pip
    exit /b 1
)

cmd /c where blobxfer.exe > nul 2>&1
if %errorlevel% neq 0 (
    echo Please install blobxfer
    exit /b 1
)

if "%2" neq "" (

)

%powershell% -exec bypass -file %script_dir%\namd.ps1 -namdConfFilePath %1 -namdArgs "%2" -recipe %recipe% -poolId namd-tcp
