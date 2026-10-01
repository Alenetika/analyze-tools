# PowerShell Analysis Toolkit

A set of PowerShell scripts for analyzing C#/Unity/dotnet projects. It collects the entire project tree into a single text file for an LLM, generates an HTML analysis of C# scripts, and runs tests — all in a single call.

## What it does

A three-step pipeline:

| Step | Tool | Output |
|-----|-----------|-----------|
| 1 | [gitingest](https://github.com/cyclotruc/gitingest) | `gitingest.txt` — a flat project tree with file contents, ready for an LLM |
| 2 | [unilyze](https://github.com/bigdra50/unilyze) | `unilyze.html` — analysis of C# scripts (works for any project with .cs files, not just Unity) |
| 3 | Built-in TestRunner | XML/TRX test reports (Unity Test Framework, `dotnet test`, NUnit) |

## Requirements

- **Windows** with PowerShell 5.1+
- **WSL 2** with `gitingest` installed inside (`pip install --user gitingest`)
- Optional: **unilyze** — in the Windows PATH
- Optional: **Unity Editor** (for Unity projects), **dotnet SDK** (for dotnet projects), **NUnit.ConsoleRunner** (installed automatically)

## Installation

```powershell
git clone [<repo>](https://github.com/Alenetika/analyze-tools.git) C:\Projects\PowerShell
cd C:\Projects\PowerShell
.\setup.ps1
```

For access from anywhere

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