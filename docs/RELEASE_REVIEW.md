# Release review — 2026-10-11

**Release decision: the owner authorised v1.6.0 as an experimental release, accepting the unresolved Claude credential-use policy risk.** The integration remains unofficial, with no verified provider permission. Clean-machine installation and additional Windows/taskbar configurations remain unverified. Automated checks establish specific behavior; they do not certify all environments or provider approval.

The repository is already public, with v1.5.0 published on 2026-10-05. This report records the pre-release review and v1.6.0 preparation. Release completion and CI results are recorded on GitHub. Existing v1.5.0 assets are preserved; installing the updated widget is a separate step.

## Findings and fixes

| Area | Finding | Result |
|---|---|---|
| Provider policy | The widget reads a Claude subscription token and calls an undocumented usage endpoint. Explicit permission for third-party usage monitoring was not verified. | **Unresolved policy risk accepted by the owner for an experimental release.** README and SECURITY disclose it. |
| Login renewal | “Official renewal” overstated what `claude doctor` guarantees. Anthropic documents diagnostics; renewal may be a side effect. | Corrected documentation, installer, menu and tooltip. The opt-in helper remains experimental. The v1.5.0 changelog now carries a correction; its public release notes are corrected during release preparation. |
| Consent | README said both choices default to no; code defaulted renewal to yes. | Both default to no. Regression tested. Existing saved choices are retained. |
| Exhausted limits | Full bars looked too similar to forecast warnings; no explicit reached state. | Added red **× LIMIT REACHED** widget labels, white × on full taskbar bars, and **FULL** tray values. Expired windows clear the state. Over-limit responses are treated as exhausted. |
| Windows compatibility | NotifyIcon on .NET Framework rejects text longer than 63 characters; code allowed 127. Four exhausted windows exposed the bug. | Shortened and capped tray text; tested all four FULL values together. |
| Stale data | Failed refreshes could retain a healthy-looking previous Codex result; cached readings still produced forecasts. Missing bars looked like zero usage. The log fallback could attach a newer unrelated timestamp to an older selected value. | Retained results show stale/error state. Readings older than 15 minutes and session-log fallbacks do not forecast. Unknown/stale/fallback strip data shows `?`; tooltip reports age, source and failure details. Fallback age now reflects the oldest selected window. |
| Response validation | Missing percentages became zero. Unknown Claude response schemas and empty Codex windows could appear successful. | Validate percentages and durations; unsupported data reports unavailable/unexpected response. Prefer the explicitly named shared Codex pool over its legacy view. |
| Process output | ReadToEndAsync buffered unrestricted stdout/stderr; Codex's cap applied only after a complete line. Continuous lines could evade its timeout check. | Bound both pipes while reading, including incomplete lines. Check deadlines on every protocol loop. Real Codex query smoke test passed. |
| Credentials and HTTP | Invalid bearer syntax could expose a token through a formatting error; HTTP clients followed redirects. | Reject malformed tokens without echoing them, redact the access token in network errors, disable redirects, and dispose request/response resources. |
| Forced termination | Fallback used a substring anywhere in another process's command line. | Parse Windows arguments and require the installed script as the actual `-File` target. Exclude command/encoded-command modes, unrelated scripts and similarly named files. |
| Local logs | Initial reads allocated the full remaining file. A bad timestamp could interrupt accounting. Local dates could miss UTC session folders. | Read in 8 MiB chunks, preserve ordinary partial UTF-8 records, skip oversized incomplete lines, ignore invalid timestamps, reset truncated-file state and use UTC session dates. |
| Pricing | Unknown models inherited an arbitrary known price. Legacy Opus 4 and Sonnet 5.5 cache pricing were incorrect. | Corrected checked prices, added Astra/Luna base prices, and leave unknown variants unpriced. Partial amounts say **priced subtotal** and omit the plan multiple. Scoped Claude rows omit unsupported token attribution. |
| CSV export | Leading spaces/control characters could evade the formula-prefix sanitiser. | Strip leading whitespace and formula operators; expanded regression cases. |
| Update cache | A malformed cached version could throw during version comparison. | Validate cached versions before using them. Document hourly failure retries accurately. |
| Installer | Wrapper continued after an unblock failure and did not preserve installation exit status. | Use the system PowerShell path, stop on unblock failure, preserve exit status and show failures. Tested paths with spaces, `&` and apostrophes. |
| Release package | Zip omitted the MIT license and security/readme context; version input and recursive output replacement lacked explicit guards. | Include README, LICENSE and SECURITY; validate version format and refuse a linked/unexpected output directory. Packaging regression tests verify hashes, contents and CRLF. |
| Accessibility | Icon controls were mouse-only Borders; update link was mouse-only text. | Native Buttons with accessible names, F5 refresh, Escape hide and Shift+F10 menu. Screen-reader and real keyboard interaction still need a manual pass. |
| GitHub presentation | Privacy FAQ said “No” despite credential-bearing network requests. Theme/fullscreen behavior and checksum assurances were overstated. | Clarified network behavior, startup-only theme selection, strip-only fullscreen hiding and checksum limitations. Removed unverified negative claims about competitors; added a download link and sample 100% images. |
| CI and repository hygiene | Checkout was tag-pinned; Pester/PSScriptAnalyzer versions floated. Local audit downloads could be committed accidentally. | Pin checkout to its resolved commit, pin test modules, add Dependabot for Actions and ignore local review output/common credential/data files. |

## Evidence

- Original suite: 39 passing tests. Final expanded suite: **84 passed on PowerShell 7; 82 passed and 2 packaging tests intentionally skipped on Windows PowerShell 5.1**, using Pester 5.7.1. Coverage includes exhausted states, response/privacy validation, accounting, process bounds, UTC dates, installation defaults, termination selection and release packaging.
- Windows PowerShell 5.1 and PowerShell 7 checks run locally on Windows ARM64. Packaging tests intentionally run only on PowerShell 7 because the release builder requires it.
- PSScriptAnalyzer, parse, ASCII-only script and `git diff --check` checks pass.
- Sixteen offline WPF renders exercise normal, short-window-full, weekly-full, all-full, missing-data, unpriced-data, stale-full and log-fallback states in dark/light themes. Representative images are [widget](limit-reached-dark.png) and [strip](limit-reached-strip.png). These are labelled sample data.
- Live, read-only Codex query returned the shared five-hour and weekly windows without error. No model request was made.
- Isolated install/reinstall/uninstall exercised actual COM shortcut creation and file handling. Settings were retained. The test replaced account access, real profile shortcuts and Explorer launch; it does not prove the complete first-run experience on a new PC.
- Installer wrapper preserved both success and a simulated failure's exit status in a path containing spaces, `&` and an apostrophe.
- Release build in an isolated copy verified standalone/zip script identity, Scoop hash, SHA256SUMS, license/docs contents and installer CRLF endings.
- Downloaded published v1.5.0 assets match their published hashes. The local checkout's script differs byte-for-byte because Git checks it out with CRLF; the downloaded asset uses LF. This is not evidence of release corruption. Rebuild checksums from the exact release files.
- Published v1.5.0 CI is green. The new release requires both CI matrix jobs to pass on its exact commit before publication.
- GitHub secret scanning and push protection are enabled; private vulnerability reporting is enabled; no secret-scanning alerts were returned. A history scan found no common OpenAI/Anthropic token, GitHub token, Google API key or private-key patterns. Pattern checks cannot prove absence of every possible secret.
- GitHub About text, six relevant topics, MIT license, release assets, issue templates and a custom social preview are present. Alternative-project links were opened successfully.

## Remaining validation and release checklist

1. **Resolve Claude credential use.** Anthropic's [credential-use documentation](https://code.claude.com/docs/en/legal-and-compliance#authentication-and-credential-use) restricts third-party handling/routing of subscription credentials. It does not establish an allowance for this monitor. Obtain explicit clarification or replace/remove direct subscription-token access. A disclaimer does not resolve this uncertainty. This is a policy risk assessment, not a legal determination.
2. **Keep the renewal wording accurate.** Anthropic's [CLI reference](https://code.claude.com/docs/en/cli-reference) describes `doctor` as diagnostics, without promising renewal. The documentation, menu, tooltip and changelog now describe the helper as experimental. Correct the v1.5.0 public release body before publishing v1.6.0; retain its original checksums and assets.
3. **Run a clean-user installation.** Test the published zip with its internet mark, extraction, warnings, default no choices, Start menu launch with no console, restart, startup on/off, upgrade and uninstall. Run without administrator rights. Also test the Scoop flow separately; Scoop was not installed/exercised here.
4. **Complete the Windows matrix.** Real-screen x64 Windows 11, Windows 10 1809+, bottom/top/vertical taskbars, mixed-DPI multiple monitors, secondary taskbars, auto-hide, fullscreen, sleep/wake, Explorer restart, monitor disconnect/reconnect and light taskbar. Current real-screen taskbar evidence remains Windows 11 ARM64 with a bottom dark single-monitor taskbar. Rendered light previews do not validate taskbar placement.
5. **Check lifecycle and usability manually.** Keyboard focus and screen reader names, hover details, drag/click distinction, recovery of a lost widget after monitor changes, idle CPU/memory and first scan on large logs. PowerShell 5.1 cannot guarantee terminating all descendants if an external CLI spawns subprocesses. Check that exit/upgrade leaves no orphan CLI process.
6. **Keep token value claims approximate.** Prices are a static snapshot, logs cover one PC, unsupported scopes are omitted and forks may contain inherited usage. Codex totals are accumulated per session file and inherited records may be counted more than once. This remains a known accounting limitation, not audited spending or guaranteed subscription savings. Additional Codex model-specific limit pools are not displayed.
7. **Publish the new versioned release.** AppVersion and changelog identify v1.6.0. Build matching assets and Scoop manifest, commit/push, wait for the changed CI matrix, then publish and download-check the new assets. Do not replace v1.5.0 downloads with changed bytes. The new zip includes the images referenced by README and this review; the script itself needs no image assets.

## GitHub description and promotion wording

Suggested About text:

> Windows taskbar widget for Claude Code and Codex usage limits, reset times, pace and run-out forecasts. Single PowerShell script; no additional runtime.

Until the gates above are resolved, describe it as **an experimental Windows utility tested on Windows 11 ARM64**. Say **API value estimate**, rather than verified savings. Include the provider-support limitations and link to SECURITY. Avoid “works on every Windows PC,” “official renewal,” “zero risk,” or “total assurance.”

The Codex interface is documented in the [official App Server reference](https://learn.chatgpt.com/docs/app-server). Static prices were checked against [Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing) and [OpenAI pricing](https://developers.openai.com/api/docs/pricing) on 2026-10-11.
