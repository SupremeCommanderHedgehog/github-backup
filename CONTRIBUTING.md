# Contributing to github-backup

Thanks for your interest in improving github-backup. This is a small,
single-purpose PowerShell 7 tool; contributions that keep it focused and
dependency-free are especially welcome.

## Ground rules

- **No secrets in commits.** Never commit personal access tokens, real
  account handles, or machine-specific paths. Your live configuration lives
  in `config.psd1`, which is gitignored — edit a copy of
  `config.example.psd1`, not the template.
- **No new runtime dependencies.** The tool deliberately talks to the Windows
  Credential Manager via P/Invoke and to the GitHub/GitLab REST APIs directly,
  so it needs no PowerShell modules at runtime. Keep it that way unless there
  is a compelling reason.
- **Keep it idempotent.** Both `backup.ps1` and `Migrate-ToNewAccount.ps1`
  are safe to re-run. Preserve that property.

## Development setup

Requirements (see the README for detail):

- Windows 10/11
- PowerShell 7+ (`pwsh`)
- Git for Windows (with `git-lfs` if you test LFS paths)
- [pre-commit](https://pre-commit.com/) for the secret-scan hook

Install the secret-scanning pre-commit hook once per checkout:

```powershell
pip install pre-commit
pre-commit install
```

This runs [gitleaks](https://github.com/gitleaks/gitleaks) on every commit.
The same scan runs in CI (`.github/workflows/gitleaks.yml`) on push, pull
request, and nightly over the full history.

To scan the whole working tree manually:

```powershell
pre-commit run --all-files
```

## Making changes

1. Create a topic branch off `main`.
2. Make your change. Match the surrounding style: `Set-StrictMode -Version
   Latest`, `$ErrorActionPreference = 'Stop'`, approved PowerShell verbs, and
   comment-based help on public scripts/functions.
3. Test against your own accounts. There is no automated test harness, so
   exercise the affected path manually:
   - `Migrate-ToNewAccount.ps1 -DryRun` previews migration without side effects.
   - `backup.ps1` is safe to run repeatedly; check the timestamped log under
     your configured `LogPath`.
4. Make sure `pre-commit run --all-files` passes (no secrets, no gitleaks
   findings).
5. Open a pull request describing what changed and how you verified it.

## Reporting bugs and requesting features

Use the issue templates under
[.github/ISSUE_TEMPLATE](.github/ISSUE_TEMPLATE). Include your PowerShell and
Git versions and a relevant excerpt from the run log (with any tokens or
private handles redacted).

## Security issues

Please **do not** open a public issue for a security vulnerability. Follow the
process in [SECURITY.md](SECURITY.md) instead.

## License

By contributing, you agree that your contributions will be licensed under the
[Apache License, Version 2.0](LICENSE).
