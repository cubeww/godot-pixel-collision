param(
    [string]$Godot = "godot",
    [ValidateRange(10, 600)]
    [int]$TimeoutSeconds = 90
)

$ErrorActionPreference = "Stop"
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "../..")).Path
$addonSource = Join-Path $repositoryRoot "addons/pixel_collision"
$binaryPath = Join-Path $addonSource "bin/pixel_collision.windows.x86_64.dll"
if (-not (Test-Path -LiteralPath $binaryPath)) {
    throw "Build the Windows extension before running editor tests: $binaryPath"
}

$godotCommand = Get-Command -Name $Godot -CommandType Application -ErrorAction Stop
$workspace = Join-Path ([System.IO.Path]::GetTempPath()) ("godot-pixel-collision-editor-" + [guid]::NewGuid().ToString("N"))
$addonsDirectory = Join-Path $workspace "addons"
$probeDirectory = Join-Path $addonsDirectory "editor_tests"
New-Item -ItemType Directory -Path $probeDirectory -Force | Out-Null
Copy-Item -LiteralPath $addonSource -Destination $addonsDirectory -Recurse
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "plugin.cfg") -Destination $probeDirectory
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "run_editor_tests.gd") -Destination $probeDirectory
Set-Content -LiteralPath (Join-Path $workspace "project.godot") -Encoding UTF8 -Value @'
config_version=5

[application]
config/name="Pixel Collision Editor Tests"

[rendering]
renderer/rendering_method="gl_compatibility"

[editor_plugins]
enabled=PackedStringArray("res://addons/pixel_collision/plugin.cfg", "res://addons/editor_tests/plugin.cfg")
'@

$stdoutPath = Join-Path $workspace "stdout.log"
$stderrPath = Join-Path $workspace "stderr.log"
Write-Output "Isolated editor test project and logs: $workspace"
$arguments = @("--headless", "--editor", "--path", ('"' + $workspace + '"'))
$process = Start-Process -FilePath $godotCommand.Source -ArgumentList $arguments -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
    $process.Kill()
    $process.WaitForExit()
    throw "Editor tests timed out after $TimeoutSeconds seconds. Logs remain at $workspace"
}
# Refresh retrieves ExitCode reliably after WaitForExit on Windows PowerShell.
$process.Refresh()
$stdout = Get-Content -LiteralPath $stdoutPath -Raw
$stderr = Get-Content -LiteralPath $stderrPath -Raw
Write-Output $stdout
if (-not [string]::IsNullOrWhiteSpace($stderr)) {
    Write-Output $stderr
}
if ($process.ExitCode -ne 0 -or $stdout -notmatch "EDITOR TESTS: 65 assertions, 0 failures") {
    throw "Editor tests failed (exit $($process.ExitCode)). Logs remain at $workspace"
}
Write-Output "Editor integration tests passed. Temporary artifacts are retained at $workspace"
