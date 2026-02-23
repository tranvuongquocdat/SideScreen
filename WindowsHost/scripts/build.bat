@echo off
setlocal

echo === SideScreen Windows Host Build ===
echo.

:: Check for CMake
where cmake >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: CMake not found. Please install CMake 3.20+.
    exit /b 1
)

:: Check for Visual Studio
if not defined VSINSTALLDIR (
    echo Looking for Visual Studio...
    if exist "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" (
        call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
    ) else if exist "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat" (
        call "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat"
    ) else if exist "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat" (
        call "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat"
    ) else (
        echo WARNING: Visual Studio 2022 not found. CMake will try to auto-detect.
    )
)

:: Configure
echo Configuring with CMake...
cmake -B build -G "Visual Studio 17 2022" -A x64 %*
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: CMake configure failed.
    exit /b 1
)

:: Build
echo.
echo Building Release...
cmake --build build --config Release
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Build failed.
    exit /b 1
)

echo.
echo === Build successful! ===
echo Output: build\Release\SideScreen.exe
