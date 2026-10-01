# modules/Gitingest.ps1
function ConvertTo-WslPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return "" }
    $Path = $Path.Trim('"').Trim()
    $winPath = $Path -replace "\\", "/"
    if ($winPath -match "^([a-zA-Z]):/(.*)$") {
        return "/mnt/$($Matches[1].ToLower())/$($Matches[2])"
    }
    if ($winPath -match "^/mnt/") { return $winPath }
    return $winPath
}

# FIX: экранирование одинарных кавычек для bash
function ConvertTo-BashSingleQuoted {
    param([string]$Value)
    if ($null -eq $Value) { return "''" }
    return "'" + ($Value -replace "'", "'\''") + "'"
}

function Invoke-Gitingest {
    param(
        [string]$Path,
        [string]$OutputDir,
        [string[]]$Excludes = @(),
        [object]$Config = $null
    )

    # FIX: Resolve-Path внутри проверки, чтобы не кидало исключение
    if (-not (Test-Path $Path)) {
        Write-Warning "Path not found: $Path"
        return $false
    }
    $fullPath = (Resolve-Path $Path).Path

    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }
    $resolvedOutput = (Resolve-Path $OutputDir).Path

    if (-not $Config -or -not $Config.paths -or [string]::IsNullOrEmpty($Config.paths.gitingest)) {
        Write-Warning "gitingest not configured. Run setup.ps1 first."
        return $false
    }

    $gitingestBin = $Config.paths.gitingest
    $tempDir      = $Config.paths.tempDir
    if (-not (Test-Path $tempDir)) {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }

    $wslProject = ConvertTo-WslPath -Path $fullPath
    $wslTemp    = ConvertTo-WslPath -Path $tempDir
    $wslOutFile = "$wslTemp/gitingest.txt"

    # .gitingestignore
    $ignoreFilePath = Join-Path $fullPath ".gitingestignore"
    $createdIgnore  = $false
    if (-not (Test-Path $ignoreFilePath) -and $Excludes.Count -gt 0) {
        # FIX: без BOM — gitingest может не понять BOM в ignore-файле
        [System.IO.File]::WriteAllLines($ignoreFilePath, $Excludes, [System.Text.UTF8Encoding]::new($false))
        $createdIgnore = $true
    }

    try {
        # FIX: безопасное экранирование путей
        $cmd = "cd $(ConvertTo-BashSingleQuoted $wslProject) && $(ConvertTo-BashSingleQuoted $gitingestBin) . -o $(ConvertTo-BashSingleQuoted $wslOutFile)"
        Write-Host "Running: wsl bash -c $cmd"
        wsl bash -c "$cmd"
        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0) {
            Write-Warning "gitingest failed with exit code: $exitCode"
            return $false
        }

        $src = Join-Path $tempDir "gitingest.txt"
        if (-not (Test-Path $src)) {
            Write-Warning "gitingest output not created at $src"
            return $false
        }

        Copy-Item $src $resolvedOutput -Force
        Write-Host "gitingest completed successfully"
        return $true
    } catch {
        Write-Error "gitingest error: $_"
        return $false
    } finally {
        # FIX: удаляем временный ignore-файл, чтобы не засорять репозиторий
        if ($createdIgnore -and (Test-Path $ignoreFilePath)) {
            Remove-Item $ignoreFilePath -Force -ErrorAction SilentlyContinue
            Write-Host "Temporary .gitingestignore removed"
        }
    }
}