<#
.SYNOPSIS
    aicc — AI Commit & Changelog Automation Engine (Self-Healing Edition)
    Automatically stages changes, generates ≤10-word AI commit messages,
    maintains custom changelogs/devlogs with 20+ file candidate autodetection,
    auto-initializes Git & private GitHub repos, resolves push divergences,
    and opens the repository in the user's default browser.

.DESCRIPTION
    Part of the aicc open-source CLI suite.
    Author: Oumar Ibrahim (IamOumarIbrahim)
    License: MIT
#>

[CmdletBinding()]
param(
    [string]$CustomMessage
)

$ErrorActionPreference = "Continue"

# =============================================================================
# SELF-HEALING STEP 0: Git Executable Discovery & Path Recovery
# =============================================================================
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    $commonGitPaths = @(
        "C:\Program Files\Git\cmd",
        "C:\Program Files\Git\bin",
        "$env:LOCALAPPDATA\Programs\Git\cmd",
        "$env:LOCALAPPDATA\Programs\Git\bin",
        "C:\Program Files (x86)\Git\cmd",
        "C:\ProgramData\chocolatey\bin"
    )
    foreach ($gp in $commonGitPaths) {
        if (Test-Path (Join-Path $gp "git.exe")) {
            $env:PATH = "$gp;$env:PATH"
            break
        }
    }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Error "Git is not installed or not found in PATH. Please install Git: https://git-scm.com/"
    return
}

# =============================================================================
# 1. Load Configuration & Environment Secrets
# =============================================================================
$userConfigDir = Join-Path $env:USERPROFILE ".aicc"
$scriptConfigDir = $PSScriptRoot

$config = [PSCustomObject]@{
    cli_provider             = "codex"
    log_filename             = ""
    auto_create_private_repo = $true
    default_branch           = "main"
    max_commit_words         = 10
    changelog_bullets_count  = 3
    open_web_on_push         = $true
    openai_model             = "gpt-4o-mini"
    anthropic_model          = "claude-3-5-haiku-20241022"
}

# Config file discovery hierarchy: User global -> Script local -> Repo override
$configPaths = @(
    (Join-Path $userConfigDir "config.json"),
    (Join-Path $scriptConfigDir "config.json"),
    (Join-Path (Get-Location) ".aicc.json"),
    (Join-Path (Get-Location) "aicc.json")
)

foreach ($cp in $configPaths) {
    if (Test-Path $cp) {
        try {
            $json = Get-Content -Path $cp -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
            if ($json) {
                foreach ($prop in $json.PSObject.Properties) {
                    if ($null -ne $prop.Value -and $prop.Value -ne "") {
                        $config | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $prop.Value -Force
                    }
                }
            }
        } catch {}
    }
}

# Environment secrets discovery hierarchy: User global -> Script local -> Current Repo
$envPaths = @(
    (Join-Path $userConfigDir ".env"),
    (Join-Path $scriptConfigDir ".env"),
    (Join-Path (Get-Location) ".env")
)

foreach ($ep in $envPaths) {
    if (Test-Path $ep) {
        Get-Content -Path $ep -ErrorAction SilentlyContinue | ForEach-Object {
            $line = $_.Trim()
            if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
                $idx = $line.IndexOf("=")
                $key = $line.Substring(0, $idx).Trim()
                $val = $line.Substring($idx + 1).Trim().Trim('"').Trim("'")
                if (-not [System.Environment]::GetEnvironmentVariable($key)) {
                    [System.Environment]::SetEnvironmentVariable($key, $val, "Process")
                }
            }
        }
    }
}

# =============================================================================
# SELF-HEALING STEP 1: Git User Identity Auto-Configuration
# =============================================================================
$userName = git config user.name 2>$null
$userEmail = git config user.email 2>$null

if (-not $userName -or -not $userEmail) {
    $ghUser = $null
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $ghUser = gh api user --jq .login 2>$null
    }
    if (-not $userName) {
        $fallbackName = if ($ghUser) { $ghUser } elseif ($env:USERNAME) { $env:USERNAME } else { "aicc-user" }
        git config user.name "$fallbackName"
    }
    if (-not $userEmail) {
        $fallbackEmail = if ($ghUser) { "$ghUser@users.noreply.github.com" } else { "user@local.dev" }
        git config user.email "$fallbackEmail"
    }
}

# =============================================================================
# SELF-HEALING STEP 2: Repository Check & Auto-Creation
# =============================================================================
$isGit = git rev-parse --is-inside-work-tree 2>$null
if ($LASTEXITCODE -ne 0 -or $isGit -ne 'true') {
    if ($config.auto_create_private_repo) {
        Write-Host "Not inside a git repository. Auto-initializing git repository..." -ForegroundColor Cyan
        $branchName = if ($config.default_branch) { $config.default_branch } else { "main" }
        git init -b $branchName 2>$null
        if ($LASTEXITCODE -ne 0) {
            git init
            git checkout -B $branchName 2>$null
        }

        # Check GitHub CLI authentication to create remote private repo
        $ghAuth = gh auth status 2>&1
        if ($LASTEXITCODE -eq 0) {
            $repoName = Split-Path -Leaf (Get-Location).ProviderPath
            Write-Host "Creating private GitHub repository '$repoName'..." -ForegroundColor Cyan
            gh repo create $repoName --private --source=. --remote=origin 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Created and linked private GitHub repository: $repoName" -ForegroundColor Green
            } else {
                Write-Host "Local repository initialized. (GitHub remote creation skipped or already exists)." -ForegroundColor Yellow
            }
        } else {
            Write-Host "GitHub CLI (gh) not logged in. Local git repository initialized." -ForegroundColor Yellow
        }
    } else {
        Write-Warning "Not inside a git repository."
        return
    }
}

$gitRoot = (git rev-parse --show-toplevel 2>$null).Trim()
if (-not $gitRoot) {
    $gitRoot = (Get-Location).ProviderPath
}

# Auto-heal missing remote origin if GitHub CLI is logged in
$remoteOrigin = git remote get-url origin 2>$null
if (-not $remoteOrigin -and $config.auto_create_private_repo) {
    $ghAuth = gh auth status 2>&1
    if ($LASTEXITCODE -eq 0) {
        $repoName = Split-Path -Leaf $gitRoot
        Write-Host "No remote origin detected. Creating private GitHub repository '$repoName'..." -ForegroundColor Cyan
        gh repo create $repoName --private --source=. --remote=origin 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Linked private GitHub repository: $repoName" -ForegroundColor Green
        }
    }
}

# =============================================================================
# 3. Stage Changes & Check Working Tree
# =============================================================================
git add .

$staged = git status --porcelain
if (-not $staged) {
    Write-Host "Nothing to commit, working tree clean." -ForegroundColor Yellow
    return
}

# =============================================================================
# SELF-HEALING STEP 3: Multi-Candidate Devlog / Changelog Discovery (20+ Candidates)
# =============================================================================
$targetLogFile = $null
$hasLogFile = $false

# 3a. If user specified a file in config, check it first
if ($config.log_filename -and $config.log_filename.Trim() -ne "") {
    $configuredName = $config.log_filename.Trim()
    $match = Get-ChildItem -Path $gitRoot -File -Depth 0 -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq $configuredName } | Select-Object -First 1
    if ($match) {
        $targetLogFile = $match.FullName
        $hasLogFile = $true
    } else {
        # If user explicitly configured a name, target it for creation/append
        $targetLogFile = Join-Path $gitRoot $configuredName
        $hasLogFile = Test-Path $targetLogFile
    }
}

# 3b. Self-healing fallback: If not found or not specified, check 20+ standard logging patterns in root
if (-not $hasLogFile) {
    $candidateLogNames = @(
        "CHANGELOG.md", "changelog.md", "ChangeLog.md",
        "CHANGES.md", "changes.md",
        "DEVLOG.md", "devlog.md", "DevLog.md",
        "DEV.md", "dev.md",
        "LOGGING.md", "logging.md",
        "LOG.md", "log.md",
        "LOGS.md", "logs.md",
        "HISTORY.md", "history.md",
        "RELEASES.md", "releases.md",
        "RELEASE_NOTES.md", "release-notes.md",
        "UPDATES.md", "updates.md",
        "WORKLOG.md", "worklog.md",
        "NOTES.md", "notes.md",
        "CHANGELOG.txt", "devlog.txt", "log.txt", "changes.txt"
    )

    $rootFiles = Get-ChildItem -Path $gitRoot -File -Depth 0 -ErrorAction SilentlyContinue
    
    # Check exact candidates
    foreach ($cand in $candidateLogNames) {
        $found = $rootFiles | Where-Object { $_.Name -ieq $cand } | Select-Object -First 1
        if ($found) {
            $targetLogFile = $found.FullName
            $hasLogFile = $true
            Write-Host "Self-healed: Auto-detected log file '$($found.Name)'" -ForegroundColor DarkCyan
            break
        }
    }

    # Fuzzy regex fallback for any root markdown file related to logs/changes
    if (-not $hasLogFile) {
        $fuzzyMatch = $rootFiles | Where-Object { $_.Name -match '(?i)(change|log|history|dev|release|update|work).*\.(md|markdown|txt)$' } | Select-Object -First 1
        if ($fuzzyMatch) {
            $targetLogFile = $fuzzyMatch.FullName
            $hasLogFile = $true
            Write-Host "Self-healed: Auto-detected log file '$($fuzzyMatch.Name)'" -ForegroundColor DarkCyan
        }
    }
}

# =============================================================================
# 4. Extract Staged Diff & Summary
# =============================================================================
$stat = git diff --cached --stat
$diffSample = (git diff --cached | Select-Object -First 300) -join "`n"
$context = "$stat`n`n$diffSample"

$provider = ($config.cli_provider + "").ToLower().Trim()
$providerDisplay = switch ($provider) {
    "claude"   { "Claude Code" }
    "anthropic"{ "Anthropic Claude" }
    "openai"   { "OpenAI" }
    default    { "Codex" }
}

$logDisplay = if ($hasLogFile) { "& $(Split-Path $targetLogFile -Leaf) " } else { "" }
Write-Host "Generating AI commit message $logDisplaywith $providerDisplay..." -ForegroundColor Cyan

$prompt = @"
Analyze the staged git changes below.
1. Generate ONE short meaningful git commit message (max 10 words, no punctuation, no quotes, no markdown).
2. Generate EXACTLY 3 concise bullet points for the biggest changes (each starting with '- ').

Output EXACTLY in this format:
COMMIT: <commit message>
CHANGELOG:
- <change 1>
- <change 2>
- <change 3>

Staged summary and diff:
$context
"@

# =============================================================================
# SELF-HEALING STEP 4: Cascaded Multi-Tier AI Execution & Fail-Proof Fallback
# =============================================================================
$rawOutput = ""
$tmpFile = [System.IO.Path]::GetTempFileName()

if ($CustomMessage) {
    $rawOutput = "COMMIT: $CustomMessage`nCHANGELOG:`n- $CustomMessage`n- Minor project improvements`n- Codebase maintenance"
}

if (-not $rawOutput) {
    try {
        if ($provider -eq "claude" -or $provider -eq "anthropic") {
            # Tier 1: Local Claude CLI
            if (Get-Command claude.cmd -ErrorAction SilentlyContinue) {
                $rawOutput = & claude.cmd -p "$prompt" 2>$null
            } elseif (Get-Command claude -ErrorAction SilentlyContinue) {
                $rawOutput = & claude -p "$prompt" 2>$null
            }
            
            # Tier 2: Direct Anthropic REST API Fallback
            if (-not $rawOutput -and $env:ANTHROPIC_API_KEY) {
                $body = @{
                    model      = if ($config.anthropic_model) { $config.anthropic_model } else { "claude-3-5-haiku-20241022" }
                    max_tokens = 300
                    messages   = @(@{ role = "user"; content = $prompt })
                } | ConvertTo-Json -Depth 5

                $headers = @{
                    "x-api-key"         = $env:ANTHROPIC_API_KEY
                    "anthropic-version" = "2023-06-01"
                    "content-type"      = "application/json"
                }

                $response = Invoke-RestMethod -Uri "https://api.anthropic.com/v1/messages" -Method Post -Headers $headers -Body $body -TimeoutSec 15 -ErrorAction SilentlyContinue
                if ($response -and $response.content -and $response.content.Count -gt 0) {
                    $rawOutput = $response.content[0].text
                }
            }

            # Tier 3: NPX Claude Runner
            if (-not $rawOutput) {
                $rawOutput = npx -y @anthropic-ai/claude-code -p "$prompt" 2>$null
            }
        } else {
            # Tier 1: Local Codex CLI
            $codexJs = "$env:APPDATA\npm\node_modules\@openai\codex\bin\codex.js"
            if (Test-Path $codexJs) {
                $prompt | node $codexJs exec --skip-git-repo-check - -o $tmpFile 2>$null
                if (Test-Path $tmpFile) { $rawOutput = Get-Content $tmpFile -Raw -ErrorAction SilentlyContinue }
            } elseif (Get-Command codex.cmd -ErrorAction SilentlyContinue) {
                $prompt | & codex.cmd exec --skip-git-repo-check - -o $tmpFile 2>$null
                if (Test-Path $tmpFile) { $rawOutput = Get-Content $tmpFile -Raw -ErrorAction SilentlyContinue }
            } elseif (Get-Command codex -ErrorAction SilentlyContinue) {
                $prompt | & codex exec --skip-git-repo-check - -o $tmpFile 2>$null
                if (Test-Path $tmpFile) { $rawOutput = Get-Content $tmpFile -Raw -ErrorAction SilentlyContinue }
            }

            # Tier 2: Direct OpenAI REST API Fallback
            if (-not $rawOutput -and $env:OPENAI_API_KEY) {
                $body = @{
                    model       = if ($config.openai_model) { $config.openai_model } else { "gpt-4o-mini" }
                    messages    = @(@{ role = "user"; content = $prompt })
                    max_tokens  = 300
                    temperature = 0.2
                } | ConvertTo-Json -Depth 5

                $headers = @{
                    "Authorization" = "Bearer $env:OPENAI_API_KEY"
                    "Content-Type"  = "application/json"
                }

                $response = Invoke-RestMethod -Uri "https://api.openai.com/v1/chat/completions" -Method Post -Headers $headers -Body $body -TimeoutSec 15 -ErrorAction SilentlyContinue
                if ($response -and $response.choices -and $response.choices.Count -gt 0) {
                    $rawOutput = $response.choices[0].message.content
                }
            }

            # Tier 3: NPX Codex Runner
            if (-not $rawOutput) {
                $prompt | npx -y @openai/codex exec --skip-git-repo-check - -o $tmpFile 2>$null
                if (Test-Path $tmpFile) { $rawOutput = Get-Content $tmpFile -Raw -ErrorAction SilentlyContinue }
            }
        }

        # Tier 4: Cross-Provider Key Auto-Recovery
        if (-not $rawOutput) {
            if ($env:OPENAI_API_KEY) {
                $body = @{
                    model       = "gpt-4o-mini"
                    messages    = @(@{ role = "user"; content = $prompt })
                    max_tokens  = 300
                    temperature = 0.2
                } | ConvertTo-Json -Depth 5
                $headers = @{ "Authorization" = "Bearer $env:OPENAI_API_KEY"; "Content-Type" = "application/json" }
                $response = Invoke-RestMethod -Uri "https://api.openai.com/v1/chat/completions" -Method Post -Headers $headers -Body $body -TimeoutSec 10 -ErrorAction SilentlyContinue
                if ($response -and $response.choices -and $response.choices.Count -gt 0) {
                    $rawOutput = $response.choices[0].message.content
                }
            } elseif ($env:ANTHROPIC_API_KEY) {
                $body = @{
                    model      = "claude-3-5-haiku-20241022"
                    max_tokens = 300
                    messages   = @(@{ role = "user"; content = $prompt })
                } | ConvertTo-Json -Depth 5
                $headers = @{ "x-api-key" = $env:ANTHROPIC_API_KEY; "anthropic-version" = "2023-06-01"; "content-type" = "application/json" }
                $response = Invoke-RestMethod -Uri "https://api.anthropic.com/v1/messages" -Method Post -Headers $headers -Body $body -TimeoutSec 10 -ErrorAction SilentlyContinue
                if ($response -and $response.content -and $response.content.Count -gt 0) {
                    $rawOutput = $response.content[0].text
                }
            }
        }
    } catch {
        Write-Warning "AI Execution Exception: $($_.Exception.Message)"
    } finally {
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# SELF-HEALING STEP 5: Deterministic Git Commit & Changelog Synthesizer
# (Ensures the commit NEVER fails even without network or AI keys)
# =============================================================================
$msg = ""
$changelogItems = @()

if ($rawOutput) {
    if ($rawOutput -match '(?ms)COMMIT:\s*([^\r\n]+)') {
        $msg = $matches[1].Trim().Trim('"').Trim("'").Trim('`')
    }

    if ($rawOutput -match '(?ms)CHANGELOG:\s*([\s\S]+)$') {
        $changelogBlock = $matches[1].Trim()
        $lines = $changelogBlock -split "`r?`n" | Where-Object { $_.Trim() -ne '' }
        $changelogItems = @($lines | ForEach-Object {
            $l = $_.Trim()
            if ($l -notmatch '^[-*•]') { "- $l" } else { $l }
        })
    }

    if (-not $msg) {
        $firstLine = ($rawOutput -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1)
        if ($firstLine) {
            $msg = $firstLine.Trim().Trim('"').Trim("'").Trim('`')
        }
    }
}

# If AI generation failed completely, synthesize from staged file statistics
if (-not $msg) {
    Write-Host "Self-healed: Synthesizing deterministic commit summary from staged files..." -ForegroundColor Yellow
    $stagedFiles = git diff --cached --name-only | Where-Object { $_.Trim() -ne '' }
    $fileCount = $stagedFiles.Count
    
    if ($fileCount -eq 1) {
        $singleFile = Split-Path $stagedFiles[0] -Leaf
        $msg = "Update $singleFile"
    } elseif ($fileCount -le 3) {
        $leafNames = ($stagedFiles | ForEach-Object { Split-Path $_ -Leaf }) -join " and "
        $msg = "Update $leafNames"
    } else {
        $primary = Split-Path $stagedFiles[0] -Leaf
        $msg = "Update $primary and $($fileCount - 1) other files"
    }

    $changelogItems = @(
        "- Update staged codebase files and documentation",
        "- Synchronize repository state and configurations",
        "- Maintain project structure and dependencies"
    )
}

# Clean message punctuation and enforce max word limit
if ($msg) {
    $msg = $msg -replace '^[#\-*\s]+', '' -replace '[\r\n]+', ' '
    $words = $msg -split '\s+'
    $maxWords = if ($config.max_commit_words) { [int]$config.max_commit_words } else { 10 }
    if ($words.Count -gt $maxWords) {
        $msg = ($words[0..($maxWords - 1)] -join ' ')
    }
}

# =============================================================================
# SELF-HEALING STEP 6: Resilient Log / Changelog Appender
# =============================================================================
if ($hasLogFile -and $targetLogFile) {
    $timeStr = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $bulletCount = if ($config.changelog_bullets_count) { [int]$config.changelog_bullets_count } else { 3 }
    $itemsList = if ($changelogItems.Count -gt 0) {
        ($changelogItems | Select-Object -First $bulletCount) -join "`n"
    } else {
        "- $msg"
    }

    $existing = Get-Content $targetLogFile -Raw -ErrorAction SilentlyContinue
    $headerLine = "## [$timeStr] - $msg"

    $entry = if ([string]::IsNullOrWhiteSpace($existing)) {
        "$headerLine`n$itemsList`n"
    } elseif ($existing.EndsWith("`n`n") -or $existing.EndsWith("`r`n`r`n")) {
        "$headerLine`n$itemsList`n"
    } elseif ($existing.EndsWith("`n") -or $existing.EndsWith("`r`n")) {
        "`n$headerLine`n$itemsList`n"
    } else {
        "`n`n$headerLine`n$itemsList`n"
    }

    [System.IO.File]::AppendAllText($targetLogFile, $entry, [System.Text.Encoding]::UTF8)
    git add $targetLogFile
    Write-Host "Appended changes to $(Split-Path $targetLogFile -Leaf) (push time: $timeStr)" -ForegroundColor Cyan
}

# =============================================================================
# SELF-HEALING STEP 7: Commit & Push with Divergence & Upstream Recovery
# =============================================================================
Write-Host "Commit: $msg" -ForegroundColor Green
git commit -m "$msg"
if ($LASTEXITCODE -ne 0) {
    Write-Warning "git commit failed."
    return
}

Write-Host "Pushing to remote..." -ForegroundColor Cyan
git push 2>$null

if ($LASTEXITCODE -ne 0) {
    $branch = (git rev-parse --abbrev-ref HEAD 2>$null).Trim()
    if (-not $branch -or $branch -eq "HEAD") {
        $branch = if ($config.default_branch) { $config.default_branch } else { "main" }
    }
    
    # Retry 1: Set upstream branch
    git push -u origin $branch 2>$null
    
    # Retry 2: If rejected due to remote changes/divergence, auto rebase and push
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Self-healing: Remote diverged. Pulling and rebasing..." -ForegroundColor Yellow
        git pull --rebase origin $branch 2>$null
        git push -u origin $branch 2>$null
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "git push failed or no remote configured."
        return
    }
}

# =============================================================================
# SELF-HEALING STEP 8: Browser Launcher & Web URL Normalizer
# =============================================================================
Write-Host "Opening repository in browser..." -ForegroundColor Cyan
$opened = $false

if (Get-Command gh -ErrorAction SilentlyContinue) {
    gh repo view --web 2>$null
    if ($LASTEXITCODE -eq 0) {
        $opened = $true
    }
}

if (-not $opened) {
    $remoteUrl = git remote get-url origin 2>$null
    if ($remoteUrl) {
        $webUrl = $null
        if ($remoteUrl -match 'github\.com[:/]([^/]+)/([^/\.]+)(\.git)?') {
            $webUrl = "https://github.com/$($matches[1])/$($matches[2])"
        } elseif ($remoteUrl -match 'gitlab\.com[:/]([^/]+)/([^/\.]+)(\.git)?') {
            $webUrl = "https://gitlab.com/$($matches[1])/$($matches[2])"
        } elseif ($remoteUrl -match '^https?://') {
            $webUrl = $remoteUrl -replace '\.git$', ''
        }
        
        if ($webUrl) {
            try {
                Start-Process $webUrl
                $opened = $true
            } catch {
                Write-Host "Repository URL: $webUrl" -ForegroundColor Green
            }
        }
    }
}
