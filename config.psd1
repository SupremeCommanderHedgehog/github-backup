@{
    # === Primary GitHub source (used by backup.ps1) ===
    GitHubUser                = 'your-github-username'
    GitHubCredentialName      = 'github-backup/github-pat'

    # === Old GitHub account (used by Migrate-ToNewAccount.ps1 only) ===
    OldGitHubUser             = 'your-old-github-username'
    OldGitHubCredentialName   = 'github-backup/old-github-pat'

    # === GitLab destination ===
    # Mirrors are created in the authenticated user's personal namespace,
    # i.e. gitlab.com/<your-handle>/<repo>. Top-level groups were avoided
    # because gitlab.com gates that operation behind identity verification
    # for new accounts.
    GitLabHost                = 'https://gitlab.com'
    GitLabCredentialName      = 'github-backup/gitlab-pat'

    # === Local cache ===
    CachePath                 = 'D:\github-backup-cache'
    LogPath                   = 'D:\github-backup-cache\logs'

    # === Logging ===
    EventLogSource            = 'GitHubBackup'

    # === Behavior: backup ===
    LfsHandling               = 'auto'      # 'auto' or 'skip'
    GitLabVisibility          = 'private'   # all GitLab mirrors land private regardless of source visibility
    SkipForks                 = $true
    SkipArchived              = $false

    # === Behavior: migration ===
    NewGitHubVisibility       = 'private'   # new GitHub repos always created private (user decides later when to make public)
    PreserveDescription       = $true
    PreserveDefaultBranch     = $true
}
