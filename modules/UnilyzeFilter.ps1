# modules/UnilyzeFilter.ps1
#
# Фильтр вывода unilyze.
#
# Идея: полный JSON-снимок unilyze содержит ВСЁ — включая типы и находки,
# которые в пределах нормы (healthy, informational, уже подавленные baseline /
# inline-комментариями, признанные false-positive). Для LLM и для чтения глазами
# это шум. Модуль читает снимок и пишет компактный дайджест: остаётся только то,
# что ХУЖЕ НОРМЫ, плюс причины, по которым каждый тип туда попал.
#
# Источники «хуже нормы» (-Mode, по умолчанию smell):
#   smell  — вердикты самого unilyze (typeMetrics[].codeSmells[]), кроме
#            suppressed / baselined / triage=false-positive|wontfix.
#            Ничего не додумывается: проект уже настроен через .unilyze.json,
#            --baseline и inline-директивы, и мы это уважаем.
#   metric — независимый пересчёт сырых метрик по порогам (`unilyze metrics`).
#            Полезно, когда хочется проверить «сырые» значения, не доверяя
#            конфигурации проекта. Осторожно: включает проверки, которые проект
#            мог осознанно отключить.
#   both   — smell + metric. Находки, уже подавленные (в т.ч. inline),
#            отключённые правилом UNIxxx=off или относящиеся к profile-зависимым
#            видам под unity, повторно НЕ добавляются.
#
# Пороги берутся из:
#   a) встроенных значений unilyze (docs/metrics.md / `unilyze metrics`);
#   b) `<project>/.unilyze.json` -> smells (то, что реально применяет инструмент);
#   c) analyze-config.json -> unilyze.filter.thresholds (приоритет выше).
#
# Совместимость: Windows PowerShell 5.1+.

$script:UnilyzeSmellRules = [ordered]@{
    GodClass                        = 'UNI001'
    LongMethod                      = 'UNI002'
    ExcessiveParameters             = 'UNI003'
    HighComplexity                  = 'UNI004'
    DeepNesting                     = 'UNI005'
    LowCohesion                     = 'UNI006'
    HighCoupling                    = 'UNI007'
    LowMaintainability              = 'UNI008'
    CyclicDependency                = 'UNI009'
    DeepInheritance                 = 'UNI010'
    BoxingAllocation                = 'UNI011'
    ClosureCapture                  = 'UNI012'
    ParamsArrayAllocation           = 'UNI013'
    CatchAllException               = 'UNI014'
    MissingInnerException           = 'UNI015'
    ThrowingSystemException         = 'UNI016'
    ExpensiveUnityApiInHotPath      = 'UNI017'
    LinqInHotPath                   = 'UNI018'
    CollectionAllocationInHotPath   = 'UNI019'
    StringConcatenationInHotPath    = 'UNI020'
    WeakTemporization               = 'UNI021'
    AsyncVoidMethod                 = 'UNI022'
    BlockingTaskWait                = 'UNI023'
    MissingBurstCompile             = 'UNI024'
    ManagedReferenceInComponentData = 'UNI025'
}

function Get-UnilyzeProp {
    param(
        [object]$Object,
        [string]$Name,
        $Default = $null
    )
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    if ($null -eq $p.Value) { return $Default }
    return $p.Value
}

function Get-UnilyzeSeverityRank {
    param([string]$Severity)
    if ($Severity -eq 'Critical') { return 2 }
    if ($Severity -eq 'Warning') { return 1 }
    return 0
}

function Get-UnilyzeWorstSeverity {
    param([object[]]$Severities)
    $rank = 0
    foreach ($s in $Severities) {
        $r = Get-UnilyzeSeverityRank -Severity $s
        if ($r -gt $rank) { $rank = $r }
    }
    if ($rank -ge 2) { return 'Critical' }
    if ($rank -eq 1) { return 'Warning' }
    return 'Info'
}

function Get-UnilyzeSmellRule {
    param([string]$Kind)
    if ($Kind -and $script:UnilyzeSmellRules.Contains($Kind)) {
        return $script:UnilyzeSmellRules[$Kind]
    }
    return $null
}

function Get-UnilyzeRuleKind {
    param([string]$Rule)
    if (-not $Rule) { return $null }
    foreach ($k in $script:UnilyzeSmellRules.Keys) {
        if ($script:UnilyzeSmellRules[$k] -eq $Rule) { return $k }
    }
    return $null
}

# PowerShell 5.1 печатает JSON с отступами (ключ -Compress появился в 6+).
# Для больших снимков отступы дают мегабайты шума, поэтому минифицируем сами:
# убираем незначащие пробелы/переводы строк вне строковых литералов.
function Compress-UnilyzeJson {
    param([string]$Json)

    $sb = New-Object System.Text.StringBuilder ($Json.Length)
    $inString = $false
    $escaped = $false
    foreach ($ch in $Json.ToCharArray()) {
        if ($inString) {
            [void]$sb.Append($ch)
            if ($escaped) { $escaped = $false }
            elseif ($ch -eq '\') { $escaped = $true }
            elseif ($ch -eq '"') { $inString = $false }
            continue
        }
        if ($ch -eq '"') { $inString = $true; [void]$sb.Append($ch); continue }
        if ($ch -eq ' ' -or $ch -eq "`t" -or $ch -eq "`r" -or $ch -eq "`n") { continue }
        [void]$sb.Append($ch)
    }
    return $sb.ToString()
}

# Убирает свойства со значением $null: компактнее и не мешает чтению.
function Remove-UnilyzeNullProperty {
    param([object]$Object)
    if ($null -eq $Object) { return $null }
    foreach ($p in @($Object.PSObject.Properties)) {
        if ($null -eq $p.Value) { $Object.PSObject.Properties.Remove($p.Name) }
    }
    return $Object
}

function Get-UnilyzeSortedObject {
    param([hashtable]$Table)
    $o = [ordered]@{}
    foreach ($k in ($Table.Keys | Sort-Object)) { $o[$k] = $Table[$k] }
    return [pscustomobject]$o
}

# ---------------------------------------------------------------------------
# Пороги
# ---------------------------------------------------------------------------

function Get-UnilyzeDefaultThresholds {
    # Значения из `unilyze metrics` / docs/metrics.md (default profile).
    # Ключ = "<SmellKind>.<param>" — тот же вид, что в .unilyze.json -> smells.
    return @{
        'CodeHealth.warningBelow'   = 9.0
        'CodeHealth.alertBelow'     = 4.0

        'GodClass.lines'            = 500.0
        'GodClass.methods'          = 20.0
        'GodClass.criticalLines'    = 1000.0

        'LongMethod.lines'          = 80.0
        'LongMethod.cogCc'          = 25.0
        'LongMethod.criticalLines'  = 150.0
        'LongMethod.criticalCogCc'  = 40.0

        'HighComplexity.cycCc'      = 15.0
        'HighComplexity.cogCc'      = 15.0

        'DeepNesting.depth'         = 4.0
        'DeepNesting.criticalDepth' = 6.0

        'ExcessiveParameters.max'   = 5.0

        'LowCohesion.lcom'          = 0.8

        'HighCoupling.cbo'          = 15.0
        'HighCoupling.criticalCbo'  = 25.0

        'DeepInheritance.dit'       = 5.0

        'LowMaintainability.mi'     = 60.0
    }
}

function Merge-UnilyzeThresholdNode {
    param(
        [hashtable]$Table,
        [object]$Node,
        [string]$Prefix = ''
    )
    if ($null -eq $Node) { return }
    foreach ($p in $Node.PSObject.Properties) {
        $key = $p.Name
        if ($Prefix -ne '') { $key = "$Prefix.$($p.Name)" }
        $v = $p.Value
        if ($null -eq $v) { continue }
        if ($v -is [System.Management.Automation.PSCustomObject]) {
            Merge-UnilyzeThresholdNode -Table $Table -Node $v -Prefix $key
        } elseif ($v -is [bool] -or $v -is [string]) {
            continue   # строковые значения (например "off") в порогах не участвуют
        } else {
            $Table[$key] = [double]$v
        }
    }
}

function Get-UnilyzeThresholdValue {
    param([hashtable]$Table, [string]$Key, [double]$Default)
    if ($Table.ContainsKey($Key)) { return [double]$Table[$Key] }
    return $Default
}

function Get-UnilyzeThresholds {
    <#
      Собирает пороги и «правила проекта»: какие виды находок проект отключил
      (rules UNIxxx = off), какой профиль заявлен и т.п. Это нужно, чтобы
      metric-режим не спорил с осознанной конфигурацией проекта.
    #>
    param(
        [object]$Config = $null,
        [string]$ProjectPath = $null,
        [string]$Profile = $null,
        [object]$Override = $null   # .unilyze.json, уже разобранный вызывающим кодом
    )

    $table = Get-UnilyzeDefaultThresholds
    $sources = @('unilyze defaults (docs/metrics.md)')
    $disabledKinds = New-Object System.Collections.ArrayList
    $explicitKinds = New-Object System.Collections.ArrayList
    $effectiveProfile = $Profile

    # Проектный конфиг: либо переданный в памяти (превью из UI), либо с диска.
    $j = $null
    if ($Override) {
        $j = $Override
        $sources += '.unilyze.json (передан в памяти)'
    } elseif ($ProjectPath) {
        $projCfg = Join-Path $ProjectPath '.unilyze.json'
        if (Test-Path $projCfg) {
            try {
                $j = Get-Content $projCfg -Raw -Encoding UTF8 | ConvertFrom-Json
            } catch {
                Write-Warning "UnilyzeFilter: не удалось прочитать $projCfg : $_"
            }
        }
    }

    if ($j) {
        $smells = Get-UnilyzeProp -Object $j -Name 'smells'
        if ($smells) {
            Merge-UnilyzeThresholdNode -Table $table -Node $smells
            $sources += '.unilyze.json -> smells'
        }

        if (-not $effectiveProfile) {
            $p = Get-UnilyzeProp -Object $j -Name 'profile'
            if ($p) { $effectiveProfile = [string]$p }
        }

        $rules = Get-UnilyzeProp -Object $j -Name 'rules'
        if ($rules) {
            foreach ($p in $rules.PSObject.Properties) {
                if ("$($p.Value)".ToLowerInvariant() -eq 'off') {
                    $kind = Get-UnilyzeRuleKind -Rule $p.Name
                    if (-not $kind -and $script:UnilyzeSmellRules.Contains($p.Name)) { $kind = $p.Name }
                    if ($kind) { [void]$disabledKinds.Add($kind) }
                }
            }
            if ($disabledKinds.Count -gt 0) {
                $sources += ".unilyze.json -> rules off ($($disabledKinds -join ', '))"
            }
        }
    }

    if ($Config) {
        $u = Get-UnilyzeProp -Object $Config -Name 'unilyze'
        if ($u) {
            if (-not $effectiveProfile) {
                $p = Get-UnilyzeProp -Object $u -Name 'profile'
                if ($p) { $effectiveProfile = [string]$p }
            }
            $f = Get-UnilyzeProp -Object $u -Name 'filter'
            if ($f) {
                $t = Get-UnilyzeProp -Object $f -Name 'thresholds'
                if ($t) {
                    Merge-UnilyzeThresholdNode -Table $table -Node $t
                    # Явно заданный здесь порог — последнее слово: он возвращает
                    # проверку вида в строй, даже если проект отключил её правилом.
                    foreach ($p in $t.PSObject.Properties) { [void]$explicitKinds.Add($p.Name) }
                    $sources += 'analyze-config.json -> unilyze.filter.thresholds'
                }
                if (-not $effectiveProfile) {
                    $p = Get-UnilyzeProp -Object $f -Name 'profile'
                    if ($p) { $effectiveProfile = [string]$p }
                }
            }
        }
    }

    if ($effectiveProfile) { $sources += "profile=$effectiveProfile" }

    return [pscustomobject]@{
        Values        = $table
        Sources       = $sources
        DisabledKinds = @($disabledKinds)
        ExplicitKinds = @($explicitKinds)
        Profile       = $effectiveProfile
    }
}

# ---------------------------------------------------------------------------
# Разбор находок
# ---------------------------------------------------------------------------

function Test-UnilyzeSmellKept {
    param(
        [object]$Smell,
        [hashtable]$Options
    )

    if ((Get-UnilyzeProp -Object $Smell -Name 'suppressed' -Default $false) -and -not $Options.IncludeSuppressed) {
        return 'suppressed'
    }
    if ((Get-UnilyzeProp -Object $Smell -Name 'baselined' -Default $false) -and -not $Options.IncludeBaselined) {
        return 'baselined'
    }
    $triage = Get-UnilyzeProp -Object $Smell -Name 'triage'
    if ($triage -and -not $Options.IncludeTriage) {
        if ($triage -eq 'false-positive' -or $triage -eq 'wontfix') { return 'triage' }
    }
    if ((Get-UnilyzeSeverityRank -Severity (Get-UnilyzeProp -Object $Smell -Name 'severity')) -lt (Get-UnilyzeSeverityRank -Severity $Options.MinSeverity)) {
        return 'severity'
    }
    return 'kept'
}

function New-UnilyzeReason {
    param(
        [string]$Source,
        [string]$Kind,
        [string]$Severity,
        [string]$Message,
        [string]$Rule = $null,
        [string]$Metric = $null,
        $Value = $null,
        $Threshold = $null,
        [string]$MethodName = $null,
        $Line = $null,
        [string]$Fingerprint = $null
    )
    $o = [ordered]@{
        source   = $Source
        severity = $Severity
    }
    if ($Rule)          { $o.rule   = $Rule }
    if ($Kind)          { $o.kind   = $Kind }
    if ($Metric)        { $o.metric = $Metric }
    if ($null -ne $Value)     { $o.value     = $Value }
    if ($null -ne $Threshold) { $o.threshold = $Threshold }
    if ($MethodName)    { $o.method = $MethodName }
    if ($null -ne $Line) { $o.line  = $Line }
    if ($Fingerprint)   { $o.fingerprint = $Fingerprint }
    if ($Message)       { $o.message = $Message }
    return [pscustomobject]$o
}

# Пересчёт сырых метрик типа/методов по порогам (режим metric / both).
function Get-UnilyzeMetricViolations {
    param(
        [object]$Type,
        [hashtable]$Thresholds,
        [string[]]$SkipKinds
    )

    $violations = New-Object System.Collections.ArrayList
    $skip = @{}
    foreach ($k in $SkipKinds) { if ($k) { $skip[$k] = $true } }

    $lineCount   = [double](Get-UnilyzeProp -Object $Type -Name 'lineCount' -Default 0)
    $methodCount = [double](Get-UnilyzeProp -Object $Type -Name 'methodCount' -Default 0)
    $lcom        = Get-UnilyzeProp -Object $Type -Name 'lcom'
    $cbo         = Get-UnilyzeProp -Object $Type -Name 'cbo'
    $dit         = Get-UnilyzeProp -Object $Type -Name 'dit'

    # --- GodClass (type level) ---
    if (-not $skip.ContainsKey('GodClass')) {
        $gcLines     = Get-UnilyzeThresholdValue -Table $Thresholds -Key 'GodClass.lines' -Default 500
        $gcMethods   = Get-UnilyzeThresholdValue -Table $Thresholds -Key 'GodClass.methods' -Default 20
        $gcCritLines = Get-UnilyzeThresholdValue -Table $Thresholds -Key 'GodClass.criticalLines' -Default 1000
        if ($lineCount -ge $gcLines -or $methodCount -ge $gcMethods) {
            $sev = 'Warning'
            if ($lineCount -ge $gcCritLines) { $sev = 'Critical' }
            $metric = 'lineCount'; $value = $lineCount; $threshold = $gcLines
            if ($lineCount -lt $gcLines) { $metric = 'methodCount'; $value = $methodCount; $threshold = $gcMethods }
            $msg = "$([int]$lineCount) lines / $([int]$methodCount) methods (GodClass threshold: $([int]$gcLines) lines or $([int]$gcMethods) methods)"
            [void]$violations.Add((New-UnilyzeReason -Source 'metric' -Kind 'GodClass' -Severity $sev -Rule (Get-UnilyzeSmellRule 'GodClass') -Metric $metric -Value $value -Threshold $threshold -Message $msg))
        }
    }

    # --- LowCohesion (type level) ---
    if (-not $skip.ContainsKey('LowCohesion')) {
        $lcLcom = Get-UnilyzeThresholdValue -Table $Thresholds -Key 'LowCohesion.lcom' -Default 0.8
        if ($null -ne $lcom -and [double]$lcom -ge $lcLcom) {
            [void]$violations.Add((New-UnilyzeReason -Source 'metric' -Kind 'LowCohesion' -Severity 'Warning' -Rule (Get-UnilyzeSmellRule 'LowCohesion') -Metric 'lcom' -Value ([double]$lcom) -Threshold $lcLcom -Message ("LCOM {0:N2} (threshold: {1:N2})" -f ([double]$lcom), $lcLcom)))
        }
    }

    # --- HighCoupling (type level) ---
    if (-not $skip.ContainsKey('HighCoupling')) {
        $hcCbo  = Get-UnilyzeThresholdValue -Table $Thresholds -Key 'HighCoupling.cbo' -Default 15
        $hcCrit = Get-UnilyzeThresholdValue -Table $Thresholds -Key 'HighCoupling.criticalCbo' -Default 25
        if ($null -ne $cbo -and [double]$cbo -ge $hcCbo) {
            $sev = 'Warning'
            if ([double]$cbo -ge $hcCrit) { $sev = 'Critical' }
            [void]$violations.Add((New-UnilyzeReason -Source 'metric' -Kind 'HighCoupling' -Severity $sev -Rule (Get-UnilyzeSmellRule 'HighCoupling') -Metric 'cbo' -Value ([double]$cbo) -Threshold $hcCbo -Message ("CBO {0} (threshold: {1})" -f ([int]$cbo), [int]$hcCbo)))
        }
    }

    # --- DeepInheritance (type level) ---
    if (-not $skip.ContainsKey('DeepInheritance')) {
        $diDit = Get-UnilyzeThresholdValue -Table $Thresholds -Key 'DeepInheritance.dit' -Default 5
        if ($null -ne $dit -and [double]$dit -ge $diDit) {
            [void]$violations.Add((New-UnilyzeReason -Source 'metric' -Kind 'DeepInheritance' -Severity 'Warning' -Rule (Get-UnilyzeSmellRule 'DeepInheritance') -Metric 'dit' -Value ([double]$dit) -Threshold $diDit -Message ("DIT {0} (threshold: {1})" -f ([int]$dit), [int]$diDit)))
        }
    }

    # --- Per-method ---
    $lmLines = Get-UnilyzeThresholdValue -Table $Thresholds -Key 'LongMethod.lines' -Default 80
    $lmCog   = Get-UnilyzeThresholdValue -Table $Thresholds -Key 'LongMethod.cogCc' -Default 25
    $lmCLine = Get-UnilyzeThresholdValue -Table $Thresholds -Key 'LongMethod.criticalLines' -Default 150
    $lmCCog  = Get-UnilyzeThresholdValue -Table $Thresholds -Key 'LongMethod.criticalCogCc' -Default 40
    $hcxCyc  = Get-UnilyzeThresholdValue -Table $Thresholds -Key 'HighComplexity.cycCc' -Default 15
    $hcxCog  = Get-UnilyzeThresholdValue -Table $Thresholds -Key 'HighComplexity.cogCc' -Default 15
    $dnDepth = Get-UnilyzeThresholdValue -Table $Thresholds -Key 'DeepNesting.depth' -Default 4
    $dnCrit  = Get-UnilyzeThresholdValue -Table $Thresholds -Key 'DeepNesting.criticalDepth' -Default 6
    $epMax   = Get-UnilyzeThresholdValue -Table $Thresholds -Key 'ExcessiveParameters.max' -Default 5
    $miMin   = Get-UnilyzeThresholdValue -Table $Thresholds -Key 'LowMaintainability.mi' -Default 60

    $methods = Get-UnilyzeProp -Object $Type -Name 'methods'
    if ($methods) {
        foreach ($m in $methods) {
            $mName  = [string](Get-UnilyzeProp -Object $m -Name 'methodName' -Default '?')
            $mLine  = Get-UnilyzeProp -Object $m -Name 'startLine'
            $mLoc   = [double](Get-UnilyzeProp -Object $m -Name 'lineCount' -Default 0)
            $mCog   = [double](Get-UnilyzeProp -Object $m -Name 'cognitiveComplexity' -Default 0)
            $mCyc   = [double](Get-UnilyzeProp -Object $m -Name 'cyclomaticComplexity' -Default 0)
            $mNest  = [double](Get-UnilyzeProp -Object $m -Name 'maxNestingDepth' -Default 0)
            $mParam = [double](Get-UnilyzeProp -Object $m -Name 'parameterCount' -Default 0)
            $mMi    = Get-UnilyzeProp -Object $m -Name 'maintainabilityIndex'

            if ((-not $skip.ContainsKey('LongMethod')) -and ($mLoc -ge $lmLines -or $mCog -ge $lmCog)) {
                $sev = 'Warning'
                if ($mLoc -ge $lmCLine -or $mCog -ge $lmCCog) { $sev = 'Critical' }
                $metric = 'lineCount'; $value = $mLoc; $threshold = $lmLines
                if ($mLoc -lt $lmLines) { $metric = 'cogCc'; $value = $mCog; $threshold = $lmCog }
                $msg = "$([int]$mLoc) lines / CogCC $([int]$mCog) (LongMethod threshold: $([int]$lmLines) lines or CogCC $([int]$lmCog))"
                [void]$violations.Add((New-UnilyzeReason -Source 'metric' -Kind 'LongMethod' -Severity $sev -Rule (Get-UnilyzeSmellRule 'LongMethod') -Metric $metric -Value $value -Threshold $threshold -MethodName $mName -Line $mLine -Message $msg))
            }

            if ((-not $skip.ContainsKey('HighComplexity')) -and ($mCyc -ge $hcxCyc -or $mCog -ge $hcxCog)) {
                $metric = 'cycCc'; $value = $mCyc; $threshold = $hcxCyc
                if ($mCyc -lt $hcxCyc) { $metric = 'cogCc'; $value = $mCog; $threshold = $hcxCog }
                $msg = "CycCC $([int]$mCyc) / CogCC $([int]$mCog) (threshold: $([int]$hcxCyc))"
                [void]$violations.Add((New-UnilyzeReason -Source 'metric' -Kind 'HighComplexity' -Severity 'Warning' -Rule (Get-UnilyzeSmellRule 'HighComplexity') -Metric $metric -Value $value -Threshold $threshold -MethodName $mName -Line $mLine -Message $msg))
            }

            if ((-not $skip.ContainsKey('DeepNesting')) -and $mNest -ge $dnDepth) {
                $sev = 'Warning'
                if ($mNest -ge $dnCrit) { $sev = 'Critical' }
                [void]$violations.Add((New-UnilyzeReason -Source 'metric' -Kind 'DeepNesting' -Severity $sev -Rule (Get-UnilyzeSmellRule 'DeepNesting') -Metric 'maxNestingDepth' -Value $mNest -Threshold $dnDepth -MethodName $mName -Line $mLine -Message ("nesting depth {0} (threshold: {1})" -f [int]$mNest, [int]$dnDepth)))
            }

            if ((-not $skip.ContainsKey('ExcessiveParameters')) -and $mParam -gt $epMax) {
                [void]$violations.Add((New-UnilyzeReason -Source 'metric' -Kind 'ExcessiveParameters' -Severity 'Warning' -Rule (Get-UnilyzeSmellRule 'ExcessiveParameters') -Metric 'parameterCount' -Value $mParam -Threshold $epMax -MethodName $mName -Line $mLine -Message ("{0} parameters (threshold: {1})" -f [int]$mParam, [int]$epMax)))
            }

            if ((-not $skip.ContainsKey('LowMaintainability')) -and $null -ne $mMi -and [double]$mMi -lt $miMin) {
                [void]$violations.Add((New-UnilyzeReason -Source 'metric' -Kind 'LowMaintainability' -Severity 'Warning' -Rule (Get-UnilyzeSmellRule 'LowMaintainability') -Metric 'maintainabilityIndex' -Value ([double]$mMi) -Threshold $miMin -MethodName $mName -Line $mLine -Message ("MI {0:N1} (threshold: < {1:N0})" -f ([double]$mMi), $miMin)))
            }
        }
    }

    return $violations
}

# ---------------------------------------------------------------------------
# Основная обработка снимка
# ---------------------------------------------------------------------------

function Get-UnilyzeFindings {
    param(
        [object]$Snapshot,
        [object]$ThresholdInfo,
        [hashtable]$Options
    )

    $Types_ = Get-UnilyzeProp -Object $Snapshot -Name 'typeMetrics'
    if (-not $Types_) { $Types_ = @() }

    $counters = @{
        smellsTotal       = 0
        smellsKept        = 0
        smellsCritical    = 0
        smellsWarning     = 0
        droppedSuppressed = 0
        droppedBaselined  = 0
        droppedTriage     = 0
        droppedSeverity   = 0
        droppedSource     = 0
        droppedIgnored    = 0
        metricViolations  = 0
        informational     = 0
        byKind            = @{}
    }

    # Виды, которые metric-режим не должен переоткрывать: отключённые правилами
    # проекта и выключенные в ignoreKinds. Явный порог из analyze-config.json
    # сильнее проектного "off", а profile-зависимые виды (unity) не трогаем,
    # пока порог не задан явно.
    $metricSkip = New-Object System.Collections.ArrayList
    foreach ($k in $Options.IgnoreKinds) { [void]$metricSkip.Add($k) }
    foreach ($k in $ThresholdInfo.DisabledKinds) {
        if ($ThresholdInfo.ExplicitKinds -notcontains $k) { [void]$metricSkip.Add($k) }
    }
    if ($ThresholdInfo.Profile -eq 'unity') {
        # В unity-профиле GodClass имеет role-aware пороги, а LowCohesion
        # намеренно понижен до informational — не переоткрываем их сырыми порогами.
        if ($ThresholdInfo.ExplicitKinds -notcontains 'GodClass')    { [void]$metricSkip.Add('GodClass') }
        if ($ThresholdInfo.ExplicitKinds -notcontains 'LowCohesion') { [void]$metricSkip.Add('LowCohesion') }
    }
    $minRank = Get-UnilyzeSeverityRank -Severity $Options.MinSeverity

    $flagged = New-Object System.Collections.ArrayList
    $totalHealth = 0.0
    $healthCount = 0
    $minHealth = $null

    foreach ($type in $Types_) {
        $health = Get-UnilyzeProp -Object $type -Name 'codeHealth'
        if ($null -ne $health) {
            $totalHealth += [double]$health
            $healthCount++
            if ($null -eq $minHealth -or [double]$health -lt $minHealth) { $minHealth = [double]$health }
        }
        $info = Get-UnilyzeProp -Object $type -Name 'informationalCount'
        if ($info) { $counters.informational += [int]$info }

        $reasons = New-Object System.Collections.ArrayList
        $keptSmells = New-Object System.Collections.ArrayList
        $allSmellKeys = @{}   # ВСЕ находки, включая подавленные: чтобы metric их не дублировал

        $rawSmells = Get-UnilyzeProp -Object $type -Name 'codeSmells'
        if ($rawSmells) {
            foreach ($s in $rawSmells) {
                $counters.smellsTotal++
                $kind = [string](Get-UnilyzeProp -Object $s -Name 'kind')
                $mName = [string](Get-UnilyzeProp -Object $s -Name 'methodName')
                $allSmellKeys["$kind|$mName"] = $true

                if ($Options.IgnoreKinds -contains $kind) { $counters.droppedIgnored++; continue }

                if (-not ($Options.Sources -contains 'smell')) { $counters.droppedSource++; continue }

                $verdict = Test-UnilyzeSmellKept -Smell $s -Options $Options
                if ($verdict -ne 'kept') {
                    switch ($verdict) {
                        'suppressed' { $counters.droppedSuppressed++ }
                        'baselined'  { $counters.droppedBaselined++ }
                        'triage'     { $counters.droppedTriage++ }
                        'severity'   { $counters.droppedSeverity++ }
                    }
                    continue
                }

                $sev = [string](Get-UnilyzeProp -Object $s -Name 'severity' -Default 'Warning')
                $counters.smellsKept++
                if ($sev -eq 'Critical') { $counters.smellsCritical++ } else { $counters.smellsWarning++ }
                if ($kind) {
                    if (-not $counters.byKind.ContainsKey($kind)) { $counters.byKind[$kind] = 0 }
                    $counters.byKind[$kind]++
                }

                [void]$keptSmells.Add($s)
                [void]$reasons.Add((New-UnilyzeReason -Source 'smell' -Kind $kind -Severity $sev -Rule (Get-UnilyzeSmellRule $kind) -Message ([string](Get-UnilyzeProp -Object $s -Name 'message')) -MethodName $mName -Line (Get-UnilyzeProp -Object $s -Name 'line') -Fingerprint ([string](Get-UnilyzeProp -Object $s -Name 'id'))))
            }
        }

        # --- metric scan ---
        if ($Options.MetricScan) {
            foreach ($v in (Get-UnilyzeMetricViolations -Type $type -Thresholds $ThresholdInfo.Values -SkipKinds @($metricSkip))) {
                if ($Options.IgnoreKinds -contains $v.kind) { continue }
                if ((Get-UnilyzeSeverityRank -Severity $v.severity) -lt $minRank) { $counters.droppedSeverity++; continue }
                $key = "$($v.kind)|$(Get-UnilyzeProp -Object $v -Name 'method')"
                if ($allSmellKeys.ContainsKey($key)) { continue }   # инструмент уже высказался (в т.ч. «подавлено»)
                $counters.metricViolations++
                if ($v.kind) {
                    if (-not $counters.byKind.ContainsKey($v.kind)) { $counters.byKind[$v.kind] = 0 }
                    $counters.byKind[$v.kind]++
                }
                [void]$reasons.Add($v)
            }
        }

        # --- code health ---
        if ($Options.Sources -contains 'health') {
            $category = [string](Get-UnilyzeProp -Object $type -Name 'codeHealthCategory' -Default '')
            if ($category -eq 'alert' -or $category -eq 'warning') {
                $warnBelow = Get-UnilyzeThresholdValue -Table $ThresholdInfo.Values -Key 'CodeHealth.warningBelow' -Default 9.0
                if ($null -ne $health -and [double]$health -lt $warnBelow) {
                    $sev = 'Warning'
                    if ($category -eq 'alert') { $sev = 'Critical' }
                    if ((Get-UnilyzeSeverityRank -Severity $sev) -lt $minRank) { $counters.droppedSeverity++ }
                    else {
                        [void]$reasons.Add((New-UnilyzeReason -Source 'health' -Kind 'CodeHealth' -Severity $sev -Metric 'codeHealth' -Value ([double]$health) -Threshold $warnBelow -Message ("CodeHealth {0:N1} ({1})" -f ([double]$health), $category)))
                    }
                }
            }
        }

        if ($reasons.Count -eq 0) { continue }

        $worst = Get-UnilyzeWorstSeverity -Severities @($reasons | ForEach-Object { $_.severity })

        # Методы: только «плохие», худшие вперёд.
        $badMethods = New-Object System.Collections.ArrayList
        $methods = Get-UnilyzeProp -Object $type -Name 'methods'
        if ($methods) {
            $lmLines = Get-UnilyzeThresholdValue -Table $ThresholdInfo.Values -Key 'LongMethod.lines' -Default 80
            $lmCog   = Get-UnilyzeThresholdValue -Table $ThresholdInfo.Values -Key 'LongMethod.cogCc' -Default 25
            $hcxCyc  = Get-UnilyzeThresholdValue -Table $ThresholdInfo.Values -Key 'HighComplexity.cycCc' -Default 15
            $hcxCog  = Get-UnilyzeThresholdValue -Table $ThresholdInfo.Values -Key 'HighComplexity.cogCc' -Default 15
            $dnDepth = Get-UnilyzeThresholdValue -Table $ThresholdInfo.Values -Key 'DeepNesting.depth' -Default 4
            $epMax   = Get-UnilyzeThresholdValue -Table $ThresholdInfo.Values -Key 'ExcessiveParameters.max' -Default 5
            $miMin   = Get-UnilyzeThresholdValue -Table $ThresholdInfo.Values -Key 'LowMaintainability.mi' -Default 60

            foreach ($m in $methods) {
                $mName = [string](Get-UnilyzeProp -Object $m -Name 'methodName' -Default '?')
                $mReasons = New-Object System.Collections.ArrayList
                $mLoc  = [double](Get-UnilyzeProp -Object $m -Name 'lineCount' -Default 0)
                $mCog  = [double](Get-UnilyzeProp -Object $m -Name 'cognitiveComplexity' -Default 0)
                $mCyc  = [double](Get-UnilyzeProp -Object $m -Name 'cyclomaticComplexity' -Default 0)
                $mNest = [double](Get-UnilyzeProp -Object $m -Name 'maxNestingDepth' -Default 0)
                $mPar  = [double](Get-UnilyzeProp -Object $m -Name 'parameterCount' -Default 0)
                $mMi   = Get-UnilyzeProp -Object $m -Name 'maintainabilityIndex'

                if ($mLoc -ge $lmLines -or $mCog -ge $lmCog)      { [void]$mReasons.Add('LongMethod') }
                if ($mCyc -ge $hcxCyc -or $mCog -ge $hcxCog)      { [void]$mReasons.Add('HighComplexity') }
                if ($mNest -ge $dnDepth)                          { [void]$mReasons.Add('DeepNesting') }
                if ($mPar -gt $epMax)                             { [void]$mReasons.Add('ExcessiveParameters') }
                if ($null -ne $mMi -and [double]$mMi -lt $miMin)  { [void]$mReasons.Add('LowMaintainability') }

                foreach ($s in @($keptSmells | Where-Object { (Get-UnilyzeProp -Object $_ -Name 'methodName') -eq $mName })) {
                    [void]$mReasons.Add([string](Get-UnilyzeProp -Object $s -Name 'kind'))
                }

                if ($mReasons.Count -eq 0) { continue }

                $o = [ordered]@{
                    methodName           = $mName
                    startLine            = Get-UnilyzeProp -Object $m -Name 'startLine'
                    lineCount            = Get-UnilyzeProp -Object $m -Name 'lineCount'
                    cyclomaticComplexity = Get-UnilyzeProp -Object $m -Name 'cyclomaticComplexity'
                    cognitiveComplexity  = Get-UnilyzeProp -Object $m -Name 'cognitiveComplexity'
                    maxNestingDepth      = Get-UnilyzeProp -Object $m -Name 'maxNestingDepth'
                    parameterCount       = Get-UnilyzeProp -Object $m -Name 'parameterCount'
                    maintainabilityIndex = $mMi
                    reasons              = @($mReasons | Select-Object -Unique)
                }
                [void]$badMethods.Add([pscustomobject]$o)
            }
        }

        $sortedMethods = @($badMethods | Sort-Object -Property @{ Expression = { @($_.reasons).Count }; Descending = $true },
                                                          @{ Expression = { if ($null -eq $_.maintainabilityIndex) { 100 } else { [double]$_.maintainabilityIndex } } },
                                                          @{ Expression = { $_.methodName } })
        $methodOverflow = 0
        if ($Options.MaxMethodsPerType -gt 0 -and $sortedMethods.Count -gt $Options.MaxMethodsPerType) {
            $methodOverflow = $sortedMethods.Count - $Options.MaxMethodsPerType
            $sortedMethods = @($sortedMethods[0..($Options.MaxMethodsPerType - 1)])
        }

        $metricsObj = [pscustomobject][ordered]@{
            maxCognitiveComplexity        = Get-UnilyzeProp -Object $type -Name 'maxCognitiveComplexity'
            maxCyclomaticComplexity       = Get-UnilyzeProp -Object $type -Name 'maxCyclomaticComplexity'
            maxNestingDepth               = Get-UnilyzeProp -Object $type -Name 'maxNestingDepth'
            averageCognitiveComplexity    = Get-UnilyzeProp -Object $type -Name 'averageCognitiveComplexity'
            averageCyclomaticComplexity   = Get-UnilyzeProp -Object $type -Name 'averageCyclomaticComplexity'
            excessiveParameterMethodCount = Get-UnilyzeProp -Object $type -Name 'excessiveParameterMethodCount'
            lcom                          = Get-UnilyzeProp -Object $type -Name 'lcom'
            cbo                           = Get-UnilyzeProp -Object $type -Name 'cbo'
            dit                           = Get-UnilyzeProp -Object $type -Name 'dit'
            wmc                           = Get-UnilyzeProp -Object $type -Name 'wmc'
            rfc                           = Get-UnilyzeProp -Object $type -Name 'rfc'
            noc                           = Get-UnilyzeProp -Object $type -Name 'noc'
            minMaintainabilityIndex       = Get-UnilyzeProp -Object $type -Name 'minMaintainabilityIndex'
            averageMaintainabilityIndex   = Get-UnilyzeProp -Object $type -Name 'averageMaintainabilityIndex'
            afferentCoupling              = Get-UnilyzeProp -Object $type -Name 'afferentCoupling'
            efferentCoupling              = Get-UnilyzeProp -Object $type -Name 'efferentCoupling'
            typeRank                      = Get-UnilyzeProp -Object $type -Name 'typeRank'
        } | Remove-UnilyzeNullProperty

        $flaggedType = [pscustomobject][ordered]@{
            typeName           = Get-UnilyzeProp -Object $type -Name 'typeName'
            qualifiedName      = Get-UnilyzeProp -Object $type -Name 'qualifiedName'
            namespace          = Get-UnilyzeProp -Object $type -Name 'namespace'
            assembly           = Get-UnilyzeProp -Object $type -Name 'assembly'
            filePath           = Get-UnilyzeProp -Object $type -Name 'filePath'
            startLine          = Get-UnilyzeProp -Object $type -Name 'startLine'
            codeHealth         = $health
            codeHealthCategory = Get-UnilyzeProp -Object $type -Name 'codeHealthCategory'
            severity           = $worst
            lineCount          = Get-UnilyzeProp -Object $type -Name 'lineCount'
            methodCount        = Get-UnilyzeProp -Object $type -Name 'methodCount'
            metrics            = $metricsObj
            reasons            = @($reasons)
            smells             = @($keptSmells)
            methods            = $sortedMethods
        }
        if ($methodOverflow -gt 0) {
            $flaggedType | Add-Member -NotePropertyName methodsTruncated -NotePropertyValue $methodOverflow
        }
        [void]$flagged.Add($flaggedType)
    }

    $sorted = @($flagged | Sort-Object -Property @{ Expression = { if ($null -eq $_.codeHealth) { 10 } else { [double]$_.codeHealth } } },
                                                 @{ Expression = { $_.qualifiedName } })

    $summary = [ordered]@{
        typesTotal        = @($Types_).Count
        typesFlagged      = $sorted.Count
        typesHealthy      = (@($Types_).Count - $sorted.Count)
        smellsTotal       = $counters.smellsTotal
        smellsFlagged     = $counters.smellsKept
        smellsCritical    = $counters.smellsCritical
        smellsWarning     = $counters.smellsWarning
        metricViolations  = $counters.metricViolations
        informational     = $counters.informational
        droppedSuppressed = $counters.droppedSuppressed
        droppedBaselined  = $counters.droppedBaselined
        droppedTriage     = $counters.droppedTriage
        droppedBySeverity = $counters.droppedSeverity
        droppedBySource   = $counters.droppedSource
        droppedIgnored    = $counters.droppedIgnored
        averageCodeHealth = $null
        minCodeHealth     = $minHealth
        byKind            = $counters.byKind
    }
    if ($healthCount -gt 0) { $summary.averageCodeHealth = [math]::Round($totalHealth / $healthCount, 2) }

    return [pscustomobject]@{
        Types   = $sorted
        Summary = [pscustomobject]$summary
    }
}

# ---------------------------------------------------------------------------
# Вывод
# ---------------------------------------------------------------------------

function Get-UnilyzeDominantKindHint {
    <#
      Текст подсказки, если один вид находок съедает большую часть вывода.
      Возвращает $null, если подсказывать нечего. Общий для CLI и для UI.
    #>
    param(
        [object]$Summary,
        [double]$Share = 0.5,
        [int]$MinTotal = 20
    )
    if (-not $Summary) { return $null }
    $byKind = Get-UnilyzeProp -Object $Summary -Name 'byKind'
    if (-not $byKind) { return $null }
    $total = 0
    foreach ($v in $byKind.Values) { $total += [int]$v }
    if ($total -le $MinTotal) { return $null }

    $topKind = $null; $topCount = 0
    foreach ($k in $byKind.Keys) {
        if ([int]$byKind[$k] -gt $topCount) { $topKind = $k; $topCount = [int]$byKind[$k] }
    }
    if (-not $topKind -or ($topCount / $total) -lt $Share) { return $null }

    return ("'{0}' даёт {1}% находок ({2}/{3}). Можно вынести в unilyze.filter.ignoreKinds или отключить правилом {4}=off в .unilyze.json." -f `
        $topKind, [int](100 * $topCount / $total), $topCount, $total, (Get-UnilyzeSmellRule $topKind))
}

function ConvertTo-UnilyzeMarkdown {
    param([object]$Digest)

    $sb = New-Object System.Text.StringBuilder
    $s = $Digest.summary
    [void]$sb.AppendLine('# Unilyze: только хуже нормы')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Проект: ``$($Digest.source.projectPath)``")
    [void]$sb.AppendLine("Снимок: ``$($Digest.source.snapshot)``")
    [void]$sb.AppendLine("Проанализирован: $($Digest.source.analyzedAt)")
    [void]$sb.AppendLine("Инструмент: unilyze $($Digest.source.toolVersion), уровень $($Digest.source.analysisLevel), metricsVersion $($Digest.source.metricsVersion)")
    [void]$sb.AppendLine("Режим фильтра: $($Digest.filter.mode), минимум: $($Digest.filter.minSeverity)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Сводка')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Метрика | Значение |')
    [void]$sb.AppendLine('|---|---|')
    [void]$sb.AppendLine("| Типов всего | $($s.typesTotal) |")
    [void]$sb.AppendLine("| Типов хуже нормы | $($s.typesFlagged) |")
    [void]$sb.AppendLine("| Типов в норме (отсеяно) | $($s.typesHealthy) |")
    [void]$sb.AppendLine("| Находок всего | $($s.smellsTotal) |")
    [void]$sb.AppendLine("| Находок хуже нормы | $($s.smellsFlagged) (Critical $($s.smellsCritical) / Warning $($s.smellsWarning)) |")
    [void]$sb.AppendLine("| Нарушений метрик (пересчёт) | $($s.metricViolations) |")
    [void]$sb.AppendLine("| Информационных отметок (не в счёт) | $($s.informational) |")
    [void]$sb.AppendLine("| Отсеяно: suppressed | $($s.droppedSuppressed) |")
    [void]$sb.AppendLine("| Отсеяно: baseline | $($s.droppedBaselined) |")
    [void]$sb.AppendLine("| Отсеяно: triage (false-positive/wontfix) | $($s.droppedTriage) |")
    [void]$sb.AppendLine("| Отсеяно: ниже порога важности | $($s.droppedBySeverity) |")
    [void]$sb.AppendLine("| Отсеяно: источник не запрошен | $($s.droppedBySource) |")
    [void]$sb.AppendLine("| Отсеяно: ignoreKinds | $($s.droppedIgnored) |")
    [void]$sb.AppendLine("| Средний CodeHealth | $($s.averageCodeHealth) |")
    [void]$sb.AppendLine("| Минимальный CodeHealth | $($s.minCodeHealth) |")
    [void]$sb.AppendLine('')

    if ($s.byKind -and $s.byKind.Keys.Count -gt 0) {
        [void]$sb.AppendLine('## Находки по видам')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('| Вид | Правило | Кол-во | Доля |')
        [void]$sb.AppendLine('|---|---|---|---|')
        $total = 0
        foreach ($v in $s.byKind.Values) { $total += $v }
        foreach ($k in ($s.byKind.Keys | Sort-Object -Property @{ Expression = { -$s.byKind[$_] } })) {
            $rule = Get-UnilyzeSmellRule $k
            if (-not $rule) { $rule = '-' }
            $pc = 0
            if ($total -gt 0) { $pc = [int][math]::Round(100.0 * $s.byKind[$k] / $total) }
            [void]$sb.AppendLine("| $k | $rule | $($s.byKind[$k]) | $pc% |")
        }
        [void]$sb.AppendLine('')
    }

    [void]$sb.AppendLine('## Типы хуже нормы (от худшего)')
    [void]$sb.AppendLine('')
    if (@($Digest.types).Count -eq 0) {
        [void]$sb.AppendLine('Ничего не найдено — всё в пределах нормы.')
    }
    foreach ($t in $Digest.types) {
        $loc = $t.filePath
        if ($t.startLine) { $loc = "${loc}:$($t.startLine)" }
        [void]$sb.AppendLine("### $($t.qualifiedName) — $($t.severity)")
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("- Файл: ``$loc``")
        [void]$sb.AppendLine("- CodeHealth: $($t.codeHealth) ($($t.codeHealthCategory)); строк $($t.lineCount), методов $($t.methodCount)")
        foreach ($r in $t.reasons) {
            $where = ''
            if ($r.method) { $where = " [$($r.method)]" }
            if ($r.rule) { $where = "$where $($r.rule)" }
            [void]$sb.AppendLine("- **$($r.severity)** $($r.kind)$($where): $($r.message)")
        }
        [void]$sb.AppendLine('')
    }

    return $sb.ToString()
}

function Invoke-UnilyzeFilter {
    <#
    .SYNOPSIS
      Отсеивает из JSON-снимка unilyze всё, что в пределах нормы.
    .DESCRIPTION
      Читает <SnapshotPath>, применяет пороги и оставляет только типы/находки хуже нормы.
      Пишет <OutputDir>\<outputJson> и (опционально) <OutputDir>\<outputMarkdown>.
      Возвращает $true, если дайджест записан.
    #>
    param(
        [string]$SnapshotPath,
        [string]$OutputDir,
        [object]$Config = $null,
        [string]$ProjectPath = $null,
        [string]$Mode = $null,
        [string]$MinSeverity = $null,
        [string]$Profile = $null,
        [int]$MaxTypes = 0,
        [object]$SnapshotObject = $null,        # уже разобранный снимок: превью без перечитывания
        [object]$ProjectConfigOverride = $null, # .unilyze.json в памяти
        [switch]$PassThru,                      # не писать файлы, вернуть дайджест
        [switch]$Quiet                          # не печатать сводку в консоль
    )

    if (-not $SnapshotObject) {
        if (-not $SnapshotPath -or -not (Test-Path $SnapshotPath)) {
            Write-Warning "UnilyzeFilter: снимок не найден: $SnapshotPath"
            return $false
        }
    }
    if (-not $OutputDir) {
        if ($SnapshotPath) { $OutputDir = Split-Path -Parent $SnapshotPath }
        else { $OutputDir = (Get-Location).Path }
    }
    if (-not $PassThru -and -not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    # --- настройки фильтра из конфига ---
    $fc = $null
    if ($Config) {
        $u = Get-UnilyzeProp -Object $Config -Name 'unilyze'
        if ($u) {
            $fc = Get-UnilyzeProp -Object $u -Name 'filter'
            if (-not $Mode)        { $Mode        = Get-UnilyzeProp -Object $fc -Name 'mode' }
            if (-not $MinSeverity) { $MinSeverity = Get-UnilyzeProp -Object $fc -Name 'minSeverity' }
            if ($MaxTypes -eq 0)   { $MaxTypes    = [int](Get-UnilyzeProp -Object $fc -Name 'maxTypes' -Default 0) }
        }
    }
    # Умолчания: доверяем вердиктам инструмента (он уже учитывает .unilyze.json,
    # baseline, triage и inline-подавления) и показываем всё от Warning и выше.
    if (-not $Mode)        { $Mode = 'smell' }
    if (-not $MinSeverity) { $MinSeverity = 'Warning' }

    $outputJson = 'unilyze-flags.json'
    $outputMd   = 'unilyze-flags.md'
    if ($fc) {
        $j = Get-UnilyzeProp -Object $fc -Name 'outputJson'
        $m = Get-UnilyzeProp -Object $fc -Name 'outputMarkdown'
        if ($j) { $outputJson = $j }
        if ($null -ne $m) { $outputMd = $m }
    }

    $sources = @('smell', 'metric', 'health')
    $cfgSources = Get-UnilyzeProp -Object $fc -Name 'sources'
    if ($cfgSources) { $sources = @($cfgSources) }

    $ignoreKinds = @()
    $cfgIgnore = Get-UnilyzeProp -Object $fc -Name 'ignoreKinds'
    if ($cfgIgnore) { $ignoreKinds = @($cfgIgnore) }

    $metricScan = ($Mode -eq 'metric' -or $Mode -eq 'both')
    if (-not ($sources -contains 'metric')) { $metricScan = $false }

    $options = @{
        MinSeverity        = $MinSeverity
        MetricScan         = $metricScan
        Sources            = $sources
        IgnoreKinds        = $ignoreKinds
        MaxMethodsPerType  = [int](Get-UnilyzeProp -Object $fc -Name 'maxMethodsPerType' -Default 0)
        IncludeRawSmells   = [bool](Get-UnilyzeProp -Object $fc -Name 'includeRawSmells' -Default $true)
        IncludeSuppressed  = [bool](Get-UnilyzeProp -Object $fc -Name 'includeSuppressed' -Default $false)
        IncludeBaselined   = [bool](Get-UnilyzeProp -Object $fc -Name 'includeBaselined' -Default $false)
        IncludeTriage      = [bool](Get-UnilyzeProp -Object $fc -Name 'includeTriage' -Default $false)
        Compact            = [bool](Get-UnilyzeProp -Object $fc -Name 'compact' -Default $true)
    }

    if ($SnapshotObject) {
        $snapshot = $SnapshotObject
    } else {
        try {
            $snapshot = Get-Content $SnapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            Write-Warning "UnilyzeFilter: не удалось разобрать JSON $SnapshotPath : $_"
            return $false
        }
    }

    if (-not $ProjectPath) { $ProjectPath = [string](Get-UnilyzeProp -Object $snapshot -Name 'projectPath') }

    $thr = Get-UnilyzeThresholds -Config $Config -ProjectPath $ProjectPath -Profile $Profile -Override $ProjectConfigOverride
    $findings = Get-UnilyzeFindings -Snapshot $snapshot -ThresholdInfo $thr -Options $options

    $types = @($findings.Types)
    $truncated = 0
    if ($MaxTypes -gt 0 -and $types.Count -gt $MaxTypes) {
        $truncated = $types.Count - $MaxTypes
        $types = @($types[0..($MaxTypes - 1)])
    }
    if (-not $options.IncludeRawSmells) {
        foreach ($t in $types) { $t.PSObject.Properties.Remove('smells') }
    }

    $snapshotFull = ''
    if ($SnapshotPath -and (Test-Path $SnapshotPath)) { $snapshotFull = (Resolve-Path $SnapshotPath).Path }

    $digest = [ordered]@{
        kind          = 'unilyze-digest'
        schemaVersion = 1
        generatedAt   = (Get-Date).ToString('o')
        source        = [pscustomobject][ordered]@{
            snapshot       = $snapshotFull
            projectPath    = Get-UnilyzeProp -Object $snapshot -Name 'projectPath'
            analyzedAt     = Get-UnilyzeProp -Object $snapshot -Name 'analyzedAt'
            toolVersion    = Get-UnilyzeProp -Object $snapshot -Name 'toolVersion'
            metricsVersion = Get-UnilyzeProp -Object $snapshot -Name 'metricsVersion'
            projectKind    = Get-UnilyzeProp -Object $snapshot -Name 'projectKind'
            analysisLevel  = Get-UnilyzeProp -Object $snapshot -Name 'analysisLevel'
        }
        filter        = [pscustomobject][ordered]@{
            mode              = $Mode
            minSeverity       = $MinSeverity
            sources           = $sources
            ignoreKinds       = $ignoreKinds
            profile           = $thr.Profile
            includeSuppressed = $options.IncludeSuppressed
            includeBaselined  = $options.IncludeBaselined
            includeTriage     = $options.IncludeTriage
            maxTypes          = $MaxTypes
            typesTruncated    = $truncated
            thresholds        = (Get-UnilyzeSortedObject -Table $thr.Values)
            thresholdSources  = $thr.Sources
            rulesDisabledByProject = $thr.DisabledKinds
        }
        summary       = $findings.Summary
        types         = $types
    }

    # --- Превью из UI: посчитать и вернуть, ничего не записывая ---
    if ($PassThru) { return $digest }

    $jsonPath = Join-Path $OutputDir $outputJson
    $jsonText = $digest | ConvertTo-Json -Depth 12
    if ($options.Compact) { $jsonText = Compress-UnilyzeJson -Json $jsonText }
    [System.IO.File]::WriteAllText($jsonPath, $jsonText, (New-Object System.Text.UTF8Encoding($false)))

    if (-not $Quiet) {
        $sum = $findings.Summary
        Write-Host ("Unilyze filter: хуже нормы {0} из {1} типов, находок {2} (Critical {3}) -> {4} [{5} KB]" -f `
            $sum.typesFlagged, $sum.typesTotal, $sum.smellsFlagged, $sum.smellsCritical, $outputJson, [int]((Get-Item $jsonPath).Length / 1KB))

        # Топ худших — сразу в консоль, чтобы не открывать файлы.
        foreach ($t in @($types | Select-Object -First 5)) {
            $where = $t.qualifiedName
            if ($t.filePath) { $where = "$where ($($t.filePath))" }
            Write-Host ("  [{0}] CH {1} — {2}" -f $t.severity, $t.codeHealth, $where) -ForegroundColor $(if ($t.severity -eq 'Critical') { 'Red' } else { 'Yellow' })
        }

        $hint = Get-UnilyzeDominantKindHint -Summary $sum
        if ($hint) { Write-Host "  Подсказка: $hint" -ForegroundColor DarkGray }
    }

    if ($outputMd -and $outputMd -ne '' -and $outputMd -ne 'none') {
        $mdPath = Join-Path $OutputDir $outputMd
        $md = ConvertTo-UnilyzeMarkdown -Digest $digest
        [System.IO.File]::WriteAllText($mdPath, $md, (New-Object System.Text.UTF8Encoding($false)))
        if (-not $Quiet) { Write-Host "Unilyze filter: отчёт -> $outputMd" }
    }

    return $true
}
