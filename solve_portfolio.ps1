param(
  [Parameter(Mandatory = $true)]
  [string]$Instance,
  [string]$Output,
  [int]$TimeLimitMs = 30000
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $MyInvocation.MyCommand.Path
$model = Join-Path $workspace 'airport_sched.mzn'
$instancePath = (Resolve-Path $Instance).Path

if (-not $Output) {
  $match = [regex]::Match([IO.Path]::GetFileNameWithoutExtension($instancePath), '(\d{2})')
  $suffix = if ($match.Success) { $match.Groups[1].Value } else { 'instance' }
  $Output = Join-Path $workspace "sol\sol_$suffix.json"
}

$outputPath = [IO.Path]::GetFullPath($Output)
$scratch = Join-Path $workspace 'tmp\portfolio'
New-Item -ItemType Directory -Force $scratch | Out-Null

$solvers = @('chuffed', 'gecode', 'cp-sat')
$runs = foreach ($solver in $solvers) {
  $safeName = $solver.Replace('-', '_')
  $candidate = Join-Path $scratch "$safeName.json"
  if (Test-Path $candidate) { Clear-Content -LiteralPath $candidate }
  $arguments = "--solver $solver --time-limit $TimeLimitMs --no-output-comments " +
    "--soln-sep `" `" --search-complete-msg `" `" " +
    "--output-to-file `"$candidate`" `"$model`" `"$instancePath`""
  $process = Start-Process -FilePath minizinc -ArgumentList $arguments `
    -PassThru -WindowStyle Hidden
  [pscustomobject]@{ Solver = $solver; Candidate = $candidate; Process = $process }
}

$deadline = [DateTime]::UtcNow.AddMilliseconds($TimeLimitMs + 15000)
while ([DateTime]::UtcNow -lt $deadline -and ($runs.Process | Where-Object { -not $_.HasExited })) {
  Start-Sleep -Milliseconds 200
}
foreach ($run in $runs) {
  if (-not $run.Process.HasExited) { Stop-Process -Id $run.Process.Id -Force }
}

$solutions = foreach ($run in $runs) {
  if (-not (Test-Path $run.Candidate) -or (Get-Item $run.Candidate).Length -eq 0) { continue }
  try {
    $solution = Get-Content -Raw $run.Candidate | ConvertFrom-Json -ErrorAction Stop
    if ($null -ne $solution.cost -and [long]$solution.cost -ge 0) {
      [pscustomobject]@{
        Solver = $run.Solver
        Cost = [long]$solution.cost
        Candidate = $run.Candidate
      }
    }
  } catch { }
}

$best = $solutions | Sort-Object Cost | Select-Object -First 1
if ($null -eq $best) {
  Write-Error 'No solver produced a valid JSON solution; existing output was preserved.'
}

Copy-Item -LiteralPath $best.Candidate -Destination $outputPath -Force
Write-Output "solver=$($best.Solver) cost=$($best.Cost) output=$outputPath"
