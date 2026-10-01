# PowerShell Analysis Toolkit

Набор PowerShell-скриптов для анализа C#/Unity/dotnet-проектов. Собирает всё дерево проекта в один текстовый файл для LLM, генерирует HTML-анализ C#-скриптов и прогоняет тесты — в один вызов.

## Что делает

Пайплайн из трёх шагов:

| Шаг | Инструмент | Результат |
|-----|-----------|-----------|
| 1 | [gitingest](https://github.com/cyclotruc/gitingest) | `gitingest.txt` — плоское дерево проекта с содержимым файлов, готовое для LLM |
| 2 | [unilyze](https://github.com/bigdra50/unilyze) | `unilyze.html` — анализ C#-скриптов (работает для любого проекта с .cs, не только Unity) |
| 3 | Встроенный TestRunner | XML/TRX-отчёты тестов (Unity Test Framework, `dotnet test`, NUnit) |

## Требования

- **Windows** с PowerShell 5.1+ (или PowerShell 7+)
- **WSL 2** с установленным `gitingest` внутри (`pip install --user gitingest`)
- Опционально: **unilyze** — в Windows PATH
- Опционально: **Unity Editor** (для Unity-проектов), **dotnet SDK** (для dotnet-проектов), **NUnit.ConsoleRunner** (автоустанавливается)

## Установка

```powershell
git clone [<repo>](https://github.com/Alenetika/analyze-tools.git) C:\Projects\PowerShell
cd C:\Projects\PowerShell
.\setup.ps1
