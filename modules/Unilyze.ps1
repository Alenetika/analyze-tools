# modules/Unilyze.ps1
function Invoke-Unilyze {
    param(
        [string]$Path,
        [string]$OutputDir,
        [object]$Config = $null,
        [string]$OutputFile = "unilyze.html"
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

    Write-Host "Running Unilyze: $unilyzeBin"

    try {
        # FIX: не глушим stderr целиком — пользователь должен видеть проблемы инструмента
        & $unilyzeBin -p "$fullPath" -o "$outputPath"
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Unilyze completed successfully"
            return $true
        }
        Write-Warning "Unilyze failed with exit code: $LASTEXITCODE"
        return $false
    } catch {
        Write-Error "Unilyze error: $_"
        return $false
    }
}