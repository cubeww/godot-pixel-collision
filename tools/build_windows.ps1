param([string]$Configuration = 'Release', [switch]$CoreOnly)
$ErrorActionPreference = 'Stop'
$repoPath = Split-Path -Parent $PSScriptRoot
$cmakeCommand = Get-Command cmake -ErrorAction SilentlyContinue
$cmakePath = if ($cmakeCommand) { $cmakeCommand.Source } else { 'C:\Program Files\CMake\bin\cmake.exe' }
if (-not (Test-Path -LiteralPath $cmakePath)) { throw 'CMake 3.21 or newer is required.' }
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio C++ Build Tools and vswhere are required.' }
$vsPath = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) { throw 'No Visual Studio installation with the C++ toolchain was found.' }
$vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'
$buildPath = Join-Path $repoPath 'build'
$extension = if ($CoreOnly) { 'OFF' } else { 'ON' }
# A generated command file keeps quoting and the MSVC environment in one shell.
New-Item -ItemType Directory -Path $buildPath -Force | Out-Null
$commandPath = Join-Path $buildPath 'build-local.cmd'
$ctestPath = Join-Path (Split-Path $cmakePath) 'ctest.exe'
$lines = @(
    '@echo off',
    ('call "' + $vcvars + '"'),
    'if errorlevel 1 exit /b %errorlevel%',
    ('"' + $cmakePath + '" -S "' + $repoPath + '" -B "' + $buildPath + '" -G "NMake Makefiles" -DCMAKE_BUILD_TYPE=' + $Configuration + ' -DPIXEL_COLLISION_BUILD_EXTENSION=' + $extension),
    'if errorlevel 1 exit /b %errorlevel%',
    ('"' + $cmakePath + '" --build "' + $buildPath + '"'),
    'if errorlevel 1 exit /b %errorlevel%',
    ('"' + $ctestPath + '" --test-dir "' + $buildPath + '" --output-on-failure'),
    'exit /b %errorlevel%'
)
Set-Content -LiteralPath $commandPath -Value $lines -Encoding ASCII
& $env:ComSpec /d /c $commandPath
if ($LASTEXITCODE -ne 0) { throw "Build or tests failed with exit code $LASTEXITCODE." }
