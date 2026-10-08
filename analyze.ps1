# analyze.ps1

param(
    [string]$Path = ".",
    [string]$OutDir = ".",
    [string]$Token = $env:GITHUB_TOKEN,   # зарезервировано под будущее использование
    [string]$Profile = "auto",
    [switch]$FromRoot,
    [switch]$IncludeIgnored,
    [switch]$SkipSetup
)

$ErrorActionPreference = "Stop"

# --- Директория САМОГО скрипта ---
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptDir = (Resolve-Path $scriptDir).Path

$modulePath = Join-Path $scriptDir "modules"
$configPath = Join-Path $scriptDir "analyze-config.json"
$setupPath  = Join-Path $scriptDir "setup.ps1"

# --- Автозапуск setup.ps1, если конфига нет ---
if (-not (Test-Path $configPath) -and (Test-Path $setupPath) -and -not $SkipSetup) {
    Write-Host "Config not found. Running setup.ps1..." -ForegroundColor Yellow
    & $setupPath
    if ($LASTEXITCODE -ne 0) {
        Write-Error "setup.ps1 failed with exit code $LASTEXITCODE"
        exit 1
    }
}

if (-not (Test-Path $modulePath)) {
    Write-Error "Modules directory not found: $modulePath"
    exit 1
}

# --- Dot-source модулей: функции становятся доступны в текущей сессии ---
$moduleFiles = @("UnilyzeFilter.ps1", "Gitingest.ps1", "Unilyze.ps1", "TestRunner.ps1")
foreach ($mf in $moduleFiles) {
    $full = Join-Path $modulePath $mf
    if (-not (Test-Path $full)) {
        Write-Error "Module file not found: $full"
        exit 1
    }
    try {
        . $full
    } catch {
        Write-Error "Failed to load module ${mf}: $_"
        exit 1
    }
}

# --- Загрузка конфига ---
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    Write-Host "Config not found, using defaults" -ForegroundColor Yellow
    $config = [pscustomobject]@{
        defaultExcludes = @(".idea/*", ".vs/*", ".vscode/*", ".git/*", "bin/*", "obj/*", "node_modules/*")
        profiles        = [pscustomobject]@{}
        paths           = [pscustomobject]@{ tempDir = (Join-Path $scriptDir "Temp") }
    }
}

# --- Нормализация пути ДО определения профиля ---
if ($Path -eq ".") { $Path = (Get-Location).Path }
try {
    $fullPath = (Resolve-Path $Path -ErrorAction Stop).Path
} catch {
    Write-Error "Cannot resolve path: $Path"
    exit 1
}

if ($OutDir -eq ".") { $OutDir = $fullPath }
if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}
$outDirPath = (Resolve-Path $OutDir).Path

# --- Профиль ---
if ($Profile -eq "auto") {
    $Profile = Get-ProjectType -Path $fullPath
}

# --- Сбор excludes ---
$excludes = @()
if ($config.defaultExcludes) { $excludes += @($config.defaultExcludes) }
if ($config.profiles) {
    $profileNode = $config.profiles.PSObject.Properties[$Profile]
    if ($profileNode -and $profileNode.Value.excludes) {
        $excludes += @($profileNode.Value.excludes)
    }
}
$excludes = @($excludes | Where-Object { $_ } | Select-Object -Unique)

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Analysis started" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Path: $fullPath"
Write-Host "Profile: $Profile"
Write-Host "Scope: $(if ($FromRoot) { 'весь проект (от корня проекта)' } else { 'только указанная папка' })"
Write-Host "Output: $outDirPath"
Write-Host "Excludes: $($excludes.Count) pattern(s)"
Write-Host ""

# --- Шаг 1: Gitingest ---
Write-Host ">> Step 1/3: Running Gitingest" -ForegroundColor Yellow
$gitingestSuccess = Invoke-Gitingest -Path $fullPath -OutputDir $outDirPath -Excludes $excludes -Config $config
Write-Host ""

# --- Шаг 2: Unilyze ---
# Unilyze работает с любым проектом, где есть C#-скрипты, а не только с Unity.
# Профиль анализа ('unity') включает role-aware пороги unilyze.
Write-Host ">> Step 2/3: Running Unilyze" -ForegroundColor Yellow
$unilyzeSuccess = Invoke-Unilyze -Path $fullPath -OutputDir $outDirPath -Config $config -ProjectProfile $Profile -FromRoot:$FromRoot
Write-Host ""

# --- Шаг 3: Tests ---
Write-Host ">> Step 3/3: Running Tests" -ForegroundColor Yellow
Write-Host "Project type: $Profile" -ForegroundColor Gray
$testSuccess = Invoke-Tests -Path $fullPath -OutputDir $outDirPath -IncludeIgnored:$IncludeIgnored
Write-Host ""

# --- Итоговый отчёт ---
$gitingestStatus = if ($gitingestSuccess) { 'Success' } else { 'Failed' }
$unilyzeStatus   = if ($unilyzeSuccess)   { 'Success' } else { 'Failed' }
$testStatus      = if ($testSuccess)      { 'Success' } else { 'Failed' }

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Analysis completed" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Gitingest: $gitingestStatus"
Write-Host "Unilyze:   $unilyzeStatus"
Write-Host "Tests:     $testStatus"
Write-Host ""
Write-Host "Output directory: $outDirPath"
Write-Host "  - gitingest.txt"
Write-Host "  - unilyze.html"
Write-Host "  - unilyze.json        (full snapshot)"
Write-Host "  - unilyze-flags.json  (only worse than norm)"
Write-Host "  - unilyze-flags.md    (same, human readable)"
if ($Profile -eq "unity") {
    Write-Host "  - unity-results.xml (или *-nunit.xml при fallback)"
    Write-Host "  - unity-log.txt"
} elseif ($Profile -eq "dotnet") {
    Write-Host "  - *-results.trx (или *-nunit.xml при fallback)"
} else {
    Write-Host "  - *-nunit.xml (если найдены тесты)"
}
Write-Host ""

if ($gitingestSuccess -and $unilyzeSuccess -and $testSuccess) {
    Write-Host "All steps completed successfully" -ForegroundColor Green
    exit 0
} else {
    Write-Host "Some steps failed" -ForegroundColor Red
    exit 1
}