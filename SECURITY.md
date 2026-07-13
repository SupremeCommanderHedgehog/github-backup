# Security Policy

github-backup handles GitHub and GitLab personal access tokens (PATs) and
mirrors repository contents. Please treat security reports seriously.

## Reporting a vulnerability

**Do not open a public GitHub issue for security problems.**

Instead, report privately through GitHub's
[private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability):
open the repository's **Security** tab and click **Report a vulnerability**.
This creates a private advisory visible only to you and the maintainers.

Please include:

- A description of the issue and its impact.
- Steps to reproduce, or a proof of concept.
- The affected script/module and version (commit SHA if possible).

You can expect an initial acknowledgement within a few days. Because this is a
personal project, response times are best-effort.

## Scope

Relevant concerns include, but are not limited to:

- Leakage of tokens from Windows Credential Manager, log files, transcripts,
  or the local git cache.
- Tokens being written into git config, remote URLs, or process arguments in a
  way that exposes them.
- Command injection via repository names or API-returned fields.

## What this tool does to protect secrets

- PATs are stored in Windows Credential Manager (per-user, local machine) via
  the native `Cred*` APIs, never in plaintext config.
- Tokens are injected per git invocation with
  `git -c http.<host>/.extraheader=...` and are **not** written into the bare
  cache's git config or remote URLs.
- `config.psd1` (your personal handles and paths) is gitignored.
- A gitleaks pre-commit hook and CI workflow scan for accidentally committed
  secrets, including a nightly full-history scan.

If you find a case where any of the above does not hold, that is exactly the
kind of report we want.
