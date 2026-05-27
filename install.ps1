# ──────────────────────────── ZPI Installer (Windows) ───────────────────────
#
# One-command installer for zpi-cli on Windows.
#
# Usage (PowerShell):
#   irm https://get.zeroproofai.com/zpi.ps1 | iex
#
#   # With options:
#   irm https://get.zeroproofai.com/zpi.ps1 -OutFile $env:TEMP\zpi-install.ps1; & $env:TEMP\zpi-install.ps1 -Dev -AgentB
#
# What it does:
#   1. Downloads the correct zpi-cli binary for Windows x86_64
#   2. Verifies SHA-256 checksum
#   3. Installs to $HOME\.zpi\bin
#   4. Adds to user PATH
#   5. Creates default config at $HOME\.chp\config.toml (UTF-8, no BOM)
#   6. Installs Ollama + pulls Llama model (unless -NoOllama or -Llm <cloud>)
#   7. Installs Node.js (LTS) + mcp-remote globally (for zpi-zkpay) when
#      registering Claude
#   8. Optional -AgentB: downloads the stdio bridge to
#      $HOME\.zpi\mcp\agent-b\mcp-stdio-bridge.mjs and registers agent-b-farm
#      with Claude (remote MCP at https://merchant.zeroproofai.com/mcp by
#      default; override with -AgentBUrl)
#   9. Registers zpi + zpi-zkpay MCP servers in detected AI clients:
#        Claude Desktop, Cursor, Windsurf, VS Code, Openwork
#
param(
    [string]$Version = "latest",
    [string]$Llm = "ollama",
    [switch]$NoOllama,
    [switch]$NoClaude,
    [switch]$Cursor,
    [switch]$NoCursor,
    [switch]$Windsurf,
    [switch]$NoWindsurf,
    [switch]$Vscode,
    [switch]$NoVscode,
    [switch]$NoOpenwork,
    [switch]$Dev,
    [switch]$Local,
    [switch]$AgentB,
    [string]$AgentBUrl = "",
    [switch]$Help
)

$ErrorActionPreference = "Stop"

# ── Execution-policy bootstrap ──────────────────────────────────────
# Fresh Windows installs default to Restricted, which blocks .ps1 execution.
# If we're running from a file (not already bypassed), re-launch with Bypass.
# The env var prevents infinite re-launch loops.
if (-not $env:ZPI_INSTALL_BOOTSTRAPPED) {
    $policy = Get-ExecutionPolicy -Scope Process
    if ($policy -eq 'Restricted' -or $policy -eq 'AllSigned') {
        $scriptPath = $MyInvocation.MyCommand.Path
        if ($scriptPath) {
            $env:ZPI_INSTALL_BOOTSTRAPPED = "1"
            $argList = @("-ExecutionPolicy", "Bypass", "-NoProfile", "-File", $scriptPath)
            $argList += $MyInvocation.BoundParameters.GetEnumerator() | ForEach-Object {
                if ($_.Value -is [switch] -and $_.Value.IsPresent) { "-$($_.Key)" }
                elseif ($_.Value -isnot [switch]) { "-$($_.Key)"; "$($_.Value)" }
            }
            & powershell $argList
            exit $LASTEXITCODE
        }
    }
}

$Repo = "Zero-Proof-AI/zpi-releases"
$Target = "x86_64-pc-windows-msvc"
$InstallDir = Join-Path $HOME ".zpi\bin"
$ConfigDir = Join-Path $HOME ".chp"
$BinaryName = "zpi-cli.exe"
$McpRemoteVersion = "0.1.38"
$AgentBDefaultMcpUrl = "https://merchant.zeroproofai.com/mcp"
$BridgeAssetUrl = "https://raw.githubusercontent.com/Zero-Proof-AI/zeroproof-travel-poc/main/agent-b/mcp-server/mcp-stdio-bridge.mjs"

# ── Helpers ─────────────────────────────────────────────────────────
function Write-Info  { param($msg) Write-Host "  $msg" -ForegroundColor Cyan }
function Write-Ok    { param($msg) Write-Host "  ✓ $msg" -ForegroundColor Green }
function Write-Warn  { param($msg) Write-Host "  ⚠ $msg" -ForegroundColor Yellow }
function Write-Err   { param($msg) Write-Host "  ✗ $msg" -ForegroundColor Red }
function Write-Step  { param($msg) Write-Host "`n── $msg ──" -ForegroundColor White }

# Write text as UTF-8 *without BOM*. Windows PowerShell 5.x's `Out-File -Encoding utf8`
# emits a BOM that Rust's `toml` crate does not strip, breaking config.toml parsing.
function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

if ($Help) {
    Write-Host "ZPI Installer for Windows"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -Version [tag]   Install a specific version (default: latest)"
    Write-Host "  -Llm [backend]   LLM backend: ollama (default), openai, anthropic"
    Write-Host "  -NoOllama        Skip Ollama installation"
    Write-Host "  -NoClaude        Skip Claude Desktop registration"
    Write-Host "  -Cursor          Also register with Cursor (auto-detected by default)"
    Write-Host "  -NoCursor        Skip Cursor registration"
    Write-Host "  -Windsurf        Also register with Windsurf (auto-detected by default)"
    Write-Host "  -NoWindsurf      Skip Windsurf registration"
    Write-Host "  -Vscode          Also register with VS Code (.vscode/mcp.json in cwd)"
    Write-Host "  -NoVscode        Skip VS Code registration"
    Write-Host "  -NoOpenwork      Skip Openwork registration"
    Write-Host "  -Dev             Use dev zpi-zkpay endpoint"
    Write-Host "  -Local           Use local zpi-zkpay endpoint"
    Write-Host "  -AgentB          Demo: install stdio bridge + register agent-b-farm in Claude (remote MCP)"
    Write-Host "  -AgentBUrl       Override MCP URL (default $AgentBDefaultMcpUrl; e.g. http://host:3000/mcp for UTM)"
    exit 0
}

function Get-NodeMajorVersion {
    try {
        $v = & node --version 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        if ($v -match 'v?(\d+)') { return [int]$Matches[1] }
    } catch {
        $null = $_
    }
    return $null
}

function Initialize-NodeForMcp {
    $major = Get-NodeMajorVersion
    if ($null -ne $major -and $major -ge 20) {
        Write-Ok "Node.js v$major already installed"
        return $true
    }

    Write-Info "Installing Node.js LTS (required for zpi-zkpay MCP)..."
    $WingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($WingetCmd) {
        winget install --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements
        $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    } else {
        Write-Warn "winget not found. Install Node.js LTS manually: https://nodejs.org/"
        return $false
    }

    $major = Get-NodeMajorVersion
    if ($null -ne $major -and $major -ge 20) {
        Write-Ok "Node.js ready (v$major)"
        return $true
    }
    Write-Warn "Node.js 20+ still not on PATH after install"
    return $false
}

function Test-GlobalMcpRemoteCli {
    $npmDir = Join-Path $env:APPDATA "npm"
    $cmd = Join-Path $npmDir "mcp-remote.cmd"
    if (Test-Path $cmd) { return $true }
    foreach ($dir in @("C:\Program Files\nodejs", "C:\Program Files (x86)\nodejs")) {
        if (Test-Path (Join-Path $dir "mcp-remote.cmd")) { return $true }
    }
    return $false
}

function Initialize-GlobalMcpRemote {
    if (Test-GlobalMcpRemoteCli) {
        Write-Ok "mcp-remote@$McpRemoteVersion already installed globally"
        return $true
    }
    Write-Info "Installing mcp-remote@$McpRemoteVersion globally..."
    & npm install -g "mcp-remote@$McpRemoteVersion"
    if ($LASTEXITCODE -eq 0 -and (Test-GlobalMcpRemoteCli)) {
        Write-Ok "mcp-remote@$McpRemoteVersion installed"
        return $true
    }
    Write-Warn "Global mcp-remote install failed; zpi-zkpay will fall back to npx -y in Claude config"
    return $false
}

function Install-AgentBAsset {
    param([string]$McpUrl)

    $BridgeDir = Join-Path $HOME ".zpi\mcp\agent-b"
    $AgentBRoot = Join-Path $HOME ".zpi\agent-b"
    $BridgePath = Join-Path $BridgeDir "mcp-stdio-bridge.mjs"
    New-Item -ItemType Directory -Path $BridgeDir -Force | Out-Null
    New-Item -ItemType Directory -Path $AgentBRoot -Force | Out-Null

    Write-Info "Downloading bridge from $BridgeAssetUrl"
    try {
        Invoke-WebRequest -Uri $BridgeAssetUrl -OutFile $BridgePath -UseBasicParsing
    } catch {
        Write-Warn "Could not download agent-b bridge: $_"
        return $false
    }
    Write-Ok "Installed bridge: $BridgePath"

    $Marker = @{ agent_b = $true; mcp_url = $McpUrl; installed_at = (Get-Date).ToString("o") } | ConvertTo-Json
    Write-Utf8NoBom -Path (Join-Path $AgentBRoot "installed.json") -Content $Marker
    return $true
}

if ($Llm -ne "ollama") { $NoOllama = $true }

# Resolve attester URL (mirrors bash installer logic)
if     ($Local) { $AttesterUrl = "http://localhost:8000" }
elseif ($Dev)   { $AttesterUrl = "https://dev.attester.zeroproofai.com" }
else            { $AttesterUrl = "https://attester.zeroproofai.com" }

# Baked-in program_id (SHA-256 content address of the zpi-program ELF).
# Update this value each time a new ELF version is deployed via:
#   zpi-cli zkp register --elf path/to/zpi-program
$ProgramId = "sha256:282ea5e1e74d27a2ca7decd63809853c92cbdf4c249e3e9f9ba474ae3d635f99"

# Translate -Dev / -Local to a CLI flag for `zpi-cli install ...` calls below.
$EnvFlag = ""
if ($Dev)   { $EnvFlag = "--dev" }
if ($Local) { $EnvFlag = "--local" }

Write-Host "━━━ ZPI Installer ━━━`n" -ForegroundColor White

# ── Step 1: Download binary ────────────────────────────────────────
Write-Step "Downloading zpi-cli"

if ($Version -eq "latest") {
    $BaseUrl = "https://github.com/$Repo/releases/latest/download"
} else {
    $BaseUrl = "https://github.com/$Repo/releases/download/$Version"
}

$ArchiveUrl  = "$BaseUrl/zpi-cli-$Target.zip"
$ChecksumUrl = "$ArchiveUrl.sha256"

$TmpDir = Join-Path $env:TEMP "zpi-install-$(Get-Random)"
New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null

try {
    Write-Info "Downloading $ArchiveUrl"
    Invoke-WebRequest -Uri $ArchiveUrl  -OutFile "$TmpDir\zpi-cli.zip" -UseBasicParsing
    Invoke-WebRequest -Uri $ChecksumUrl -OutFile "$TmpDir\zpi-cli.zip.sha256" -UseBasicParsing

    # ── Step 2: Verify checksum ────────────────────────────────────
    Write-Step "Verifying checksum"
    $Expected = (Get-Content "$TmpDir\zpi-cli.zip.sha256" -Raw).Trim().Split(" ")[0]
    $Actual   = (Get-FileHash -Algorithm SHA256 "$TmpDir\zpi-cli.zip").Hash.ToLower()

    if ($Expected -ne $Actual) {
        Write-Err "Checksum mismatch! Expected: $Expected, Got: $Actual"
        exit 1
    }
    Write-Ok "Checksum verified: $($Actual.Substring(0, 16))..."

    # ── Step 3: Install binary ─────────────────────────────────────
    Write-Step "Installing zpi-cli"
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Expand-Archive -Path "$TmpDir\zpi-cli.zip" -DestinationPath $TmpDir -Force
    Copy-Item "$TmpDir\$BinaryName" "$InstallDir\$BinaryName" -Force
    Write-Ok "Installed: $InstallDir\$BinaryName"

    # Add to user PATH if not already there
    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($UserPath -notlike "*$InstallDir*") {
        [Environment]::SetEnvironmentVariable("Path", "$InstallDir;$UserPath", "User")
        $env:Path = "$InstallDir;$env:Path"
        Write-Ok "Added $InstallDir to user PATH"
    } else {
        Write-Ok "$InstallDir already in PATH"
    }

    # Verify
    try {
        $Ver = & "$InstallDir\$BinaryName" --version 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Version: $Ver"
        } else {
            Write-Warn "Could not run $BinaryName to verify version (exit code $LASTEXITCODE)."
            Write-Warn "If an Application Control policy is blocking it, add an exception for:"
            Write-Warn "  $InstallDir\$BinaryName"
            Write-Warn "The binary is installed correctly - the block is a local policy setting."
        }
    } catch {
        Write-Warn "Could not run ${BinaryName}: $($_.Exception.Message)"
    }

    # ── Step 4: Create config ──────────────────────────────────────
    Write-Step "Setting up configuration"
    New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null

    $ConfigPath = "$ConfigDir\config.toml"
    if (-not (Test-Path $ConfigPath)) {
        switch ($Llm) {
            "ollama" {
                $Toml = @"
[llm]
backend = "ollama"
model = "llama3.1:8b"

[intent]
confidence_threshold = 0.7
max_messages_default = 50
prompt_version = "v1"

[zkp]
attestation_url = "$AttesterUrl"
program_id = "$ProgramId"
# elf_path = "[absolute path to zpi-program ELF binary]"
"@
            }
            "openai" {
                $Toml = @"
[llm]
backend = "openai"
api_key_env = "OPENAI_API_KEY"
model = "gpt-4o-mini"

[intent]
confidence_threshold = 0.7
max_messages_default = 50
prompt_version = "v1"

[zkp]
attestation_url = "$AttesterUrl"
program_id = "$ProgramId"
# elf_path = "[absolute path to zpi-program ELF binary]"
"@
            }
            "anthropic" {
                $Toml = @"
[llm]
backend = "anthropic"
api_key_env = "ANTHROPIC_API_KEY"
model = "claude-sonnet-4-20250514"

[intent]
confidence_threshold = 0.7
max_messages_default = 50
prompt_version = "v1"

[zkp]
attestation_url = "$AttesterUrl"
program_id = "$ProgramId"
# elf_path = "[absolute path to zpi-program ELF binary]"
"@
            }
            default {
                Write-Err "Unknown LLM backend: $Llm (use ollama, openai, or anthropic)"
                exit 1
            }
        }
        Write-Utf8NoBom -Path $ConfigPath -Content $Toml
        Write-Ok "Created config: $ConfigPath (backend: $Llm, attester: $AttesterUrl)"
    } else {
        Write-Ok "Config exists: $ConfigPath (not overwritten)"
    }

    # ── Step 5: Ollama + Llama model ───────────────────────────────
    if (-not $NoOllama) {
        Write-Step "Setting up Ollama + Llama model"

        $OllamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
        if (-not $OllamaCmd) {
            Write-Info "Installing Ollama via winget..."
            $WingetCmd = Get-Command winget -ErrorAction SilentlyContinue
            if ($WingetCmd) {
                winget install --id Ollama.Ollama --accept-source-agreements --accept-package-agreements
                # Refresh PATH after install
                $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
            } else {
                Write-Warn "winget not found. Install Ollama manually: https://ollama.com/download"
                $NoOllama = $true
            }
        } else {
            Write-Ok "Ollama already installed"
        }

        if (-not $NoOllama) {
            $OllamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
            if ($OllamaCmd) {
                # Check if running
                try {
                    Invoke-WebRequest -Uri "http://localhost:11434/api/tags" -UseBasicParsing -TimeoutSec 2 | Out-Null
                    Write-Ok "Ollama server already running"
                } catch {
                    Write-Info "Starting Ollama server..."
                    Start-Process ollama -ArgumentList "serve" -WindowStyle Hidden
                    Start-Sleep -Seconds 3
                }

                # Pull model
                $Model = "llama3.1:8b"
                Write-Info "Pulling $Model (this may take a few minutes)..."
                & ollama pull $Model
                if ($LASTEXITCODE -eq 0) {
                    Write-Ok "Model $Model ready"
                } else {
                    Write-Warn "ollama pull exited with code $LASTEXITCODE"
                }
            }
        }
    } else {
        Write-Step "LLM backend: $Llm"
        if ($Llm -eq "openai") {
            Write-Warn "Set OPENAI_API_KEY environment variable before using zpi-cli"
        } elseif ($Llm -eq "anthropic") {
            Write-Warn "Set ANTHROPIC_API_KEY environment variable before using zpi-cli"
        }
    }

    # ── Step 5b: Node.js + mcp-remote (for zpi-zkpay) ───────────────
    if (-not $NoClaude) {
        Write-Step "Setting up Node.js for zpi-zkpay"
        Initialize-NodeForMcp | Out-Null
        Initialize-GlobalMcpRemote | Out-Null
    }

    # ── Step 5c: Optional agent-b demo assets ─────────────────────
    $ResolvedAgentBUrl = if ($AgentBUrl) { $AgentBUrl } else { $AgentBDefaultMcpUrl }
    if ($AgentB) {
        if ($NoClaude) {
            Write-Warn "-AgentB requires Claude registration; skipping agent-b (use without -NoClaude)"
            $AgentB = $false
        } else {
            Write-Step "Installing agent-b demo bridge"
            Install-AgentBAsset -McpUrl $ResolvedAgentBUrl | Out-Null
        }
    }

    # ── Step 6: Register MCP servers ───────────────────────────────
    # Native exe non-zero exit codes do NOT throw in PowerShell, so we check
    # $LASTEXITCODE explicitly after every `& $Binary install --<client>` call.
    $Binary = "$InstallDir\$BinaryName"

    function Invoke-ZpiInstall {
        param([string]$Flag, [string]$Label, [string[]]$Extra)
        $argsList = @("install", $Flag) + $Extra
        if ($EnvFlag) { $argsList += $EnvFlag }
        if ($AgentB -and $Flag -eq "--claude") {
            $argsList += "--agent-b"
            $argsList += @("--agent-b-url", $ResolvedAgentBUrl)
        }
        & $Binary @argsList
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Registered zpi + zpi-zkpay in $Label"
            return $true
        } else {
            Write-Warn "Could not register with $Label (zpi-cli $($argsList -join ' ') exited $LASTEXITCODE)"
            Write-Host "  Run manually later: zpi-cli install $Flag"
            return $false
        }
    }

    # Claude Desktop
    if (-not $NoClaude) {
        Write-Step "Registering with Claude Desktop"
        Invoke-ZpiInstall -Flag "--claude" -Label "Claude Desktop" -Extra @() | Out-Null
    }

    # Cursor (auto-detect: ~/.cursor, or force-register with -Cursor)
    $CursorDir = Join-Path $HOME ".cursor"
    if ((-not $NoCursor) -and ((Test-Path $CursorDir) -or $Cursor)) {
        Write-Step "Registering with Cursor"
        Invoke-ZpiInstall -Flag "--cursor" -Label "Cursor" -Extra @() | Out-Null
    }

    # Windsurf (auto-detect: ~/.codeium/windsurf, or force-register with -Windsurf)
    $WindsurfDir = Join-Path $HOME ".codeium\windsurf"
    if ((-not $NoWindsurf) -and ((Test-Path $WindsurfDir) -or $Windsurf)) {
        Write-Step "Registering with Windsurf"
        Invoke-ZpiInstall -Flag "--windsurf" -Label "Windsurf" -Extra @() | Out-Null
    }

    # VS Code (auto-detect: .vscode in current dir, or explicit -Vscode)
    if ((-not $NoVscode) -and ((Test-Path ".vscode") -or $Vscode)) {
        Write-Step "Registering with VS Code"
        Invoke-ZpiInstall -Flag "--vscode" -Label "VS Code" -Extra @() | Out-Null
    }

    # Openwork (probe a handful of common locations for opencode.jsonc)
    if (-not $NoOpenwork) {
        $OpenworkCandidates = @(
            ".\opencode.jsonc",
            ".\opencode.json",
            "..\openwork\opencode.jsonc"
        )
        foreach ($candidate in $OpenworkCandidates) {
            if (Test-Path $candidate) {
                Write-Step "Registering with Openwork"
                $OpenworkDir = (Resolve-Path (Split-Path $candidate -Parent)).Path
                Invoke-ZpiInstall -Flag "--openwork" -Label "Openwork" `
                    -Extra @("--openwork-path", $OpenworkDir) | Out-Null
                break
            }
        }
    }

    # ── Summary ────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "━━━ Installation Complete ━━━" -ForegroundColor White
    Write-Host ""
    Write-Host "  Binary:   $InstallDir\$BinaryName"
    Write-Host "  Config:   $ConfigDir\config.toml"
    Write-Host "  Database: $ConfigDir\chp.db (created on first use)"
    Write-Host "  LLM:      $Llm"
    Write-Host ""
    Write-Host "Quick start:"
    Write-Host "  zpi-cli --help               Show all commands"
    Write-Host "  zpi-cli serve                Start MCP server"
    Write-Host "  zpi-cli doctor               Check system health"
    Write-Host ""
    Write-Warn "Restart your AI client(s) to pick up the new MCP servers."
    Write-Host ""

} finally {
    Remove-Item -Recurse -Force $TmpDir -ErrorAction SilentlyContinue
}
