param(
    [string]$Executable,
    [ValidateRange(1, 1000000)][int]$Frames = 3000,
    [ValidateRange(0, 1000000)][int]$Warmup = 300,
    [ValidateRange(1, 20)][int]$Repeats = 3,
    [string]$Fixture = ''
)
$ErrorActionPreference = 'Stop'
$repoPath = Split-Path -Parent $PSScriptRoot
if (-not $Executable) { $Executable = Join-Path $repoPath 'build/export/pixel_collision.exe' }
$Executable = (Resolve-Path -LiteralPath $Executable).Path
$resultPath = Join-Path $repoPath 'test-results/benchmarks'
New-Item -ItemType Directory -Path $resultPath -Force | Out-Null
Set-Content -LiteralPath (Join-Path (Split-Path $resultPath) '.gdignore') -Value '' -NoNewline
$summary = @()
foreach ($mode in @('settled', 'burst')) {
    for ($iteration = 1; $iteration -le $Repeats; $iteration++) {
        $name = "$mode-scalar-$iteration"
        $output = Join-Path $resultPath ($name + '.json')
        $arguments = @('--', '--benchmark', "--$mode",
            "--frames=$Frames", "--warmup=$Warmup", ('"--output=' + $output + '"'))
        if ($Fixture) { $arguments += ('"--fixture=' + (Resolve-Path -LiteralPath $Fixture).Path + '"') }
        Write-Host "Running rendered benchmark: $name"
        $process = Start-Process -FilePath $Executable -ArgumentList $arguments -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $resultPath ($name + '.log')) `
            -RedirectStandardError (Join-Path $resultPath ($name + '.err')) -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "$name failed with exit code $($process.ExitCode)." }
        $errors = Get-Content -LiteralPath (Join-Path $resultPath ($name + '.err')) -Raw
        if ($errors -match 'SCRIPT ERROR|ERROR:') { throw "$name reported an engine error: $errors" }
        $result = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
        if ($result.headless -or $result.measured_frames -ne $Frames -or $result.particles -ne 800 -or $result.query_mode -ne 'scalar') {
            throw "$name did not complete the expected rendered workload."
        }
        $summary += [pscustomobject]@{
            Run = $name
            FPS = [math]::Round($result.mean_fps, 1)
            FrameMS = [math]::Round($result.frame.mean_ms, 3)
            P95MS = [math]::Round($result.frame.p95_ms, 3)
            WorkMS = [math]::Round($result.collision_and_update_work.mean_ms, 3)
            Queries = $result.query_count
        }
    }
}
$summary | Format-Table -AutoSize
Write-Host "Raw timing reports: $resultPath"
