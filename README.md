# ClawGod

[English](README.md) | [中文](README_ZH.md) | [日本語](README_JP.md)

> God mode for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

Unlock internal features, remove restrictions, one command, no compilation.

## Install

**macOS / Linux:**
```bash
curl -fsSL clawgod.0chen.cc/install.sh | bash
```

**Windows (PowerShell):**
```powershell
irm clawgod.0chen.cc/install.ps1 | iex
```

Green logo = patched. Orange logo = original.

## What it does

### Feature Unlocks

| Patch | What you get |
|-------|-------------|
| **Internal User Mode** | 24+ hidden commands (`/share`, `/teleport`, `/issue`, `/bughunter`...), debug logging, API request dumps |
| **GrowthBook Overrides** | Override any feature flag via config file |
| **Agent Teams** | Multi-agent swarm collaboration, no flags needed |
| **Computer Use** | Screen control without Max/Pro subscription (macOS) |
| **Ultraplan** | Multi-agent planning via Claude Code Remote |
| **Ultrareview** | Automated bug hunting via Claude Code Remote |

### Restriction Removals

| Patch | What's removed |
|-------|---------------|
| **CYBER_RISK_INSTRUCTION** | Security testing refusal (pentesting, C2, exploits) |
| **URL Restriction** | "NEVER generate or guess URLs" instruction |
| **Cautious Actions** | Forced confirmation before destructive operations |
| **Login Notice** | "Not logged in" startup reminder |

### Visual

| Patch | Effect |
|-------|--------|
| **Green Theme** | Brand color → green. Patched at a glance |
| **Message Filters** | Shows content hidden from non-Anthropic users |

## Commands

```bash
claude              # Patched Claude Code
claude.orig         # Original unpatched version
```

## Update

Re-run the installer to get the latest version with patches re-applied:

```bash
curl -fsSL clawgod.0chen.cc/install.sh | bash
```

## Uninstall

Restores original `claude` command:

```bash
bash <(curl -fsSL clawgod.0chen.cc/install.sh) --uninstall
```

## Requirements

- Node.js >= 18 + npm
- Claude Code account (`claude auth login`)

## License

GPL-3.0 — Not affiliated with Anthropic. Use at your own risk.
