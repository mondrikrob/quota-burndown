# Contributing

Thanks for helping! Bug reports with the `-Once` output and the end of `widget.log` are the most useful thing you can send (see the bug report form). Never paste tokens or `.credentials.json`.

## Ground rules for code

- **One file.** Everything lives in `QuotaBurndown.ps1`; no modules, no dependencies, no build step.
- **Windows PowerShell 5.1 first.** It must run on the `powershell.exe` that ships with Windows, and on PowerShell 7.
- **ASCII only.** Write other characters as `[char]0x....`, so the file reads the same in every editor and code page.
- **Data layer vs UI.** Anything the background worker needs goes inside the `$DataLayer` script block; it runs in both the UI thread and the worker runspace.
- **Security.** Never print, log or copy tokens. Don't add network calls to new hosts. Any change to how the credentials file is read or written needs a test. See [SECURITY.md](SECURITY.md).

Known PowerShell traps in this codebase:
- `[Math]::Max(0, $x)` picks the integer overload; write `0.0`.
- `$null` passed to a .NET string parameter becomes `""`; use `[NullString]::Value`.
- `H` and `R` are built-in aliases and `$input` is an automatic variable; don't use them as names.

## Checks

Before opening a pull request, run what CI runs:

```powershell
Invoke-ScriptAnalyzer -Path .\QuotaBurndown.ps1 -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-Pester -Path .\tests
```

Then try it for real: `-Once`, `-Snapshot out.png -Theme dark` and `-Theme light` (look at the images), and `-Install`, then check `widget.log`.

Add an entry to `CHANGELOG.md` under a new version heading for anything user-visible.
