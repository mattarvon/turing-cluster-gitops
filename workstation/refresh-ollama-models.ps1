# Re-pull every installed Ollama model so library rebuilds land automatically.
# Runs weekly from Task Scheduler on the workstation (task "Ollama model refresh").
# Only refreshes tags that already exist; new model families are a human decision.
# Custom tags (no registry.ollama.ai manifest) are skipped, they can't be refreshed.
#
# Register:  .\refresh-ollama-models.ps1 -Register
# Run now:   .\refresh-ollama-models.ps1
param([switch]$Register)

$ErrorActionPreference = 'Continue'
$log = Join-Path $env:LOCALAPPDATA 'Ollama\refresh.log'
New-Item -ItemType Directory -Force (Split-Path $log) | Out-Null

if ($Register) {
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
               -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 4am
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable `
                -ExecutionTimeLimit (New-TimeSpan -Hours 3)
    Register-ScheduledTask -TaskName 'Ollama model refresh' -Action $action -Trigger $trigger `
        -Settings $settings -Description 'ollama pull for every installed library tag' -Force | Out-Null
    "registered: Sundays 04:00"
    return
}

"=== $(Get-Date -Format s) ===" | Tee-Object -Append $log
$models = (Invoke-RestMethod http://localhost:11434/api/tags).models.name
foreach ($m in $models) {
    $manifest = Join-Path $env:OLLAMA_MODELS "manifests\registry.ollama.ai\library\$($m -replace ':','\')"
    if (-not (Test-Path $manifest)) { "skip $m (custom tag)" | Tee-Object -Append $log; continue }
    $before = (Get-Content $manifest -Raw).GetHashCode()
    & ollama pull $m 2>&1 | Out-Null
    $after = (Get-Content $manifest -Raw).GetHashCode()
    $state = if ($before -ne $after) { 'UPDATED' } else { 'current' }
    "$state  $m" | Tee-Object -Append $log
}
& ollama list 2>&1 | Tee-Object -Append $log
