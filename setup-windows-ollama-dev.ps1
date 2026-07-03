param(
    [string]$Model = "qwen3.5",
    [switch]$InstallCodex,
    [switch]$InstallClaude,
    [switch]$PullModel,
    [switch]$LaunchVSCode
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host "  - $Message" -ForegroundColor Gray
}

function Write-Ok {
    param([string]$Message)
    Write-Host "  OK  $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  WARN $Message" -ForegroundColor Yellow
}

function Test-Command {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Require-Command {
    param(
        [string]$Name,
        [string]$InstallHint
    )

    if (Test-Command $Name) {
        Write-Ok "$Name detected"
        return $true
    }

    Write-Warn "$Name not found"
    if ($InstallHint) {
        Write-Info $InstallHint
    }
    return $false
}

function Run-Checked {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList
    )

    Write-Info "$FilePath $($ArgumentList -join ' ')"
    & $FilePath @ArgumentList
}

Write-Step "Checking basic Windows developer tools"

$hasGit = Require-Command -Name "git" -InstallHint "Install Git for Windows first. Claude Code on native Windows requires Git for Windows."
$hasNode = Require-Command -Name "node" -InstallHint "Install Node.js LTS from the official installer before installing Codex CLI."
$hasNpm = Require-Command -Name "npm" -InstallHint "npm is normally installed with Node.js."
$hasCode = Require-Command -Name "code" -InstallHint "Install Visual Studio Code and make sure the 'code' command is available in PATH."

Write-Step "Checking Ollama"

if (Require-Command -Name "ollama" -InstallHint "Install Ollama for Windows from the official installer, then reopen PowerShell.") {
    Run-Checked -FilePath "ollama" -ArgumentList @("--version")
} else {
    Write-Warn "Stopping here because Ollama is required for the local GPU workflow."
    exit 1
}

Write-Step "Checking VS Code AI prerequisites"

if ($hasCode) {
    Write-Info "VS Code CLI detected. If Copilot Chat is not installed yet, install it from Extensions inside VS Code."
} else {
    Write-Warn "VS Code CLI not detected, so extension automation will be skipped."
}

Write-Step "Checking local Ollama API"

try {
    $response = Invoke-WebRequest -Uri "http://localhost:11434" -UseBasicParsing -TimeoutSec 3
    Write-Ok "Ollama API responded on http://localhost:11434"
    Write-Info ($response.Content.Trim())
} catch {
    Write-Warn "Ollama API did not respond on http://localhost:11434"
    Write-Info "Start Ollama from Start Menu or run: ollama serve"
}

if ($PullModel) {
    Write-Step "Pulling model $Model"
    Run-Checked -FilePath "ollama" -ArgumentList @("pull", $Model)
}

Write-Step "Listing downloaded models"
Run-Checked -FilePath "ollama" -ArgumentList @("list")

Write-Step "Checking whether a model is using GPU"
Write-Info "If a model is loaded, 'ollama ps' should show CPU/GPU usage in the Processor column."
try {
    Run-Checked -FilePath "ollama" -ArgumentList @("ps")
} catch {
    Write-Warn "Could not read running model state yet. This is normal if no model is loaded."
}

if ($InstallCodex) {
    Write-Step "Installing OpenAI Codex CLI"
    if (-not ($hasNode -and $hasNpm)) {
        Write-Warn "Skipping Codex install because Node.js/npm is missing."
    } else {
        Run-Checked -FilePath "npm" -ArgumentList @("install", "-g", "@openai/codex")
        Write-Ok "Codex CLI installed"
    }
}

if ($InstallClaude) {
    Write-Step "Installing Claude Code"
    if (-not $hasGit) {
        Write-Warn "Skipping Claude Code install because Git for Windows is missing."
    } else {
        Write-Info "Running Anthropic's official PowerShell installer."
        Invoke-Expression (Invoke-RestMethod "https://claude.ai/install.ps1")
        Write-Ok "Claude Code installer finished"
    }
}

if ($LaunchVSCode) {
    Write-Step "Launching VS Code with Ollama integration"
    Run-Checked -FilePath "ollama" -ArgumentList @("launch", "vscode")
}

Write-Step "Recommended next commands"
Write-Host "  1. VS Code local chat" -ForegroundColor White
Write-Host "     ollama launch vscode" -ForegroundColor Green
Write-Host "  2. Codex with local Ollama model" -ForegroundColor White
Write-Host "     codex --oss" -ForegroundColor Green
Write-Host "  3. Codex with a specific local model" -ForegroundColor White
Write-Host "     codex --oss -m gpt-oss:20b" -ForegroundColor Green
Write-Host "  4. Claude Code with Ollama" -ForegroundColor White
Write-Host '     $env:ANTHROPIC_AUTH_TOKEN="ollama"' -ForegroundColor Green
Write-Host '     $env:ANTHROPIC_API_KEY=""' -ForegroundColor Green
Write-Host '     $env:ANTHROPIC_BASE_URL="http://localhost:11434"' -ForegroundColor Green
Write-Host "     claude --model $Model" -ForegroundColor Green

Write-Step "Optional context-size guidance"
Write-Info "Agent-style coding tools work better with large context windows."
Write-Info "If needed, restart Ollama after setting a larger context window."
Write-Host '  $env:OLLAMA_CONTEXT_LENGTH="65536"' -ForegroundColor Green
Write-Host '  ollama serve' -ForegroundColor Green

Write-Step "Done"
Write-Ok "Use this script again with switches such as -PullModel -InstallCodex -InstallClaude -LaunchVSCode"
