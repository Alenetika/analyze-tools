# setup.ps1
param(
    [switch]$Force   # перезаписать analyze-config.json
)

$ErrorActionPreference = "Stop"

function Write-Ok   { param($m) Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn2{ param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err2 { param($m) Write-Host "[x] $m" -ForegroundColor Red }

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptDir  = (Resolve-Path $scriptDir).Path
$configPath = Join-Path $scriptDir "analyze-config.json"
$tempDir    = Join-Path $scriptDir "Temp"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Setup: gitingest + unilyze" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Script dir: $scriptDir"
Write-Host ""

# --- 1. WSL доступен? ---
if (-not (Get-Command "wsl" -ErrorAction SilentlyContinue)) {
    Write-Err2 "WSL not found. Install: wsl --install"
    exit 1
}

$probe = (wsl bash -lc "echo ok" 2>$null) -join "`n"
if ($probe.Trim() -ne "ok") {
    Write-Err2 "WSL is present but bash does not run. Check: wsl --status"
    exit 1
}

# --- 2. Ищем gitingest в WSL ---
# ВАРИАНТ B: -ic (interactive) читает ~/.bashrc → conda активируется → PATH корректный
$gitingestRaw = (wsl bash -ic "command -v gitingest 2>/dev/null" 2>$null) -join "`n"
$gitingestPath = ($gitingestRaw -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
if ($gitingestPath) { $gitingestPath = $gitingestPath.Trim() }

if ([string]::IsNullOrEmpty($gitingestPath) -or $gitingestPath -match 'not found') {
    Write-Err2 "gitingest not found in WSL."
    Write-Host "    Install manually:  wsl bash -ic 'pip install --user gitingest'" -ForegroundColor Gray
    exit 1
}
Write-Ok "gitingest: $gitingestPath"

# --- 2b. Ищем unilyze (сначала в WSL, потом в Windows PATH) ---
$unilyzePath = $null
$unilyzeRaw = (wsl bash -ic "command -v unilyze 2>/dev/null" 2>$null) -join "`n"
$unilyzeWsl = ($unilyzeRaw -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
if ($unilyzeWsl) { $unilyzeWsl = $unilyzeWsl.Trim() }

if ($unilyzeWsl -and $unilyzeWsl -notmatch 'not found') {
    $unilyzePath = $unilyzeWsl
} else {
    $cmd = Get-Command "unilyze" -ErrorAction SilentlyContinue
    if ($cmd) { $unilyzePath = $cmd.Source }
}

if ($unilyzePath) {
    Write-Ok "unilyze: $unilyzePath"
} else {
    Write-Warn2 "unilyze not found. Unilyze step will be skipped."
    Write-Host "    Install it or add to PATH, then re-run setup.ps1, or set 'paths.unilyze' manually." -ForegroundColor Gray
}

# --- 3. Temp dir ---
if (-not (Test-Path $tempDir)) {
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
}

# --- 4. Конфиг ---
$pathsSection = [ordered]@{
    tempDir   = $tempDir
    gitingest = $gitingestPath
    unilyze   = if ($unilyzePath) { $unilyzePath } else { "" }
}

$defaultConfig = [ordered]@{
    defaultExcludes = @(
        "**.idea/*","**.vs/*","**.vscode/*","**.git/*","**bin/*","**obj/*",
        "**node_modules/*","**.ttf","**gitingest.txt","**.gitingestignore",
        "**unilyze.html","**unilyze.json","**.testsession"
    )
    profiles = [ordered]@{
        unity  = @{ excludes = @(
            "*Library/*","*Temp/*","*Logs/*","*Build/*","Assets/TextMesh Pro",
            "*packages-lock.json","*ProjectSettings/*","**.unity","**.meta",
            "**.mat","**.cginc","**.shader","*.asset","UserSettings/*"
        )}
        dotnet = @{ excludes = @("bin/*","obj/*","packages/*") }
        web    = @{ excludes = @("node_modules/*","dist/*","build/*",".next/*","out/*") }
    }
    paths = $pathsSection
}

if ((Test-Path $configPath) -and -not $Force) {
    try {
        $existing = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        # Прямое присваивание надёжнее Add-Member -Force
        $existing.paths = [pscustomobject]$pathsSection
        $json = $existing | ConvertTo-Json -Depth 20
        # Без BOM — сторонние JSON-парсеры спотыкаются о BOM
        [System.IO.File]::WriteAllText($configPath, $json, [System.Text.UTF8Encoding]::new($false))
        Write-Ok "Updated 'paths' in existing config"
    } catch {
        Write-Err2 "Failed to update config: $_"
        exit 1
    }
} else {
    $json = $defaultConfig | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($configPath, $json, [System.Text.UTF8Encoding]::new($false))
    Write-Ok "Config written: $configPath"
}

# --- 5. Итог ---
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Setup completed" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Config:    $configPath"
Write-Host "Temp dir:  $tempDir"
Write-Host "gitingest: $gitingestPath"
if ($unilyzePath) {
    Write-Host "unilyze:   $unilyzePath"
} else {
    Write-Host "unilyze:   (not found — Unilyze step will be skipped)" -ForegroundColor Yellow
}
Write-Host ""
exit 0