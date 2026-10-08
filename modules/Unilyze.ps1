# modules/Unilyze.ps1

function Get-UnilyzeScopeExcludes {
    <#
        .SYNOPSIS
        Считает список --exclude-dir, сужающий анализ unilyze до указанной папки.

        .DESCRIPTION
        unilyze ищет .csproj вверх по дереву от -p и, найдя его, анализирует ВЕСЬ
        проект, а не указанную папку: при запуске в подпапке в отчёт попадают типы
        со всего дерева. Функция находит ближайший .csproj и возвращает всех
        «соседей» на каждом уровне от корня проекта до целевой папки — их и надо
        передать в --exclude-dir (пути относительны корня проекта, как того требует
        unilyze).

        Если .csproj выше нет (Unity-проект, просто папка с .cs), unilyze сам
        ограничивается указанной папкой, и исключения не нужны. Один .sln без
        .csproj анализ всего дерева не включает, поэтому корнем считается только
        папка с .csproj.

        .OUTPUTS
        Объект: Root (корень проекта или $null), Excludes (список путей), Levels.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $result = [pscustomobject]@{
        Root     = $null
        Excludes = @()
        Levels   = 0
    }

    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    $target = (Get-Item -LiteralPath $Path).FullName

    # 1. Ближайшая папка с .csproj вверх по дереву
    $projectRoot = $null
    $probe = $target
    while ($probe) {
        if (@(Get-ChildItem -LiteralPath $probe -File -Filter *.csproj -ErrorAction SilentlyContinue).Count -gt 0) {
            $projectRoot = $probe
            break
        }
        $parent = Split-Path -Parent $probe
        if (-not $parent -or $parent -eq $probe) { break }
        $probe = $parent
    }

    if (-not $projectRoot) { return $result }
    $result.Root = $projectRoot
    if ($projectRoot -eq $target) { return $result }   # запуск из корня проекта — сужать нечего

    # 2. Все «соседи» на каждом уровне от корня проекта до целевой папки
    $relative = $target.Substring($projectRoot.Length).Trim('\', '/')
    $segments = @($relative -split '[\\/]' | Where-Object { $_ })
    $excludes = New-Object System.Collections.Generic.List[string]
    $current = $projectRoot
    foreach ($segment in $segments) {
        Get-ChildItem -LiteralPath $current -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne $segment -and $_.Name -notin 'bin', 'obj' -and -not $_.Name.StartsWith('.') } |
            ForEach-Object { [void]$excludes.Add($_.FullName.Substring($projectRoot.Length).Trim('\', '/')) }
        $current = Join-Path $current $segment
    }

    $result.Excludes = $excludes.ToArray()
    $result.Levels = $segments.Count
    return $result
}

function Invoke-Unilyze {
    param(
        [string]$Path,
        [string]$OutputDir,
        [object]$Config = $null,
        [string]$OutputFile = "unilyze.html",
        [string]$ProjectProfile = $null,
        [switch]$FromRoot
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

    # --- Сужение области анализа ---
    # По умолчанию отчёт описывает только указанную папку: без этого unilyze,
    # найдя .csproj выше, анализирует весь проект. -FromRoot возвращает прежнее
    # поведение (анализ от корня проекта).
    $scope = $null
    if (-not $FromRoot) {
        $scope = Get-UnilyzeScopeExcludes -Path $fullPath
        if ($scope.Root -and $scope.Excludes.Count -gt 0) {
            foreach ($dir in $scope.Excludes) { $toolArgs += @('--exclude-dir', $dir) }
        }
    }

    # В консоль не выводим все --exclude-dir: их бывает несколько десятков.
    $shownArgs = New-Object System.Collections.Generic.List[string]
    $skipNext = $false
    foreach ($arg in $toolArgs) {
        if ($skipNext) { $skipNext = $false; continue }
        if ($arg -eq '--exclude-dir') { $skipNext = $true; continue }
        [void]$shownArgs.Add($arg)
    }
    $scopeNote = ''
    if ($scope -and $scope.Excludes.Count -gt 0) { $scopeNote = " +$($scope.Excludes.Count) --exclude-dir" }

    Write-Host "Running Unilyze: $unilyzeBin $($shownArgs -join ' ')$scopeNote"
    if ($FromRoot) {
        Write-Host "  scope: весь проект (-FromRoot)" -ForegroundColor Gray
    } elseif ($scope -and $scope.Excludes.Count -gt 0) {
        Write-Host "  scope: только $fullPath (корень проекта: $($scope.Root), исключено каталогов: $($scope.Excludes.Count))" -ForegroundColor Gray
    } elseif ($scope -and $scope.Root) {
        Write-Host "  scope: корень проекта ($($scope.Root)) — сужать нечего" -ForegroundColor Gray
    } else {
        Write-Host "  scope: .csproj выше не найден — unilyze ограничится указанной папкой" -ForegroundColor Gray
    }
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
