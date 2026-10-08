# modules/Unilyze.ps1
function Invoke-Unilyze {
    param(
        [string]$Path,
        [string]$OutputDir,
        [object]$Config = $null,
        [string]$OutputFile = "unilyze.html",
        [string]$ProjectProfile = $null
    )

    if (-not (Test-Path $Path)) {
        Write-Warning "Path not found: $Path"
        return $false
    }
    $fullPath = (Resolve-Path $Path).Path

    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }
    $resolvedOutput = (Resolve-Path $OutputDir).Path
    $outputPath = Join-Path $resolvedOutput $OutputFile
    $outputParent = Split-Path -Parent $outputPath
    if ($outputParent -and -not (Test-Path $outputParent)) {
        New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
    }

    # FIX: сначала смотрим в конфиг, потом в PATH; если нигде — понятная подсказка
    $unilyzeBin = $null
    if ($Config -and $Config.paths -and $Config.paths.unilyze) {
        $unilyzeBin = $Config.paths.unilyze
    } else {
        $cmd = Get-Command "unilyze" -ErrorAction SilentlyContinue
        if ($cmd) { $unilyzeBin = $cmd.Source }
    }

    if (-not $unilyzeBin) {
        Write-Warning "unilyze not found. Install it or add 'unilyze' to analyze-config.json -> paths.unilyze."
        return $false
    }

    if (-not (Test-Path $unilyzeBin) -and -not (Get-Command $unilyzeBin -ErrorAction SilentlyContinue)) {
        Write-Warning "unilyze binary not found at: $unilyzeBin"
        return $false
    }

    # --- Настройки шага из конфига (analyze-config.json -> unilyze) ---
    $uc = $null
    if ($Config) { $uc = $Config.unilyze }

    $emitHtml = $true
    if ($uc -and $null -ne $uc.emitHtml) { $emitHtml = [bool]$uc.emitHtml }

    # Профиль unilyze: явный из конфига важнее автоопределения профиля анализа.
    # Unity-профиль даёт role-aware пороги (MonoBehaviour/ScriptableObject/Editor)
    # и переводит LowCohesion в informational.
    $unilyzeProfile = $null
    if ($uc) { $unilyzeProfile = $uc.profile }
    if (-not $unilyzeProfile -and $ProjectProfile -eq 'unity') { $unilyzeProfile = 'unity' }

    $filterEnabled = $true
    if ($uc -and $uc.filter -and $null -ne $uc.filter.enabled) { $filterEnabled = [bool]$uc.filter.enabled }

    # --- Аргументы ---
    if ($emitHtml) {
        $toolArgs = @('-p', $fullPath, '-o', $outputPath)
    } else {
        # Без HTML: сразу JSON (быстрее, если нужен только дайджест).
        $jsonOnly = [System.IO.Path]::ChangeExtension($outputPath, '.json')
        $toolArgs = @('-p', $fullPath, '-f', 'json', '-o', $jsonOnly)
    }
    if ($unilyzeProfile) { $toolArgs += @('--profile', $unilyzeProfile) }

    Write-Host "Running Unilyze: $unilyzeBin $($toolArgs -join ' ')"
    if ($unilyzeProfile) { Write-Host "  profile: $unilyzeProfile" -ForegroundColor Gray }

    try {
        # FIX: не глушим stderr целиком — пользователь должен видеть проблемы инструмента.
        # Но unilyze пишет в stderr и информационные строки, поэтому на время вызова
        # ослабляем ErrorActionPreference, иначе analyze.ps1 (-Stop) считает это ошибкой.
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $unilyzeBin @toolArgs
            $exit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEap
        }

        if ($exit -ne 0) {
            Write-Warning "Unilyze failed with exit code: $exit"
            return $false
        }
        Write-Host "Unilyze completed successfully"
    } catch {
        Write-Error "Unilyze error: $_"
        return $false
    }

    # --- Шаг 2b: фильтр «только хуже нормы» ---
    if (-not $filterEnabled) {
        Write-Host "Unilyze filter: disabled by config" -ForegroundColor Gray
        return $true
    }
    if (-not (Get-Command Invoke-UnilyzeFilter -ErrorAction SilentlyContinue)) {
        Write-Warning "UnilyzeFilter module not loaded; skipping digest."
        return $true
    }

    $snapshotPath = [System.IO.Path]::ChangeExtension($outputPath, '.json')
    if (-not (Test-Path $snapshotPath)) {
        Write-Warning "Unilyze JSON snapshot not found: $snapshotPath (digest skipped)"
        return $true
    }

    try {
        Invoke-UnilyzeFilter -SnapshotPath $snapshotPath -OutputDir $resolvedOutput `
            -Config $Config -ProjectPath $fullPath -Profile $ProjectProfile | Out-Null
    } catch {
        Write-Warning "Unilyze filter failed: $_"
    }

    return $true
}
