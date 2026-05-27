#!/usr/bin/env bash
# ──────────────────────────── ZPI Installer ─────────────────────────────────
#
# One-command installer for zpi-cli on macOS and Linux.
#
# Usage:
#   curl -fsSL https://get.zeroproofai.com/zpi | bash
#   curl -fsSL https://get.zeroproofai.com/zpi | bash -s -- --no-ollama
#   curl -fsSL https://get.zeroproofai.com/zpi | bash -s -- --llm openai
#   curl -fsSL https://get.zeroproofai.com/zpi | bash -s -- --version v0.2.0
#
# What it does:
#   1. Detects platform (macOS / Linux, x86_64 / aarch64)
#   2. Downloads the correct zpi-cli binary for your OS and architecture
#   3. Verifies SHA-256 checksum
#   4. Installs to ~/.local/bin
#   5. Creates default config at ~/.chp/config.toml
#   6. Installs Ollama + pulls Llama model (unless --no-ollama or --llm <cloud>)
#   7. Installs Node.js + mcp-remote (for zpi-zkpay MCP) when registering Claude
#   8. Optional --agent-b: downloads the stdio bridge to
#      ~/.zpi/mcp/agent-b/mcp-stdio-bridge.mjs (remote MCP at
#      https://merchant.zeroproofai.com/mcp by default; override with
#      --agent-b-url)
#   9. Registers zpi + zpi-zkpay MCP servers in detected AI clients
#
set -euo pipefail

# When invoked via `curl ... | bash`, stdin is the script itself. Subprocesses
# (brew, ollama pull, npm install, ...) inherit FD 0 and can consume script
# bytes before bash reads them, truncating the install at step 6.
#
# Wrapping the entire body in `{ ... }` forces bash to parse the compound
# command in full — i.e. drain the pipe — before executing anything inside.
# `</dev/null` on the block redirects every subprocess's stdin so they cannot
# consume script bytes even in degenerate cases. Pattern matches the Homebrew,
# Docker (get.docker.com), and rustup installers.
{

# ── Configuration ───────────────────────────────────────────────────
REPO="Zero-Proof-AI/zpi-releases"
INSTALL_DIR="${HOME}/.local/bin"
CONFIG_DIR="${HOME}/.chp"
ZPI_DIR="${HOME}/.zpi"
MCP_REMOTE_VERSION="0.1.38"
AGENT_B_DEFAULT_MCP_URL="https://merchant.zeroproofai.com/mcp"
BRIDGE_ASSET_URL="https://raw.githubusercontent.com/Zero-Proof-AI/zeroproof-travel-poc/main/agent-b/mcp-server/mcp-stdio-bridge.mjs"

# ── Colors ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()  { echo -e "${BLUE}▸${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
err()   { echo -e "${RED}✗${NC} $*" >&2; }
step()  { echo -e "\n${BOLD}── $* ──${NC}"; }

# ── Parse arguments ─────────────────────────────────────────────
VERSION="latest"
LLM_BACKEND="ollama"
SKIP_OLLAMA=false
SKIP_CLAUDE=false
SKIP_OPENWORK=false
SKIP_CURSOR=false
SKIP_WINDSURF=false
SKIP_VSCODE=false
FORCE_CURSOR=false
FORCE_WINDSURF=false
FORCE_VSCODE=false
ZPI_ENV="prod"
AGENT_B=false
AGENT_B_URL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)     VERSION="$2"; shift 2 ;;
        --llm)         LLM_BACKEND="$2"; shift 2 ;;
        --no-ollama)   SKIP_OLLAMA=true; shift ;;
        --no-claude)   SKIP_CLAUDE=true; shift ;;
        --no-openwork) SKIP_OPENWORK=true; shift ;;
        --cursor)      FORCE_CURSOR=true; shift ;;
        --no-cursor)   SKIP_CURSOR=true; shift ;;
        --windsurf)    FORCE_WINDSURF=true; shift ;;
        --no-windsurf) SKIP_WINDSURF=true; shift ;;
        --vscode)      FORCE_VSCODE=true; shift ;;
        --no-vscode)   SKIP_VSCODE=true; shift ;;
        --dev)         ZPI_ENV="dev"; shift ;;
        --local)       ZPI_ENV="local"; shift ;;
        --agent-b)     AGENT_B=true; shift ;;
        --agent-b-url) AGENT_B_URL="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: curl -fsSL https://get.zeroproofai.com/zpi | bash [-s -- OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --version <tag>   Install a specific version (default: latest)"
            echo "  --llm <backend>   LLM backend: ollama (default), openai, anthropic"
            echo "  --no-ollama       Skip Ollama installation"
            echo "  --no-claude       Skip Claude Desktop registration"
            echo "  --no-openwork     Skip Openwork registration"
            echo "  --cursor          Force-register with Cursor (even without ~/.cursor)"
            echo "  --no-cursor       Skip Cursor registration"
            echo "  --windsurf        Force-register with Windsurf (even without ~/.codeium/windsurf)"
            echo "  --no-windsurf     Skip Windsurf registration"
            echo "  --vscode          Force-register with VS Code (even without ./.vscode)"
            echo "  --no-vscode       Skip VS Code registration"
            echo "  --dev             Use dev zpi-zkpay endpoint"
            echo "  --local           Use local zpi-zkpay endpoint"
            echo "  --agent-b         Demo: install stdio bridge + register agent-b-farm in Claude"
            echo "  --agent-b-url URL Override MCP URL (default: ${AGENT_B_DEFAULT_MCP_URL})"
            exit 0
            ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
done

# If user chose a cloud LLM, skip Ollama
if [[ "$LLM_BACKEND" != "ollama" ]]; then
    SKIP_OLLAMA=true
fi

# ── Detect platform ─────────────────────────────────────────────────
detect_platform() {
    local os arch target

    os="$(uname -s)"
    arch="$(uname -m)"

    case "$os" in
        Darwin) os="apple-darwin" ;;
        Linux)  os="unknown-linux-gnu" ;;
        *)      err "Unsupported OS: $os"; exit 1 ;;
    esac

    case "$arch" in
        x86_64|amd64)  arch="x86_64" ;;
        arm64|aarch64) arch="aarch64" ;;
        *)             err "Unsupported architecture: $arch"; exit 1 ;;
    esac

    # No aarch64-linux build yet
    if [[ "$arch" == "aarch64" && "$os" == "unknown-linux-gnu" ]]; then
        err "aarch64-linux is not yet supported. Use x86_64 or build from source."
        exit 1
    fi

    target="${arch}-${os}"
    echo "$target"
}

# ── Download helpers ────────────────────────────────────────────────
download() {
    local url="$1" dest="$2"
    if command -v curl &>/dev/null; then
        curl -fsSL -o "$dest" "$url"
    elif command -v wget &>/dev/null; then
        wget -q -O "$dest" "$url"
    else
        err "Neither curl nor wget found. Install one and retry."
        exit 1
    fi
}

# ── Resolve download URL ───────────────────────────────────────────
resolve_url() {
    local target="$1"
    local base

    if [[ "$VERSION" == "latest" ]]; then
        base="https://github.com/${REPO}/releases/latest/download"
    else
        base="https://github.com/${REPO}/releases/download/${VERSION}"
    fi

    echo "${base}/zpi-cli-${target}.tar.gz"
}

# ── Node.js + mcp-remote (zpi-zkpay MCP transport) ─────────────────
get_node_major() {
    if ! command -v node &>/dev/null; then
        echo ""
        return
    fi
    node -e 'const v=process.versions.node.split(".")[0]; process.stdout.write(v)' 2>/dev/null || true
}

initialize_node_for_mcp() {
    local major
    major="$(get_node_major)"
    if [[ -n "$major" && "$major" -ge 20 ]]; then
        ok "Node.js v${major} already installed"
        return 0
    fi

    info "Installing Node.js (required for zpi-zkpay MCP)..."
    if [[ "$(uname -s)" == "Darwin" ]]; then
        if command -v brew &>/dev/null; then
            brew install node </dev/null
        else
            warn "Homebrew not found. Install Node.js 20+ manually: https://nodejs.org/"
            return 1
        fi
    else
        warn "Install Node.js 20+ manually: https://nodejs.org/"
        return 1
    fi

    major="$(get_node_major)"
    if [[ -n "$major" && "$major" -ge 20 ]]; then
        ok "Node.js ready (v${major})"
        return 0
    fi
    warn "Node.js 20+ still not on PATH after install"
    return 1
}

test_global_mcp_remote_cli() {
    command -v mcp-remote &>/dev/null
}

initialize_global_mcp_remote() {
    if test_global_mcp_remote_cli; then
        ok "mcp-remote@${MCP_REMOTE_VERSION} already installed globally"
        return 0
    fi
    if ! command -v npm &>/dev/null; then
        warn "npm not found; zpi-zkpay will fall back to npx -y in Claude config"
        return 1
    fi
    info "Installing mcp-remote@${MCP_REMOTE_VERSION} globally..."
    if npm install -g "mcp-remote@${MCP_REMOTE_VERSION}" </dev/null; then
        if test_global_mcp_remote_cli; then
            ok "mcp-remote@${MCP_REMOTE_VERSION} installed"
            return 0
        fi
    fi
    warn "Global mcp-remote install failed; zpi-zkpay will fall back to npx -y in Claude config"
    return 1
}

install_agent_b_bridge() {
    local mcp_url="$1"
    local bridge_dir="${ZPI_DIR}/mcp/agent-b"
    local agent_b_root="${ZPI_DIR}/agent-b"
    local bridge_path="${bridge_dir}/mcp-stdio-bridge.mjs"

    mkdir -p "$bridge_dir" "$agent_b_root"

    info "Downloading bridge from ${BRIDGE_ASSET_URL}"
    if ! curl -fsSL "$BRIDGE_ASSET_URL" -o "$bridge_path"; then
        warn "Could not download agent-b bridge"
        return 1
    fi
    ok "Installed bridge: ${bridge_path}"
    printf '%s\n' "{\"agent_b\":true,\"mcp_url\":\"${mcp_url}\",\"installed_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
        > "${agent_b_root}/installed.json"
}

# ════════════════════════════════════════════════════════════════════
echo -e "${BOLD}━━━ ZPI Installer ━━━${NC}"
echo ""

# ── Step 1: Detect platform ────────────────────────────────────────
step "Detecting platform"
TARGET="$(detect_platform)"
ok "Platform: ${TARGET}"

# ── Step 2: Download binary ────────────────────────────────────────
step "Downloading zpi-cli"
ARCHIVE_URL="$(resolve_url "$TARGET")"
CHECKSUM_URL="${ARCHIVE_URL}.sha256"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

info "Downloading ${ARCHIVE_URL}"
download "$ARCHIVE_URL" "$TMPDIR/zpi-cli.tar.gz"
download "$CHECKSUM_URL" "$TMPDIR/zpi-cli.tar.gz.sha256"

# ── Step 3: Verify checksum ────────────────────────────────────────
step "Verifying checksum"
EXPECTED="$(awk '{print $1}' "$TMPDIR/zpi-cli.tar.gz.sha256")"

if command -v sha256sum &>/dev/null; then
    ACTUAL="$(sha256sum "$TMPDIR/zpi-cli.tar.gz" | awk '{print $1}')"
elif command -v shasum &>/dev/null; then
    ACTUAL="$(shasum -a 256 "$TMPDIR/zpi-cli.tar.gz" | awk '{print $1}')"
else
    warn "No sha256sum or shasum found — skipping checksum verification"
    ACTUAL="$EXPECTED"
fi

if [[ "$EXPECTED" != "$ACTUAL" ]]; then
    err "Checksum mismatch!"
    err "  Expected: $EXPECTED"
    err "  Actual:   $ACTUAL"
    exit 1
fi
ok "Checksum verified: ${DIM}${ACTUAL:0:16}...${NC}"

# ── Step 4: Install binary ─────────────────────────────────────────
step "Installing zpi-cli"
mkdir -p "$INSTALL_DIR"
tar xzf "$TMPDIR/zpi-cli.tar.gz" -C "$TMPDIR"
mv "$TMPDIR/zpi-cli" "$INSTALL_DIR/zpi-cli"
chmod +x "$INSTALL_DIR/zpi-cli"

# macOS: strip Gatekeeper quarantine flag so the binary is not killed on first run
if [[ "$(uname -s)" == "Darwin" ]]; then
    xattr -dr com.apple.quarantine "$INSTALL_DIR/zpi-cli" 2>/dev/null || true
fi

ok "Installed: ${INSTALL_DIR}/zpi-cli"

# Check PATH
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
    warn "${INSTALL_DIR} is not in your PATH"
    echo ""
    echo "  Add this to your shell profile (~/.zshrc, ~/.bashrc, etc.):"
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo ""
    # Temporarily add for the rest of this script
    export PATH="$INSTALL_DIR:$PATH"
fi

# Verify it runs
VER="$(zpi-cli --version 2>/dev/null || echo "unknown")"
ok "Version: ${VER}"

# ── Step 5: Create config ──────────────────────────────────────────
step "Setting up configuration"
mkdir -p "$CONFIG_DIR"

# Resolve attester URL from ZPI_ENV (mirrors zpi-cli install logic)
case "$ZPI_ENV" in
    local) ATTESTER_URL="http://localhost:8000" ;;
    dev)   ATTESTER_URL="https://dev.attester.zeroproofai.com" ;;
    *)     ATTESTER_URL="https://attester.zeroproofai.com" ;;
esac

# ── Baked-in program_id (SHA-256 content address of the zpi-program ELF) ──
# Update this value each time a new ELF version is deployed via:
#   zpi-cli zkp register --elf path/to/zpi-program
PROGRAM_ID="sha256:282ea5e1e74d27a2ca7decd63809853c92cbdf4c249e3e9f9ba474ae3d635f99"

if [[ ! -f "$CONFIG_DIR/config.toml" ]]; then
    # Generate config based on chosen LLM backend
    case "$LLM_BACKEND" in
        ollama)
            cat > "$CONFIG_DIR/config.toml" <<TOML
[llm]
backend = "ollama"
model = "llama3.1:8b"

[intent]
confidence_threshold = 0.7
max_messages_default = 50
prompt_version = "v1"

[zkp]
attestation_url = "${ATTESTER_URL}"
program_id = "${PROGRAM_ID}"
# elf_path = "<absolute path to zpi-program ELF binary>"
TOML
            ;;
        openai)
            cat > "$CONFIG_DIR/config.toml" <<TOML
[llm]
backend = "openai"
api_key_env = "OPENAI_API_KEY"
model = "gpt-4o-mini"

[intent]
confidence_threshold = 0.7
max_messages_default = 50
prompt_version = "v1"

[zkp]
attestation_url = "${ATTESTER_URL}"
program_id = "${PROGRAM_ID}"
# elf_path = "<absolute path to zpi-program ELF binary>"
TOML
            ;;
        anthropic)
            cat > "$CONFIG_DIR/config.toml" <<TOML
[llm]
backend = "anthropic"
api_key_env = "ANTHROPIC_API_KEY"
model = "claude-sonnet-4-20250514"

[intent]
confidence_threshold = 0.7
max_messages_default = 50
prompt_version = "v1"

[zkp]
attestation_url = "${ATTESTER_URL}"
program_id = "${PROGRAM_ID}"
# elf_path = "<absolute path to zpi-program ELF binary>"
TOML
            ;;
        *)
            err "Unknown LLM backend: $LLM_BACKEND (use ollama, openai, or anthropic)"
            exit 1
            ;;
    esac
    ok "Created config: ${CONFIG_DIR}/config.toml (backend: ${LLM_BACKEND}, attester: ${ATTESTER_URL})"
else
    ok "Config exists: ${CONFIG_DIR}/config.toml (not overwritten)"
fi

# ── Step 6: Ollama + Llama model ───────────────────────────────────
if [[ "$SKIP_OLLAMA" == "false" ]]; then
    step "Setting up Ollama + Llama model"

    if command -v ollama &>/dev/null; then
        ok "Ollama already installed: $(ollama --version 2>/dev/null || echo 'unknown version')"
    else
        info "Installing Ollama..."
        OS_NAME="$(uname -s)"
        case "$OS_NAME" in
            Darwin)
                if command -v brew &>/dev/null; then
                    brew install ollama </dev/null
                else
                    warn "Homebrew not found. Install Ollama manually: https://ollama.com/download"
                    warn "Continuing without Ollama..."
                    SKIP_OLLAMA=true
                fi
                ;;
            Linux)
                curl -fsSL https://ollama.com/install.sh | sh
                ;;
        esac

        if [[ "$SKIP_OLLAMA" == "false" ]] && command -v ollama &>/dev/null; then
            ok "Ollama installed"
        fi
    fi

    if [[ "$SKIP_OLLAMA" == "false" ]] && command -v ollama &>/dev/null; then
        # Ensure Ollama is running
        if ! curl -sf http://localhost:11434/api/tags &>/dev/null; then
            info "Starting Ollama server..."
            ollama serve &>/dev/null &
            OLLAMA_PID=$!
            # Wait for it to be ready
            for _ in {1..15}; do
                if curl -sf http://localhost:11434/api/tags &>/dev/null; then
                    break
                fi
                sleep 1
            done
            if curl -sf http://localhost:11434/api/tags &>/dev/null; then
                ok "Ollama server started (PID: ${OLLAMA_PID})"
            else
                warn "Ollama server did not start in time. Start it manually: ollama serve"
            fi
        else
            ok "Ollama server already running"
        fi

        # Pull the Llama model
        MODEL="llama3.1:8b"
        if ollama list 2>/dev/null | grep -q "$MODEL"; then
            ok "Model ${MODEL} already downloaded"
        else
            info "Pulling ${MODEL} (this may take a few minutes)..."
            ollama pull "$MODEL" </dev/null
            ok "Model ${MODEL} ready"
        fi
    fi
else
    if [[ "$LLM_BACKEND" != "ollama" ]]; then
        step "LLM backend: ${LLM_BACKEND}"
        ok "Skipping Ollama (using ${LLM_BACKEND} backend)"
        if [[ "$LLM_BACKEND" == "openai" ]]; then
            warn "Set OPENAI_API_KEY in your environment before using zpi-cli"
        elif [[ "$LLM_BACKEND" == "anthropic" ]]; then
            warn "Set ANTHROPIC_API_KEY in your environment before using zpi-cli"
        fi
    else
        step "Skipping Ollama"
        warn "Install Ollama later: https://ollama.com/download"
        warn "Then run: ollama pull llama3.1:8b"
    fi
fi

# ── Step 7: Node.js + mcp-remote (for zpi-zkpay) ─────────────────────
if [[ "$SKIP_CLAUDE" == "false" ]]; then
    step "Setting up Node.js for zpi-zkpay"
    initialize_node_for_mcp || true
    initialize_global_mcp_remote || true
fi

# ── Step 8: Optional agent-b demo bridge ───────────────────────────
RESOLVED_AGENT_B_URL="${AGENT_B_URL:-$AGENT_B_DEFAULT_MCP_URL}"
if [[ "$AGENT_B" == "true" ]]; then
    if [[ "$SKIP_CLAUDE" == "true" ]]; then
        warn "--agent-b requires Claude registration; skipping agent-b (use without --no-claude)"
        AGENT_B=false
    else
        step "Installing agent-b demo bridge"
        install_agent_b_bridge "$RESOLVED_AGENT_B_URL" || true
    fi
fi

# ── Step 9: Register MCP servers ───────────────────────────────────
# Use an array so empty $ZPI_ENV expands to zero args (not an empty "" arg).
ENV_ARGS=()
case "$ZPI_ENV" in
    dev)   ENV_ARGS=(--dev)   ;;
    local) ENV_ARGS=(--local) ;;
esac

if [[ "$SKIP_CLAUDE" == "false" ]]; then
    step "Registering with Claude Desktop"
    CLAUDE_CMD=(install --claude "${ENV_ARGS[@]}")
    if [[ "$AGENT_B" == "true" ]]; then
        CLAUDE_CMD+=(--agent-b --agent-b-url "$RESOLVED_AGENT_B_URL")
    fi
    if zpi-cli "${CLAUDE_CMD[@]}" 2>/dev/null; then
        ok "Registered zpi + zpi-zkpay in Claude Desktop"
    else
        warn "Could not register with Claude Desktop (is it installed?)"
        echo "  Run manually later: zpi-cli install --claude"
    fi
fi

if [[ "$SKIP_CURSOR" == "false" ]] && { [[ "$FORCE_CURSOR" == "true" ]] || [[ -d "$HOME/.cursor" ]]; }; then
    step "Registering with Cursor"
    if zpi-cli install --cursor "${ENV_ARGS[@]}" 2>/dev/null; then
        ok "Registered zpi + zpi-zkpay in Cursor"
    else
        warn "Could not register with Cursor"
        echo "  Run manually later: zpi-cli install --cursor"
    fi
fi

if [[ "$SKIP_WINDSURF" == "false" ]] && { [[ "$FORCE_WINDSURF" == "true" ]] || [[ -d "$HOME/.codeium/windsurf" ]]; }; then
    step "Registering with Windsurf"
    if zpi-cli install --windsurf "${ENV_ARGS[@]}" 2>/dev/null; then
        ok "Registered zpi + zpi-zkpay in Windsurf"
    else
        warn "Could not register with Windsurf"
        echo "  Run manually later: zpi-cli install --windsurf"
    fi
fi

if [[ "$SKIP_VSCODE" == "false" ]] && { [[ "$FORCE_VSCODE" == "true" ]] || [[ -d ".vscode" ]]; }; then
    step "Registering with VS Code"
    if zpi-cli install --vscode "${ENV_ARGS[@]}" 2>/dev/null; then
        ok "Registered zpi + zpi-zkpay in VS Code"
    else
        warn "Could not register with VS Code"
        echo "  Run manually later: zpi-cli install --vscode"
    fi
fi

if [[ "$SKIP_OPENWORK" == "false" ]]; then
    # Only attempt if openwork config exists somewhere
    OPENWORK_CANDIDATES=(
        "./opencode.jsonc"
        "./opencode.json"
        "../openwork/opencode.jsonc"
    )
    for candidate in "${OPENWORK_CANDIDATES[@]}"; do
        if [[ -f "$candidate" ]]; then
            step "Registering with Openwork"
            OPENWORK_DIR="$(cd "$(dirname "$candidate")" && pwd)"
            if zpi-cli install --openwork --openwork-path "$OPENWORK_DIR" "${ENV_ARGS[@]}" 2>/dev/null; then
                ok "Registered zpi + zpi-zkpay in Openwork"
            else
                warn "Could not register with Openwork"
            fi
            break
        fi
    done
fi

# ── Summary ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━ Installation Complete ━━━${NC}"
echo ""
echo "  Binary:   ${INSTALL_DIR}/zpi-cli"
echo "  Config:   ${CONFIG_DIR}/config.toml"
echo "  Database: ${CONFIG_DIR}/chp.db (created on first use)"
echo "  LLM:      ${LLM_BACKEND}"
echo ""
echo "Quick start:"
echo "  zpi-cli --help               Show all commands"
echo "  zpi-cli serve                Start MCP server"
echo "  zpi-cli doctor               Check system health"
echo ""
if [[ "$LLM_BACKEND" == "ollama" && "$SKIP_OLLAMA" == "false" ]]; then
    echo "Ollama is running with ${MODEL}."
    echo ""
fi
echo -e "${YELLOW}⚠${NC} Restart Claude Desktop to pick up the new MCP servers."
echo ""

} </dev/null
