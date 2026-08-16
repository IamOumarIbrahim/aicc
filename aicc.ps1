<#
.SYNOPSIS
    aicc — AI Commit & Changelog Automation Engine
    Automatically stages changes, generates ≤10-word AI commit messages,
    maintains custom changelogs (CHANGELOG.md, dev.md, logging.md),
    creates private GitHub repos if needed, and pushes to remote.

.DESCRIPTION
    Part of the aicc open-source CLI suite.
    Author: Oumar Ibrahim (IamOumarIbrahim)
    License: MIT
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"

# -----------------------------------------------------------------------------
# 1. Load Configuration and Environment Secrets
# -----------------------------------------------------------------------------
$userConfigDir = Join-Path $env:USERPROFILE ".aicc"
$scriptConfigDir = $PSScriptRoot

$config = [PSCustomObject]@{
    cli_provider             = "codex"
    log_filename             = "CHANGELOG.md"
    auto_create_private_repo = $true
    default_branch           = "main"
    max_commit_words         = 10
    changelog_bullets_count  = 3
    open_web_on_push         = $true
    openai_model             = "gpt-4o-mini"
    anthropic_model          = "claude-3-5-haiku-20241022"
}

# Config file candidate search (User global -> Script local -> Current repo)
$configPaths = @(
    (Join-Path $userConfigDir "config.json"),
    (Join-Path $scriptConfigDir "config.json"),
    (Join-Path (Get-Location) ".aicc.json")
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

# Load .env secrets (User global -> Script local -> Current repo)
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

# -----------------------------------------------------------------------------
# 2. Check / Initialize Git Repository & Remote
# -----------------------------------------------------------------------------
$isGit = git rev-parse --is-inside-work-tree 2>$null
if ($LASTEXITCODE -ne 0 -or $isGit -ne 'true') {
    if ($config.auto_create_private_repo) {
        Write-Host "Not inside a git repository. Initializing new git repository..." -ForegroundColor Cyan
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

# If in a git repo but remote origin is missing, try to auto-create & link private repo if gh is authenticated
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

# -----------------------------------------------------------------------------
# 3. Stage Changes & Check Working Tree
# -----------------------------------------------------------------------------
git add .

$staged = git status --porcelain
if (-not $staged) {
    Write-Host "Nothing to commit, working tree clean." -ForegroundColor Yellow
    return
}

# -----------------------------------------------------------------------------
# 4. Locate Configured Logging / Changelog File
# -----------------------------------------------------------------------------
$targetLogName = if ($config.log_filename) { $config.log_filename } else { "CHANGELOG.md" }
$logFileItem = Get-ChildItem -Path $gitRoot -File -Depth 0 -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq $targetLogName } | Select-Object -First 1
$logPath = if ($logFileItem) { $logFileItem.FullName } else { Join-Path $gitRoot $targetLogName }
$hasLogFile = Test-Path $logPath

# -----------------------------------------------------------------------------
# 5. Extract Staged Diff & Summary
# -----------------------------------------------------------------------------
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

Write-Host "Generating AI commit message $(if ($hasLogFile) { "& $(Split-Path $logPath -Leaf) " } else { '' })with $providerDisplay..." -ForegroundColor Cyan

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

# -----------------------------------------------------------------------------
# 6. Execute AI Engine (CLI or Direct API Fallback)
# -----------------------------------------------------------------------------
$rawOutput = ""
$tmpFile = [System.IO.Path]::GetTempFileName()

try {
    if ($provider -eq "claude" -or $provider -eq "anthropic") {
        # 6a. Claude Code CLI or Direct Anthropic API
        if (Get-Command claude.cmd -ErrorAction SilentlyContinue) {
            $rawOutput = & claude.cmd -p "$prompt" 2>$null
        } elseif (Get-Command claude -ErrorAction SilentlyContinue) {
            $rawOutput = & claude -p "$prompt" 2>$null
        } elseif ($env:ANTHROPIC_API_KEY) {
            # Direct Anthropic REST API Fallback
            $body = @{
                model      = if ($config.anthropic_model) { $config.anthropic_model } else { "claude-3-5-haiku-20241022" }
                max_tokens = 300
                messages   = @(
                    @{
                        role    = "user"
                        content = $prompt
                    }
                )
            } | ConvertTo-Json -Depth 5

            $headers = @{
                "x-api-key"         = $env:ANTHROPIC_API_KEY
                "anthropic-version" = "2023-06-01"
                "content-type"      = "application/json"
            }

            $response = Invoke-RestMethod -Uri "https://api.anthropic.com/v1/messages" -Method Post -Headers $headers -Body $body -ErrorAction SilentlyContinue
            if ($response -and $response.content -and $response.content.Count -gt 0) {
                $rawOutput = $response.content[0].text
            }
        } else {
            # Fallback to npx claude-code
            $rawOutput = npx -y @anthropic-ai/claude-code -p "$prompt" 2>$null
        }
    } else {
        # 6b. Codex CLI or Direct OpenAI API
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
        } elseif ($env:OPENAI_API_KEY) {
            # Direct OpenAI REST API Fallback
            $body = @{
                model       = if ($config.openai_model) { $config.openai_model } else { "gpt-4o-mini" }
                messages    = @(
                    @{
                        role    = "user"
                        content = $prompt
                    }
                )
                max_tokens  = 300
                temperature = 0.2
            } | ConvertTo-Json -Depth 5

            $headers = @{
                "Authorization" = "Bearer $env:OPENAI_API_KEY"
                "Content-Type"  = "application/json"
            }

            $response = Invoke-RestMethod -Uri "https://api.openai.com/v1/chat/completions" -Method Post -Headers $headers -Body $body -ErrorAction SilentlyContinue
            if ($response -and $response.choices -and $response.choices.Count -gt 0) {
                $rawOutput = $response.choices[0].message.content
            }
        } else {
            $prompt | npx -y @openai/codex exec --skip-git-repo-check - -o $tmpFile 2>$null
            if (Test-Path $tmpFile) { $rawOutput = Get-Content $tmpFile -Raw -ErrorAction SilentlyContinue }
        }
    }
} catch {
    Write-Warning "AI Execution Exception: $($_.Exception.Message)"
} finally {
    Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
# 7. Parse AI Commit Message and Changelog Bullets
# -----------------------------------------------------------------------------
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

# Clean message punctuation and limit word count
if ($msg) {
    $msg = $msg -replace '^[#\-*\s]+', ''
    $words = $msg -split '\s+'
    if ($words.Count -gt 10) {
        $msg = ($words[0..9] -join ' ')
    }
}

if (-not $msg) {
    Write-Warning "$providerDisplay failed to generate a commit message. Aborting commit."
    return
}

# -----------------------------------------------------------------------------
# 8. Append to Changelog / Logging File (if exists in repo root)
# -----------------------------------------------------------------------------
if ($hasLogFile) {
    $timeStr = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $bulletCount = if ($config.changelog_bullets_count) { $config.changelog_bullets_count } else { 3 }
    $itemsList = if ($changelogItems.Count -gt 0) {
        ($changelogItems | Select-Object -First $bulletCount) -join "`n"
    } else {
        "- $msg"
    }

    $existing = Get-Content $logPath -Raw -ErrorAction SilentlyContinue
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

    [System.IO.File]::AppendAllText($logPath, $entry, [System.Text.Encoding]::UTF8)
    git add $logPath
    Write-Host "Appended changes to $(Split-Path $logPath -Leaf) (push time: $timeStr)" -ForegroundColor Cyan
}

# -----------------------------------------------------------------------------
# 9. Commit and Push
# -----------------------------------------------------------------------------
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
    if ($branch) {
        git push -u origin $branch
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "git push failed or no remote configured."
        return
    }
}

# -----------------------------------------------------------------------------
# 10. View Web Repository
# -----------------------------------------------------------------------------
if ($config.open_web_on_push -and (Get-Command gh -ErrorAction SilentlyContinue)) {
    gh repo view --web 2>$null
}
