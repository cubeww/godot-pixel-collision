param([string]$Godot = 'D:\Godot\godot.exe', [switch]$SkipImport)
$ErrorActionPreference = 'Stop'
$repoPath = Split-Path -Parent $PSScriptRoot
$resultPath = Join-Path $repoPath 'test-results'
New-Item -ItemType Directory -Path $resultPath -Force | Out-Null
Set-Content -LiteralPath (Join-Path $resultPath '.gdignore') -Value '' -NoNewline
if (-not (Test-Path -LiteralPath $Godot)) { throw "Godot executable not found: $Godot" }

function Invoke-PixelGodot {
    param([string]$Name, [string[]]$Arguments)
    $outPath = Join-Path $resultPath ($Name + '.log')
    $errPath = Join-Path $resultPath ($Name + '.err')
    $process = Start-Process -FilePath $Godot -ArgumentList $Arguments -WindowStyle Hidden `
        -RedirectStandardOutput $outPath -RedirectStandardError $errPath -Wait -PassThru
    Get-Content -LiteralPath $outPath
    $errorText = Get-Content -LiteralPath $errPath -Raw
    if ($errorText) { Write-Host $errorText }
    if ($process.ExitCode -ne 0) { throw "$Name exited with code $($process.ExitCode)." }
    if ($errorText -match 'SCRIPT ERROR|Parse Error|Failed to load script|GDExtension dynamic library not found') {
        throw "$Name reported an engine/script loading error."
    }
}

$quotedProject = '"' + $repoPath + '"'
if (-not $SkipImport) {
    Invoke-PixelGodot -Name 'import' -Arguments @('--headless', '--path', $quotedProject, '--editor', '--import', '--quit')
}
Invoke-PixelGodot -Name 'integration' -Arguments @('--headless', '--path', $quotedProject, '--script', 'res://tests/godot/run_tests.gd')
$testLog = Get-Content -LiteralPath (Join-Path $resultPath 'integration.log') -Raw
if ($testLog -notmatch 'PASS') { throw 'Integration test completion was not confirmed.' }
