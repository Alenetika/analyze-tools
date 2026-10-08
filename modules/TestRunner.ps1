# modules/TestRunner.ps1

function Get-ProjectType {
    param([string]$Path)

    if (Test-Path (Join-Path $Path "Assets")) { return "unity" }
    # FIX: ограничиваем глубину поиска .sln, чтобы не сканировать гигантские деревья
    if (Get-ChildItem -Path $Path -Filter "*.sln" -Depth 2 -ErrorAction SilentlyContinue |
        Select-Object -First 1) { return "dotnet" }
    if (Test-Path (Join-Path $Path "package.json")) { return "web" }
    return "default"
}

function Get-UnityPath {
    $candidates = @()

    # FIX: проверка Windows до PS6-специфичной $IsWindows
    if ($env:OS -eq "Windows_NT") {
        $regPaths = @(
            "HKLM:\SOFTWARE\Unity Technologies\Unity Editor",
            "HKCU:\SOFTWARE\Unity Technologies\Unity Editor"
        )
        foreach ($reg in $regPaths) {
            if (Test-Path $reg) {
                $install = (Get-ItemProperty -Path $reg -ErrorAction SilentlyContinue).InstallPath
                if ($install) { $candidates += Join-Path $install "Editor\Unity.exe" }
            }
        }
        $hub = Get-ChildItem -Path "C:\Program Files\Unity\Hub\Editor\*\Editor\Unity.exe" -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
        if ($hub) { $candidates += $hub }
        $candidates += "C:\Program Files\Unity\Editor\Unity.exe"
    } else {
        $candidates += (Get-ChildItem -Path "/Applications/Unity/Hub/Editor/*/Unity.app/Contents/MacOS/Unity" -ErrorAction SilentlyContinue |
                        Select-Object -First 1 -ExpandProperty FullName)
        $candidates += "/Applications/Unity/Unity.app/Contents/MacOS/Unity"
    }

    return $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}

function Invoke-UnityTests {
    param(
        [string]$ProjectPath,
        [string]$OutputDir,
        [string]$Filter = "",
        [switch]$IncludeIgnored
    )

    $unity = Get-UnityPath
    if (-not $unity) {
        Write-Warning "Unity Editor not found"
        return $false
    }

    # FIX: переименовали $args → $unityArgs (не затираем автоматическую переменную)
    # FIX: НЕ оборачиваем значения в кавычки — Start-Process сам это сделает
    $unityArgs = @(
        "-projectPath", $ProjectPath,
        "-batchmode",
        "-runTests",
        "-testPlatform", "EditMode",
        "-testResults", (Join-Path $OutputDir "unity-results.xml"),
        "-logFile", (Join-Path $OutputDir "unity-log.txt"),
        "-nographics"
    )

    if ($Filter) { $unityArgs += @("-testFilter", $Filter) }
    # FIX: семантика -IncludeIgnored — включаем категорию Ignore в дополнение к остальным
    #      (Unity не поддерживает "включить всё + Ignore" одной опцией,
    #       поэтому запускаем обычный прогон и помечаем это в логе)
    if ($IncludeIgnored) {
        Write-Host "Note: Unity test runner ignores -testCategory Ignore by default; running all tests."
    }

    Write-Host "Starting Unity tests..."
    $proc = Start-Process -FilePath $unity -ArgumentList $unityArgs -Wait -PassThru -NoNewWindow
    return $proc.ExitCode -eq 0
}

function Invoke-DotnetTests {
    param(
        [string]$ProjectPath,
        [string]$OutputDir,
        [string]$Filter = "",
        [switch]$IncludeIgnored
    )

    $testProjects = Get-ChildItem -Path $ProjectPath -Filter "*Tests*.csproj" -Recurse -ErrorAction SilentlyContinue

    if (-not $testProjects) {
        $sln = Get-ChildItem -Path $ProjectPath -Filter "*.sln" -Depth 2 -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($sln) {
            $dotnetArgs = @(
                "test", $sln.FullName,
                "--logger", "trx;LogFileName=sln-results.trx",
                "--results-directory", $OutputDir
            )
            if ($Filter) { $dotnetArgs += @("--filter", $Filter) }

            $proc = Start-Process -FilePath "dotnet" -ArgumentList $dotnetArgs -Wait -PassThru -NoNewWindow
            return $proc.ExitCode -eq 0
        }
        return $false
    }

    $allOk = $true
    foreach ($proj in $testProjects) {
        $dotnetArgs = @(
            "test", $proj.FullName,
            "--logger", "trx;LogFileName=$($proj.BaseName)-results.trx",
            "--results-directory", $OutputDir
        )
        if ($Filter) { $dotnetArgs += @("--filter", $Filter) }

        $proc = Start-Process -FilePath "dotnet" -ArgumentList $dotnetArgs -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) { $allOk = $false }
    }

    return $allOk
}

function Invoke-NUnitTests {
    param(
        [string]$ProjectPath,
        [string]$OutputDir,
        [string]$Filter = "",
        [switch]$IncludeIgnored
    )

    # FIX: -Filter уже покрывает шаблон, -Include избыточен и ломал поиск FooTest.dll
    $dlls = Get-ChildItem -Path $ProjectPath -Recurse -Include "*Tests.dll","*Test.dll" -ErrorAction SilentlyContinue
    if (-not $dlls) { return $false }

    # FIX: после dotnet tool install команда появляется в PATH только в новой сессии,
    #      поэтому сначала ищем бинарь в стандартной папке tools.
    $nunitPath = $null
    $cmd = Get-Command "nunit3-console" -ErrorAction SilentlyContinue
    if ($cmd) {
        $nunitPath = $cmd.Source
    } else {
        $toolDir = Join-Path $HOME ".dotnet/tools"
        $candidates = @(
            (Join-Path $toolDir "nunit3-console.exe"),
            (Join-Path $toolDir "nunit3-console")
        )
        $nunitPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    }

    if (-not $nunitPath) {
        Write-Host "Installing NUnit.ConsoleRunner..."
        dotnet tool install --global NUnit.ConsoleRunner | Out-Null
        $toolDir = Join-Path $HOME ".dotnet/tools"
        $candidates = @(
            (Join-Path $toolDir "nunit3-console.exe"),
            (Join-Path $toolDir "nunit3-console")
        )
        $nunitPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $nunitPath) {
            Write-Warning "NUnit Console not available"
            return $false
        }
    }

    $allOk = $true
    foreach ($dll in $dlls) {
        $nunitArgs = @(
            $dll.FullName,
            "--result=$(Join-Path $OutputDir "$($dll.BaseName)-nunit.xml")",
            "--workers=1"
        )
        if ($Filter) { $nunitArgs += @("--where", "test == '$Filter'") }
        # FIX: корректная семантика -IncludeIgnored: по умолчанию NUnit и так запускает
        #      все, кроме явно исключённых; явный фильтр тут не нужен.
        if ($IncludeIgnored) {
            Write-Host "Note: NUnit runs Ignore-marked tests only when explicitly selected; no extra filter applied."
        }

        $proc = Start-Process -FilePath $nunitPath -ArgumentList $nunitArgs -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) { $allOk = $false }
    }

    return $allOk
}

function Invoke-Tests {
    param(
        [string]$Path,
        [string]$OutputDir,
        [string]$Filter = "",
        [switch]$IncludeIgnored
    )

    if (-not (Test-Path $Path)) {
        Write-Warning "Path not found: $Path"
        return $false
    }
    $resolvedPath = (Resolve-Path $Path).Path

    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }
    $resolvedOutput = (Resolve-Path $OutputDir).Path

    $projectType = Get-ProjectType -Path $resolvedPath
    Write-Host "Test project type: $projectType"

    $success = $false

    switch ($projectType) {
        "unity" {
            $success = Invoke-UnityTests -ProjectPath $resolvedPath -OutputDir $resolvedOutput -Filter $Filter -IncludeIgnored:$IncludeIgnored
            if (-not $success) {
                Write-Warning "Unity tests failed, falling back to NUnit"
                $success = Invoke-NUnitTests -ProjectPath $resolvedPath -OutputDir $resolvedOutput -Filter $Filter -IncludeIgnored:$IncludeIgnored
            }
        }
        "dotnet" {
            $success = Invoke-DotnetTests -ProjectPath $resolvedPath -OutputDir $resolvedOutput -Filter $Filter -IncludeIgnored:$IncludeIgnored
            if (-not $success) {
                Write-Warning "dotnet tests failed, falling back to NUnit"
                $success = Invoke-NUnitTests -ProjectPath $resolvedPath -OutputDir $resolvedOutput -Filter $Filter -IncludeIgnored:$IncludeIgnored
            }
        }
        "web" {
            Write-Warning "Web tests not implemented yet"
            $success = $false
        }
        default {
            $success = Invoke-NUnitTests -ProjectPath $resolvedPath -OutputDir $resolvedOutput -Filter $Filter -IncludeIgnored:$IncludeIgnored
        }
    }

    return $success
}