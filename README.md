# PowerShell Analysis Toolkit

Набор скриптов для анализа C#/Unity/dotnet-проектов. Собирает дерево проекта в один текстовый файл для LLM,
делает HTML-анализ C#-скриптов и **выжимку «только хуже нормы»**, а также прогоняет тесты — одним вызовом.

## Что делает

Пайплайн из трёх шагов:

| Шаг | Инструмент | Вывод |
|-----|-----------|-----------|
| 1 | [gitingest](https://github.com/cyclotruc/gitingest) | `gitingest.txt` — плоское дерево проекта с содержимым файлов, готовое для LLM |
| 2 | [unilyze](https://github.com/bigdra50/unilyze) | `unilyze.html` — интерактивный анализ; `unilyze.json` — полный снимок |
| 2b | `modules\UnilyzeFilter.ps1` | `unilyze-flags.json` / `unilyze-flags.md` — **только то, что хуже нормы** |
| 3 | Встроенный TestRunner | XML/TRX-отчёты (Unity Test Framework, `dotnet test`, NUnit) |

## Требования

- **Windows** с PowerShell 5.1+
- **WSL 2** с установленным `gitingest` (`pip install --user gitingest`)
- Опционально: **unilyze** в PATH (или путь в `analyze-config.json` -> `paths.unilyze`)
- Опционально: **Unity Editor** (для Unity-проектов), **dotnet SDK**, **NUnit.ConsoleRunner** (ставится автоматически)

## Установка

```powershell
git clone https://github.com/Alenetika/analyze-tools.git C:\Projects\PowerShell
cd C:\Projects\PowerShell
.\setup.ps1
```

Для запуска из любого места:

```powershell
$projectDir = "C:\Projects\PowerShell"
$current = [Environment]::GetEnvironmentVariable("Path", "User")
if ($current -notlike "*$projectDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$current;$projectDir", "User")
    Write-Host "Added to user PATH: $projectDir"
} else {
    Write-Host "Already in PATH"
}
```

---

# Как настраивается unilyze

## 1. Конфигурация самого инструмента

unilyze складывает настройки из трёх источников (аддитивно), младший приоритет — выше:

| Область | Путь | Что задаёт |
|---|---|---|
| Глобальная | `~/.config/unilyze/config.json` | настройки для всех проектов |
| Проектная | `<корень проекта>/.unilyze.json` | то, что нужно этому проекту |
| CLI | `--exclude-dir`, `--profile`, `--baseline`, ... | разовый запуск |

Пример `.unilyze.json`:

```jsonc
{
  "excludeDirs": ["Assets/Plugins", "Assets/ThirdParty"],
  "profile": "unity",
  "smells": {
    "LongMethod":    { "lines": 100, "cogCc": 40, "criticalLines": 200, "criticalCogCc": 60 },
    "GodClass":      { "lines": 800, "methods": 30, "criticalLines": 1500 },
    "LowCohesion":   { "lcom": 0.9 },
    "HighCoupling":  { "cbo": 20, "criticalCbo": 30 },
    "DeepNesting":   { "depth": 5, "criticalDepth": 7 },
    "ExcessiveParameters": { "max": 6 },
    "DeepInheritance":     { "dit": 6 },
    "LowMaintainability":  { "mi": 50 }
  },
  "rules": { "UNI008": "off", "UNI009": "off" }
}
```

Ключи `smells` — ровно те, что печатает `unilyze metrics`; имена порогов регистронезависимы.
Значения по умолчанию (и что они значат) всегда можно посмотреть так:

```bash
unilyze metrics      # определения метрик и все пороги (включая role-aware для unity)
unilyze schema       # справочник по полям JSON-вывода
unilyze config list  # текущая действующая конфигурация
```

### Что реально снижает шум

| Приём | Область | Когда применять |
|---|---|---|
| `"rules": { "UNI008": "off" }` | правило целиком | вид находок шумит по всему проекту (например `UNI008` LowMaintainability) |
| `"smells": { ... }` | порог вида | инструмент формально прав, но для этого проекта порог надо сдвинуть |
| `--profile unity` | запуск | Unity-проект: role-aware пороги (`MonoBehaviour` 800/30, `ScriptableObject` 650/25) и `LowCohesion` -> informational |
| `// unilyze-disable-next-line UNI002` / `// unilyze-disable UNI002` | одна находка / объявление | осознанное исключение с обоснованием |
| `--baseline` (`unilyze baseline create`) | снимок проекта | brownfield: заморозить существующий долг и следить только за новым |
| `unilyze triage` | одна находка | вердикт `false-positive` / `wontfix`, чтобы не всплывало снова |
| `excludeDirs` / `--exclude-dir` | каталоги | чужой код (плагины, SDK), который не ваш |

Подавленные находки не исчезают из JSON: у них появляется `"suppressed": true` или `"baselined": true`,
растёт корневой `suppressedCount`, а из бейджей/гейтов они исключаются.

Правила (SARIF-ID) для `rules`: `UNI001` GodClass, `UNI002` LongMethod, `UNI003` ExcessiveParameters,
`UNI004` HighComplexity, `UNI005` DeepNesting, `UNI006` LowCohesion, `UNI007` HighCoupling,
`UNI008` LowMaintainability, `UNI009` CyclicDependency, `UNI010` DeepInheritance, `UNI011` BoxingAllocation,
`UNI012` ClosureCapture, `UNI013` ParamsArrayAllocation, `UNI014` CatchAllException, `UNI015` MissingInnerException,
`UNI016` ThrowingSystemException, `UNI017`-`UNI021` Unity hot-path, `UNI022` AsyncVoidMethod,
`UNI023` BlockingTaskWait, `UNI024` MissingBurstCompile, `UNI025` ManagedReferenceInComponentData.

### Область анализа: папка запуска или весь проект

`unilyze` ищет `.csproj` вверх по дереву от `-p` и, **найдя его, анализирует весь проект**:
запуск в подпапке даёт в отчёте типы со всего дерева — и в HTML, и в `unilyze.json`, и в дайджесте.
Если `.csproj` выше нет (Unity-проект, просто папка с `.cs`), unilyze сам ограничивается указанной
папкой; один `.sln` без `.csproj` анализ всего дерева не включает.

Поэтому `analyze.ps1` по умолчанию **сужает** анализ до папки запуска: находит ближайший `.csproj`
и передаёт unilyze `--exclude-dir` для всех «соседей» на пути от корня проекта до этой папки
(в консоли это строка `scope: только <папка> (... исключено каталогов: N)`).

| Запуск | Что анализируется |
|---|---|
| `analyze` | только текущая папка (если она внутри проекта) |
| `analyze -FromRoot` | весь проект от корня `.csproj` — прежнее поведение |
| `analyze` вне проекта (Unity, папка без `.csproj`) | папка запуска, сужать нечего |

Что меняется в суженном прогоне:

- `CodeHealth` и состав находок остаются теми же, а метрики связей — нет: `Ce` и `CBO` считаются
  только по оставшимся типам;
- `TypeRank` **нельзя сравнивать** между суженным и полным прогоном: он нормирован на сумму 1
  по всему графу, поэтому на маленьком графе значения автоматически больше;
- `--exclude-dir` принимает только каталоги, поэтому отдельные «свободные» `.cs`-файлы в
  промежуточных папках (например `Processors\SomeFile.cs`) в отчёт всё равно попадут;
- пути для `--exclude-dir` считаются от корня `.csproj`, а не от папки запуска.

## 2. Настройки в analyze-config.json

```jsonc
"unilyze": {
  "profile":  "",       // "" = авто: unity при unity-профиле анализа, иначе default
  "emitHtml": true,     // false = писать только JSON (быстрее)
  "filter": {
    "enabled":  true,
    "mode":     "smell",       // smell | both | metric
    "minSeverity": "Warning",  // Warning | Critical
    "sources":  ["smell", "metric", "health"],
    "ignoreKinds": [],
    "maxTypes": 0,
    "maxMethodsPerType": 0,
    "includeRawSmells": true,
    "includeSuppressed": false,
    "includeBaselined": false,
    "includeTriage": false,
    "compact": true,
    "outputJson": "unilyze-flags.json",
    "outputMarkdown": "unilyze-flags.md",
    "thresholds": {}
  }
}
```

---

# Фильтр «только хуже нормы»

Полный JSON-снимок unilyze содержит **всё** — вместе с типами и находками, которые в пределах нормы:
`healthy`-типы, informational-отметки, уже подавленное через baseline и inline-директивы, признанное
false-positive. Для LLM и для чтения глазами это шум: на реальном Unity-проекте из 2902 типов «хуже нормы»
оказались 1001, а сам JSON ужался с 33.5 МБ до 7.5 МБ (в компактном виде — в разы меньше).

`modules\UnilyzeFilter.ps1` читает снимок и пишет дайджест только с тем, что вне нормы, и с причиной
для каждого типа.

## Что считается «хуже нормы»

Три независимых источника (управляются `filter.mode` и `filter.sources`):

| Источник | Что берёт | Комментарий |
|---|---|---|
| `smell` | вердикты самого unilyze (`typeMetrics[].codeSmells[]`) | уважает `.unilyze.json`, baseline, triage, inline-директивы |
| `metric` | независимый пересчёт сырых метрик по порогам | для случая «мой порог строже, чем разрешает проект» |
| `health` | `codeHealthCategory`: `warning` (< 9.0) и `alert` (< 4.0) | композитная оценка unilyze |

Отсеивается всегда: `suppressed`, `baselined`, `triage` = `false-positive`/`wontfix`, находки ниже
`minSeverity`, виды из `ignoreKinds`, и всё, что не проходит по источникам.

## Режимы (`mode`)

| Режим | Поведение |
|---|---|
| `smell` (по умолчанию) | Доверяем инструменту. Риск противоречия настройкам проекта нулевой. |
| `both` | `smell` + `metric`. Пересчёт **не дублирует** то, что инструмент уже сказал (включая подавленное), не переоткрывает виды, отключённые через `rules: UNIxxx = off`, и не трогает profile-зависимые виды в unity (`GodClass`, `LowCohesion`). |
| `metric` | Только пересчёт по порогам. |

Важно: `metric` использует пороги из `<проект>/.unilyze.json` -> `smells`, а пороги, **явно** заданные в
`analyze-config.json` -> `unilyze.filter.thresholds`, сильнее проектного `off` — так можно проверить
проект по своему, более строгому, стандарту.

## Опции фильтра

| Ключ | По умолчанию | Что делает |
|---|---|---|
| `enabled` | `true` | Выключает шаг 2b целиком |
| `mode` | `smell` | `smell` / `both` / `metric` |
| `minSeverity` | `Warning` | `Critical` — оставить только критичное |
| `sources` | `smell, metric, health` | какие источники причин вообще показывать |
| `ignoreKinds` | `[]` | выбросить виды находок, напр. `["LowMaintainability"]` |
| `maxTypes` | `0` | ограничить число типов в дайджесте (худшие идут первыми) |
| `maxMethodsPerType` | `0` | ограничить методы на тип (худшие идут первыми) |
| `includeRawSmells` | `true` | класть исходные объекты находок (с `id` для baseline/triage) |
| `includeSuppressed` | `false` | показать и подавленные inline |
| `includeBaselined` | `false` | показать и замороженные baseline |
| `includeTriage` | `false` | показать и `false-positive`/`wontfix` |
| `compact` | `true` | минифицировать JSON (PowerShell 5.1 иначе сыпет отступами) |
| `thresholds` | `{}` | переопределение порогов, напр. `{"GodClass": {"lines": 600}}` |

## Что внутри дайджеста

```jsonc
{
  "kind": "unilyze-digest",
  "source": { "projectPath": "...", "toolVersion": "0.6.0", "analysisLevel": "Complete", ... },
  "filter": { "mode": "smell", "minSeverity": "Warning", "thresholds": { ... }, "rulesDisabledByProject": [] },
  "summary": {
    "typesTotal": 2902, "typesFlagged": 1001, "typesHealthy": 1901,
    "smellsFlagged": 3058, "smellsCritical": 174, "smellsWarning": 2884,
    "droppedSuppressed": 0, "droppedBaselined": 0, "droppedTriage": 0,
    "averageCodeHealth": 9.79, "minCodeHealth": 1,
    "byKind": { "GodClass": 86, "LongMethod": 69 }
  },
  "types": [
    {
      "qualifiedName": "Corp.Services.Windows.Runtime.WindowsManager",
      "filePath": "Assets/Core/Windows/Runtime/WindowsManager.cs", "startLine": 12,
      "codeHealth": 8.2, "codeHealthCategory": "warning", "severity": "Critical",
      "metrics": { "maxCognitiveComplexity": 31, "cbo": 22, "lcom": 0.86 },
      "reasons": [
        { "source": "smell", "severity": "Critical", "rule": "UNI002", "kind": "LongMethod",
          "method": "Open", "line": 44, "fingerprint": "ada791..." },
        { "source": "health", "severity": "Warning", "kind": "CodeHealth",
          "metric": "codeHealth", "value": 8.2, "threshold": 9, "message": "CodeHealth 8,2 (warning)" }
      ],
      "smells": [ /* исходные объекты unilyze, если includeRawSmells */ ],
      "methods": [ /* только «плохие» методы, худшие первыми */ ]
    }
  ]
}
```

`types[]` отсортированы от худшего CodeHealth; `severity` типа — худшая из его причин.

## Примеры

```powershell
# Только то, что unilyze сам считает нарушением (по умолчанию)
.\analyze.ps1 -Path D:\Projects\MyGame

# Плюс проверка по своим, более строгим порогам
# analyze-config.json -> unilyze.filter.thresholds: { "LongMethod": { "lines": 40 } }

# Совсем кратко: только критика, не больше 30 типов
.\analyze.ps1 -Path D:\Projects\MyGame   # с mode=Critical-настройками в конфиге
```

Типичный рабочий цикл при большом наследии — заморозить долг и следить за новым:

```bash
cd /d/Projects/MyGame
unilyze baseline create -p . -o .unilyze/baseline.json
# дальше добавляем --baseline в .unilyze.json (или в запуск), фильтр сам выкинет замороженное
```

## Заметки по эксплуатации

- Дайджест читается из **JSON-снимка**, который unilyze пишет рядом с HTML (`unilyze.json`).
  Если нужен только JSON — `"emitHtml": false`.
- Дайджест и снимок добавлены в `defaultExcludes`, чтобы повторный `gitingest` их не втягивал.
- На большом проекте сам анализ unilyze долгий (порядок — минуты); фильтр по 33 МБ снимку занимает ~30 с.
- Если один вид находок съедает больше половины вывода, фильтр пишет подсказку в консоль
  (например `LowMaintainability` — 53% находок): его обычно и стоит первым делом исключить
  через `ignoreKinds` или `rules: UNI008 = "off"`.
