## Summary

What does this change do, and why?

## Related issue

Closes #

## How was this tested?

There is no automated test harness, so describe the manual verification you ran:

- [ ] `Migrate-ToNewAccount.ps1 -DryRun` (if migration paths changed)
- [ ] `backup.ps1` against my own account
- [ ] Other:

## Checklist

- [ ] No secrets, real account handles, or machine-specific paths are committed
- [ ] `pre-commit run --all-files` passes (gitleaks finds nothing)
- [ ] No new runtime dependencies (or justified above)
- [ ] Style matches surrounding code (StrictMode, `$ErrorActionPreference = 'Stop'`, approved verbs)
- [ ] README / config template updated if behavior or config keys changed
