# github-backup

PowerShell 7+ tool for two things:

1. **One-time migration** of every repo from an old GitHub account to a new
   one (`Migrate-ToNewAccount.ps1`).
2. **Ongoing backup** of the new account's repos to GitLab (`backup.ps1`).

Both create destination repos as **private**. The old GitHub account is never
modified.

## Phase 1: migration (one-time)

For each repo owned by your old account (the `OldGitHubUser` in `config.psd1`):

1. If the new account doesn't already have a repo with that name, create one
   (private; description copied if `PreserveDescription`).
2. `git clone --mirror` from old (or fetch updates if cache exists).
3. If the repo uses LFS, fetch LFS blobs.
4. Point the cache's `origin` at the new account.
5. `git push --mirror` (and `git lfs push --all` if applicable) to the new
   account.
6. Set the new repo's default branch to match the source (if
   `PreserveDefaultBranch`).

Idempotent: safe to re-run after fixing partial failures.

## Phase 2: ongoing backup

For each repo owned by your new account (the `GitHubUser` in `config.psd1`):

1. `git remote update --prune` against the cache (origin already points at the
   new account after migration).
2. If LFS is in use, fetch LFS blobs.
3. Ensure a matching GitLab project exists under your personal namespace
   (`gitlab.com/<your-handle>/<repo>`); create private if not.
4. `git push --mirror` to GitLab (+ `git lfs push --all` if applicable).

Forks are skipped by default; archived repos are included. Both are
configurable.

## Requirements

- Windows 10/11
- PowerShell 7+ (`pwsh`)
- Git for Windows (with `git-lfs` if you use LFS)
- PATs:
  - **Old GitHub account** (configured via `OldGitHubUser`) — needed only
    during migration. Fine-grained PAT, read-only: `Contents: Read` +
    `Metadata: Read` on all repos.
  - **New GitHub account** (configured via `GitHubUser`). For
    migration it needs `Administration: Write` (to create repos) +
    `Contents: Read/Write` (to push) + `Workflows: Read/Write` (GitHub
    rejects pushes that touch `.github/workflows/*` without this) +
    `Metadata: Read`. For ongoing backup, only `Contents: Read` +
    `Metadata: Read` are required — you can rotate down to a read-only PAT
    after migration if you want.
  - **GitLab** PAT with `api` scope.
- No PowerShell module dependencies — the script talks to Windows Credential Manager directly via P/Invoke (the PSGallery `CredentialManager` module doesn't work in PS7).

## End-to-end workflow

```powershell
# 1. Copy the config template and edit it with your handles, cache path, etc.
#    config.psd1 is gitignored so your personal values are never committed.
Copy-Item config.example.psd1 config.psd1
# ...then edit config.psd1

# 2. Store the NEW-account GitHub PAT + GitLab PAT, register Event Log
#    source, create GitLab group.
pwsh -File .\Register-Setup.ps1

# 3. One-time: migrate old account -> new account. Will prompt for OLD PAT.
pwsh -File .\Migrate-ToNewAccount.ps1 -DryRun   # preview
pwsh -File .\Migrate-ToNewAccount.ps1           # do it

# 4. Ongoing: back up new account -> GitLab.
pwsh -File .\backup.ps1

# 5. Optional: schedule the ongoing backup.
pwsh -File .\Install-Schedule.ps1
```

### What `Register-Setup.ps1` does

- Self-elevates to admin (needed once to register the Event Log source)
- Prompts for the **new-account** GitHub PAT and the GitLab PAT
- Verifies the GitLab PAT works and reports the namespace mirrors will land
  in (`gitlab.com/<your-handle>/<repo>`)
- Creates the cache + log directories

### What `Migrate-ToNewAccount.ps1` does

- Prompts for the **old-account** PAT if not already stored
- Lists every repo on the old account, applying the same `SkipForks` /
  `SkipArchived` rules as backup
- For each repo: creates a private repo on the new account if needed,
  bare-mirrors it across, sets default branch, and repoints the cache's
  origin at the new account
- Pass `-DryRun` to see what would be migrated without doing anything

## Running a backup

Manually:

```powershell
pwsh -File .\backup.ps1
```

Output is written both to the console and to a timestamped log file under the
configured `LogPath`. Exit codes:

- `0` &mdash; all repos succeeded
- `1` &mdash; one or more repos failed (others may have succeeded)
- `2` &mdash; fatal error before per-repo work started

Per-repo failures continue with the next repo. Failures also write an entry to
the Windows Application Event Log under source `GitHubBackup`, so Task
Scheduler will surface them.

## Scheduling

```powershell
pwsh -File .\Install-Schedule.ps1            # daily 03:00, default
pwsh -File .\Install-Schedule.ps1 -Time 02:30 -Frequency Weekly
```

The task is registered as `Interactive`, which means it runs only while you
are logged on. If you need it to run when logged off, edit the task's
principal afterward (Task Scheduler &rarr; properties &rarr; security options),
which will require you to enter your Windows password.

## Configuration

`config.psd1`:

| Key | Default | Notes |
|---|---|---|
| `GitHubUser` | `your-github-username` | New primary account. Determines backup source and migration target. |
| `OldGitHubUser` | `your-old-github-username` | Migration source only. Not touched by `backup.ps1`. |
| `GitLabHost` | `https://gitlab.com` | Change for self-managed GitLab. |
| `CachePath` | `C:\github-backup-cache` | Bare clones, one per repo. Migration leaves these with `origin` pointing at the new account. Prefer a drive with room for a full mirror of every repo — point it at a data drive (e.g. `D:\`) if your system drive is small. |
| `LogPath` | `C:\github-backup-cache\logs` | One log file per run, timestamped. |
| `EventLogSource` | `GitHubBackup` | Windows Application Event Log source. |
| `GitHubCredentialName` | `github-backup/github-pat` | New-account PAT target name in Credential Manager. |
| `OldGitHubCredentialName` | `github-backup/old-github-pat` | Old-account PAT, only present during migration. |
| `GitLabCredentialName` | `github-backup/gitlab-pat` | GitLab PAT target name. |
| `LfsHandling` | `auto` | `auto` detects via `.gitattributes` per repo; `skip` never fetches LFS blobs. |
| `GitLabVisibility` | `private` | Visibility for newly created GitLab projects. |
| `NewGitHubVisibility` | `private` | Visibility for repos created on the new GitHub account during migration. Always `private` by design. |
| `PreserveDescription` | `$true` | Copy repo description across during migration. |
| `PreserveDefaultBranch` | `$true` | Set new repo's default branch to match the source. |
| `SkipForks` | `$true` | Forks usually duplicate upstream; skip by default. |
| `SkipArchived` | `$false` | Archived repos are included by default. |

## How it works

```
backup.ps1                  ongoing: new GitHub -> GitLab
Migrate-ToNewAccount.ps1    one-time: old GitHub -> new GitHub
Register-Setup.ps1          credential + group + event-log setup
Install-Schedule.ps1        register Task Scheduler entry
  + config.psd1
  + lib/
      Credentials.psm1   Windows Credential Manager wrappers
      GitHub.psm1        repo list/get/create + default-branch (REST)
      GitLab.psm1        Get current user + Get/New project (REST v4)
      Mirror.psm1        Sync-Mirror (backup) + Sync-MigrationMirror (one-time)
      Logging.psm1       Write-Log + Write-FailureToEventLog
```

Tokens are injected per git invocation via
`git -c http.<host>/.extraheader=Authorization: Basic <base64>` &mdash; they are
never written into the bare cache's git config or remote URLs.

Mirror semantics:

- `push --mirror` is a force-style operation that makes GitLab refs identical
  to the local cache. A branch deleted on GitHub disappears from GitLab on the
  next run.
- A whole repo deleted, renamed, or made private on GitHub simply stops
  appearing in the listing. The corresponding GitLab project is left untouched
  &mdash; cold backup behavior.
- A renamed GitHub repo becomes a new GitLab project under the new name; the
  old one becomes a stale snapshot.

## Troubleshooting

**`No stored credential named '...'`** &mdash; run `Register-Setup.ps1`. Credentials
are stored under your Windows user only; another user (or the same user after
profile reset) won't see them.

**`Could not write to Event Log`** &mdash; the source isn't registered. Run
`Register-Setup.ps1` once as admin (it self-elevates).

**Push to new GitHub fails with `refusing to allow a Personal Access Token to create or update workflow ... without 'workflow' scope`** &mdash; the new-account PAT is missing the `Workflows: Read and write` permission. Edit the PAT at https://github.com/settings/personal-access-tokens, add the permission, save, then re-run the migration. The fix is idempotent.

**GitLab returns `403 Forbidden` on project creation** &mdash; the new-account
identity-verification gate on gitlab.com. Visit
`https://gitlab.com/-/identity_verification` and complete it (typically by
adding a credit card &mdash; GitLab doesn't charge it). The gate only blocks
*top-level group* creation, not personal-namespace projects, so this is
unlikely to bite the current design.

**`git lfs: command not found`** &mdash; install Git LFS
(`winget install GitHub.GitLFS`) or set `LfsHandling = 'skip'` in
`config.psd1`.

**Scheduled task doesn't run** &mdash; the task is registered as `Interactive`, so
it only fires while you're logged on. To make it run while logged off, edit
the task's principal in Task Scheduler (you'll be prompted for your Windows
password).

## Contributing

Bug reports and pull requests are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md) for how to set up the pre-commit secret
scan and what to check before opening a PR.

## Security

This tool handles GitHub and GitLab access tokens. To report a vulnerability,
see [SECURITY.md](SECURITY.md) &mdash; please do not open a public issue for
security problems.

## License

Licensed under the [Apache License, Version 2.0](LICENSE). See [NOTICE](NOTICE)
for attribution details.
