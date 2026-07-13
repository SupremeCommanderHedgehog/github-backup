@{
    # PSScriptAnalyzer configuration for the CI Lint workflow
    # (.github/workflows/lint.yml). Run locally with:
    #   Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1

    # Only Warning/Error break the build. Information-level rules
    # (comment-based help, OutputType) are advisory and not enforced.
    Severity = @('Error', 'Warning')

    # Rules excluded by deliberate design decisions for this tool:
    ExcludeRules = @(
        # This is an interactive console tool; its user-facing output is
        # intentionally Write-Host (colored status, prompts). Write-Output
        # would pollute the pipeline/return values.
        'PSAvoidUsingWriteHost'

        # A UTF-8 BOM is undesirable here: the files are committed LF/UTF-8
        # for cross-platform friendliness and a BOM breaks some tooling.
        'PSUseBOMForUnicodeEncodedFile'

        # The New-/Set-/Remove- helpers are thin internal wrappers around REST
        # and native APIs; full ShouldProcess/-WhatIf plumbing is out of scope
        # for these. (A possible future enhancement, not a correctness issue.)
        'PSUseShouldProcessForStateChangingFunctions'

        # Renaming already-exported functions (Get-GitHubHeaders,
        # Test-GitHubBranchExists, Test-RepoUsesLfs) would be a breaking API
        # change to the modules for no real benefit.
        'PSUseSingularNouns'

        # Write-Log is our internal logging helper in lib/Logging.psm1; the
        # built-in-cmdlet warning is a false positive in this context.
        'PSAvoidOverwritingBuiltInCmdlets'
    )
}
