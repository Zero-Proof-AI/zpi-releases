# zpi-releases

Public release artifacts for **zpi-cli** — the Zero Proof Intent CLI and MCP server.

---

## Install

### macOS / Linux

```bash
curl -fsSL https://get.zeroproofai.com/zpi | bash
```

### Windows (PowerShell)

```powershell
irm https://get.zeroproofai.com/zpi.ps1 | iex
```

---

## Options

### Choose an LLM backend

```bash
# Ollama (default — local, no API key needed)
curl -fsSL https://get.zeroproofai.com/zpi | bash

# OpenAI
curl -fsSL https://get.zeroproofai.com/zpi | bash -s -- --llm openai

# Anthropic
curl -fsSL https://get.zeroproofai.com/zpi | bash -s -- --llm anthropic
```

### Skip optional steps

```bash
# Skip Ollama install
curl -fsSL https://get.zeroproofai.com/zpi | bash -s -- --no-ollama

# Skip Claude Desktop registration
curl -fsSL https://get.zeroproofai.com/zpi | bash -s -- --no-claude
```

### Register with additional editors

```bash
# Cursor
curl -fsSL https://get.zeroproofai.com/zpi | bash -s -- --cursor

# Windsurf
curl -fsSL https://get.zeroproofai.com/zpi | bash -s -- --windsurf

# VS Code
curl -fsSL https://get.zeroproofai.com/zpi | bash -s -- --vscode
```

### Install a specific version

```bash
curl -fsSL https://get.zeroproofai.com/zpi | bash -s -- --version v0.1.14
```

---

## What the installer does

1. Detects your OS and architecture
2. Downloads the correct `zpi-cli` binary and verifies its SHA-256 checksum
3. Installs to `~/.local/bin` (macOS/Linux) or `~\\.zpi\\bin` (Windows)
4. Creates a default config at `~/.chp/config.toml`
5. Installs Ollama and pulls `llama3.1:8b` (unless `--no-ollama` or a cloud LLM is chosen)
6. Registers `zpi` and `zpi-zkpay` MCP servers in Claude Desktop

---

## Supported platforms

| Platform | Architecture | Archive |
|---|---|---|
| macOS | Apple Silicon (aarch64) | `.tar.gz` |
| macOS | Intel (x86_64) | `.tar.gz` |
| Linux | x86_64 | `.tar.gz` |
| Windows | x86_64 | `.zip` |

---

## Quick start after install

```bash
zpi-cli --help       # Show all commands
zpi-cli serve        # Start MCP server
zpi-cli doctor       # Check system health
```

