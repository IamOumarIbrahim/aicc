<#
.SYNOPSIS
    aicc Setup Wizard & Global Configurator
    Configures AI provider, API keys, custom log filename, and installs
    the global `aicc` command into PATH and PowerShell profiles.

.DESCRIPTION
    Part of the aicc open-source CLI suite.
    Author: Oumar Ibrahim (IamOumarIbrahim)
    License: MIT
#>

[CmdletBinding()]
param(
    [string]$Provider,
    [string]$ApiKey,
    [string]$LogFile,
    [switch]$NonInteractive,
    [switch]$SkipPathUpdate
)

$ErrorActionPreference = "Continue"

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "         aicc Configuration & Setup Wizard             " -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""

$configDir = Join-Path $env:USERPROFILE ".aicc"
if (-not (Test-Path $configDir)) {
    New-Item -Path $configDir -ItemType Directory -Force | Out-Null
}

$configJsonPath = Join-Path $configDir "config.json"
$envFilePath = Join-Path $configDir ".env"

# Existing values
$existingConfig = @{
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

if (Test-Path $configJsonPath) {
    try {
        $loaded = Get-Content $configJsonPath -Raw | ConvertFrom-Json
        if ($loaded) {
            foreach ($p in $loaded.PSObject.Properties) {
                $existingConfig[$p.Name] = $p.Value
            }
        }
    } catch {}
}

# -----------------------------------------------------------------------------
# 1. CLI Engine Selection
# -----------------------------------------------------------------------------
$selectedProvider = $Provider
if (-not $selectedProvider -and -not $NonInteractive) {
    Write-Host "Choose your AI CLI Engine / Provider:" -ForegroundColor Yellow
    Write-Host "  [1] OpenAI Codex (@openai/codex CLI or API)" -ForegroundColor White
    Write-Host "  [2] Anthropic Claude Code (claude CLI or API)" -ForegroundColor White
    Write-Host "  [3] OpenAI Direct API (Zero-dependency gpt-4o-mini)" -ForegroundColor White
    Write-Host "  [4] Anthropic Direct API (Zero-dependency claude-3-5-haiku)" -ForegroundColor White
    $choice = Read-Host "Select option [1-4, Default: 1]"
    
    $selectedProvider = switch ($choice) {
        "2" { "claude" }
        "3" { "openai" }
        "4" { "anthropic" }
        default { "codex" }
    }
} elseif (-not $selectedProvider) {
    $selectedProvider = $existingConfig["cli_provider"]
}

Write-Host "Selected Provider: $selectedProvider" -ForegroundColor Green
Write-Host ""

# -----------------------------------------------------------------------------
# 2. API Key Prompt & .env Generation
# -----------------------------------------------------------------------------
$existingOpenAiKey = [System.Environment]::GetEnvironmentVariable("OPENAI_API_KEY")
$existingAnthropicKey = [System.Environment]::GetEnvironmentVariable("ANTHROPIC_API_KEY")

if (Test-Path $envFilePath) {
    Get-Content $envFilePath | ForEach-Object {
        $l = $_.Trim()
        if ($l -and -not $l.StartsWith("#") -and $l.Contains("=")) {
            $kv = $l -split "=", 2
            if ($kv[0].Trim() -eq "OPENAI_API_KEY" -and -not $existingOpenAiKey) {
                $existingOpenAiKey = $kv[1].Trim().Trim('"').Trim("'")
            }
            if ($kv[0].Trim() -eq "ANTHROPIC_API_KEY" -and -not $existingAnthropicKey) {
                $existingAnthropicKey = $kv[1].Trim().Trim('"').Trim("'")
            }
        }
    }
}

$inputKey = $ApiKey
if (-not $inputKey -and -not $NonInteractive) {
    if ($selectedProvider -eq "claude" -or $selectedProvider -eq "anthropic") {
        $masked = if ($existingAnthropicKey) { "sk-ant-... (already set)" } else { "none" }
        Write-Host "Anthropic API Key (Current: $masked):" -ForegroundColor Yellow
        $keyPrompt = Read-Host "Enter Anthropic API Key (Press Enter to keep current)"
        $inputKey = if ($keyPrompt) { $keyPrompt.Trim() } else { $existingAnthropicKey }
        $existingAnthropicKey = $inputKey
    } else {
        $masked = if ($existingOpenAiKey) { "sk-... (already set)" } else { "none" }
        Write-Host "OpenAI API Key (Current: $masked):" -ForegroundColor Yellow
        $keyPrompt = Read-Host "Enter OpenAI API Key (Press Enter to keep current)"
        $inputKey = if ($keyPrompt) { $keyPrompt.Trim() } else { $existingOpenAiKey }
        $existingOpenAiKey = $inputKey
    }
} elseif ($inputKey) {
    if ($selectedProvider -eq "claude" -or $selectedProvider -eq "anthropic") {
        $existingAnthropicKey = $inputKey
    } else {
        $existingOpenAiKey = $inputKey
    }
}

# Write ~/.aicc/.env file safely
$envContent = @"
# ==============================================================================
# aicc Secrets Configuration (DO NOT COMMIT OR SHARE)
# ==============================================================================
OPENAI_API_KEY=$existingOpenAiKey
ANTHROPIC_API_KEY=$existingAnthropicKey
"@

Set-Content -Path $envFilePath -Value $envContent -Encoding UTF8 -Force
Write-Host "Saved API keys to: $envFilePath" -ForegroundColor Green
Write-Host ""

# -----------------------------------------------------------------------------
# 3. Custom Changelog / Logging Markdown Filename Configuration
# -----------------------------------------------------------------------------
$selectedLogFile = $LogFile
if (-not $selectedLogFile -and -not $NonInteractive) {
    $currentLog = if ($existingConfig["log_filename"]) { $existingConfig["log_filename"] } else { "CHANGELOG.md" }
    Write-Host "Logging & Changelog Filename Configuration:" -ForegroundColor Yellow
    Write-Host "Specify a preferred filename, or leave empty for auto-detection." -ForegroundColor Gray
    Write-Host "(Auto-detects: dev.md, logging.md, devlog.md, CHANGELOG.md, changes.md, etc.)" -ForegroundColor Gray
    $logPrompt = Read-Host "Enter log filename [Default: $currentLog]"
    $selectedLogFile = if ($logPrompt) { $logPrompt.Trim() } else { $currentLog }
} elseif (-not $selectedLogFile) {
    $selectedLogFile = if ($existingConfig["log_filename"]) { $existingConfig["log_filename"] } else { "CHANGELOG.md" }
}

Write-Host "Configured Log Filename: $(if ($selectedLogFile) { $selectedLogFile } else { 'Auto-Detect 20+ Naming Variants' })" -ForegroundColor Green
Write-Host ""


# -----------------------------------------------------------------------------
# 4. Save JSON Configuration
# -----------------------------------------------------------------------------
$finalConfig = [ordered]@{
    cli_provider             = $selectedProvider
    log_filename             = $selectedLogFile
    auto_create_private_repo = $existingConfig["auto_create_private_repo"]
    default_branch           = $existingConfig["default_branch"]
    max_commit_words         = $existingConfig["max_commit_words"]
    changelog_bullets_count  = $existingConfig["changelog_bullets_count"]
    open_web_on_push         = $existingConfig["open_web_on_push"]
    openai_model             = $existingConfig["openai_model"]
    anthropic_model          = $existingConfig["anthropic_model"]
}

$jsonOutput = $finalConfig | ConvertTo-Json -Depth 5
Set-Content -Path $configJsonPath -Value $jsonOutput -Encoding UTF8 -Force
Write-Host "Saved configuration to: $configJsonPath" -ForegroundColor Green
Write-Host ""

# -----------------------------------------------------------------------------
# 5. Register in User PATH and PowerShell Profiles
# -----------------------------------------------------------------------------
$installDir = $PSScriptRoot
if (-not $SkipPathUpdate) {
    # 5a. Add to User PATH
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath) {
        $pathList = $userPath -split ';' | Where-Object { $_ -ne '' }
        if ($pathList -notcontains $installDir) {
            $newUserPath = "$userPath;$installDir"
            [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
            Write-Host "Added $installDir to User PATH." -ForegroundColor Green
        } else {
            Write-Host "$installDir is already in User PATH." -ForegroundColor DarkGray
        }
    }

    # 5b. Register function in PowerShell Profiles
    $profiles = @(
        "$env:USERPROFILE\OneDrive\Documents\PowerShell\Microsoft.PowerShell_profile.ps1",
        "$env:USERPROFILE\Documents\PowerShell\Microsoft.PowerShell_profile.ps1",
        "$env:USERPROFILE\OneDrive\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1",
        "$env:USERPROFILE\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1"
    )

    $functionBlock = @"

# aicc — AI Commit & Changelog Automation
function aicc {
    & "$installDir\aicc.ps1" @args
}
"@

    $updatedProfiles = 0
    foreach ($p in $profiles) {
        $pDir = Split-Path $p
        if (-not (Test-Path $pDir)) {
            New-Item -Path $pDir -ItemType Directory -Force | Out-Null
        }

        $content = if (Test-Path $p) { Get-Content $p -Raw -ErrorAction SilentlyContinue } else { "" }
        if ($content -notlike "*function aicc*") {
            Add-Content -Path $p -Value $functionBlock -Force
            $updatedProfiles++
        } else {
            # Update existing function definition
            $regex = '(?ms)# aicc — AI Commit & Changelog Automation\s+function aicc\s*\{.*?\}'
            if ($content -match $regex) {
                $newContent = $content -replace $regex, $functionBlock.Trim()
                Set-Content -Path $p -Value $newContent -Force
                $updatedProfiles++
            }
        }
    }

    Write-Host "Registered 'aicc' function across $updatedProfiles PowerShell profile(s)." -ForegroundColor Green
}

Write-Host ""
Write-Host "========================================================" -ForegroundColor Green
Write-Host "              Installation & Setup Complete!            " -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "You can now run 'aicc' from any repository in CMD or PowerShell!" -ForegroundColor White
Write-Host "  - Automatically stages files (git add .)" -ForegroundColor Gray
Write-Host "  - Generates 10-word AI commit messages via $selectedProvider" -ForegroundColor Gray
Write-Host "  - Appends to $selectedLogFile" -ForegroundColor Gray
Write-Host "  - Automatically initializes private GitHub repo if not in one" -ForegroundColor Gray
Write-Host "  - Pushes changes to remote" -ForegroundColor Gray
Write-Host ""
