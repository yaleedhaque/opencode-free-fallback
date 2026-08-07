# verify-chain.ps1 - Model-churn guard.
# The Zen/OpenRouter free model lists rotate monthly. This diffs the installed
# fallback chain against the live `opencode models` catalog and reports:
#   1) chain models that no longer exist (stale -> remove/replace)
#   2) free-tier models in the catalog that are NOT in the chain (new candidates)
# Run manually:  powershell -File ...\verify-chain.ps1
# Optionally schedule: schtasks /Create /TN opencode-chain-verify /SC WEEKLY /D FRI /ST 09:00 /TR "powershell ..."

$ErrorActionPreference = "Stop"
$ConfigDir = Join-Path $env:USERPROFILE ".config\opencode"
$FallbackConfig = Join-Path $ConfigDir "opencode-fallback.jsonc"
$Log = Join-Path $ConfigDir "warp-rotate\chain-report.log"

function Write-Log([string]$Msg) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Msg" | Out-File -FilePath $Log -Append -Encoding utf8
}

if (-not (Test-Path $FallbackConfig)) { Write-Host "opencode-fallback.jsonc not found at $FallbackConfig" -ForegroundColor Red; exit 1 }

function Get-FallbackModels([string]$Path) {
    $raw = Get-Content $Path -Raw
    $m = [regex]::Match($raw, '"fallback_models"\s*:\s*\[(.*?)\]', 'Singleline')
    if (-not $m.Success) { return @() }
    $ids = [regex]::Matches($m.Groups[1].Value, '"([^"]+)"')
    return @($ids | ForEach-Object { $_.Groups[1].Value })
}

$chain = @(Get-FallbackModels $FallbackConfig)

if ($chain.Count -eq 0) {
    $msg = "=== FALLBACK CHAIN VERIFICATION ===`nSTRICT MODE - fallback_models is empty (big-pickle only, no model switching). Nothing to verify. To enable a chain, add models to opencode-fallback.jsonc."
    Write-Host $msg
    $msg | Out-File -FilePath $Log -Append -Encoding utf8
    exit 0
}

$modelsRaw = @(opencode models 2>$null)
$modelSet = @{}
foreach ($line in $modelsRaw) {
    $id = $line.Trim()
    if ($id) { $modelSet[$id] = $true }
}

$report = @()
$report += "=== FALLBACK CHAIN VERIFICATION ==="
$report += "checked $($chain.Count) chain models against live catalog"
$report += ""

$missing = @($chain | Where-Object { -not $modelSet.ContainsKey($_) })
if ($missing.Count -gt 0) {
    $report += "MISSING / STALE MODELS (remove or replace these in opencode-fallback.jsonc):"
    $missing | ForEach-Object { $report += "  - $_" }
} else {
    $report += "ALL chain models present in current catalog - OK"
}

$report += ""
$report += "FREE MODELS IN CATALOG NOT IN CHAIN (possible new additions):"
$candidates = @($modelsRaw |
    Where-Object { $_ -match '(hy3|(-|:)free)' -and -not ($chain -contains $_.Trim()) } |
    ForEach-Object { $_.Trim() } | Sort-Object -Unique)
if ($candidates.Count -gt 0) { $candidates | ForEach-Object { $report += "  - $_" } } else { $report += "  none" }

$report += ""
$report += "=== END (full log: $Log) ==="

$report | ForEach-Object { Write-Host $_ }
$report | Out-File -FilePath $Log -Append -Encoding utf8
