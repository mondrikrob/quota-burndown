# PSScriptAnalyzer settings for QuotaBurndown.ps1. The excluded rules are about
# module/cmdlet style and do not fit a single-file desktop script:
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Empty catch blocks are deliberate: optional steps (log, cache, icon, settings
        # file) must never stop the widget. Every network and credential path reports
        # its errors through the result or widget.log instead.
        'PSAvoidUsingEmptyCatchBlock'
        # Internal helpers, not exported cmdlets: no -WhatIf/-Confirm, and names such as
        # Read-Settings or Format-Tokens read better in plural.
        'PSUseShouldProcessForStateChangingFunctions'
        'PSUseSingularNouns'
        # Write-Host is used only for the interactive questions in -Install.
        'PSAvoidUsingWriteHost'
        # WPF and WinForms event handlers must declare ($s, $e) even when they use one.
        'PSReviewUnusedParameter'
        # The file path of the credentials file is not a password.
        'PSAvoidUsingPlainTextForPassword'
    )
}
