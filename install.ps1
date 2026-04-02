#Requires -Version 5.1
<#
.SYNOPSIS
    ClawGod Installer for Windows
.DESCRIPTION
    Downloads Claude Code from npm, applies feature unlock patches,
    and replaces the 'claude' command with the patched version.
.EXAMPLE
    irm clawgod.0chen.cc/install.ps1 | iex
    # or
    .\install.ps1
    .\install.ps1 -Version 2.1.89
    .\install.ps1 -Uninstall
#>
param(
    [string]$Version = "latest",
    [switch]$Uninstall,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$ClawDir = Join-Path $env:USERPROFILE ".clawgod"
$BinDir  = Join-Path $env:USERPROFILE ".local\bin"

# ─── Colors ───────────────────────────────────────────

function Write-OK($msg)   { Write-Host "  ✓ $msg" -ForegroundColor Green }
function Write-Err($msg)  { Write-Host "  ✗ $msg" -ForegroundColor Red }
function Write-Dim($msg)  { Write-Host "  $msg" -ForegroundColor DarkGray }

Write-Host ""
Write-Host "  ClawGod Installer" -ForegroundColor White -NoNewline
Write-Host " (Windows)" -ForegroundColor DarkGray
Write-Host ""

# ─── Uninstall ────────────────────────────────────────

if ($Uninstall) {
    # Restore original claude
    $claudeOrig = Join-Path $BinDir "claude.orig.cmd"
    $claudeCmd  = Join-Path $BinDir "claude.cmd"
    if (Test-Path $claudeOrig) {
        Move-Item -Force $claudeOrig $claudeCmd
        Write-OK "Original claude restored"
    }
    # Also check for .exe backup
    $claudeExeOrig = Join-Path $BinDir "claude.orig.exe"
    $claudeExe     = Join-Path $BinDir "claude.exe"
    if (Test-Path $claudeExeOrig) {
        Move-Item -Force $claudeExeOrig $claudeExe
        Write-OK "Original claude.exe restored"
    }

    foreach ($f in @("cli.js","cli.original.js","cli.original.js.bak","patch.js","node_modules")) {
        $p = Join-Path $ClawDir $f
        if (Test-Path $p) { Remove-Item -Recurse -Force $p }
    }
    Write-OK "ClawGod uninstalled"
    Write-Host ""
    exit 0
}

# ─── Prerequisites ────────────────────────────────────

try { $null = Get-Command node -ErrorAction Stop }
catch {
    Write-Err "Node.js is required (>= 18). Install from https://nodejs.org"
    exit 1
}

$nodeVer = [int](node -e "console.log(process.versions.node.split('.')[0])")
if ($nodeVer -lt 18) {
    Write-Err "Node.js >= 18 required (found v$nodeVer)"
    exit 1
}

try { $null = Get-Command npm -ErrorAction Stop }
catch {
    Write-Err "npm is required"
    exit 1
}

# ─── Install Claude Code from npm ─────────────────────

New-Item -ItemType Directory -Force -Path $ClawDir | Out-Null
New-Item -ItemType Directory -Force -Path $BinDir  | Out-Null

Write-Dim "Installing @anthropic-ai/claude-code@$Version ..."
npm install --prefix $ClawDir "@anthropic-ai/claude-code@$Version" --save-exact --no-fund --no-audit 2>$null | Out-Null
$installedVer = node -e "console.log(require('$($ClawDir -replace '\\','/')/node_modules/@anthropic-ai/claude-code/package.json').version)"
Write-OK "Claude Code v$installedVer downloaded"

# ─── Copy bundle ──────────────────────────────────────

$srcCli = Join-Path $ClawDir "node_modules\@anthropic-ai\claude-code\cli.js"
$dstCli = Join-Path $ClawDir "cli.original.js"
Copy-Item -Force $srcCli $dstCli
Write-OK "Bundle extracted (cli.original.js)"

# ─── Write package.json (ESM support) ─────────────────

@'
{"type":"module"}
'@ | Set-Content (Join-Path $ClawDir "package.json") -Encoding UTF8

# ─── Write wrapper (cli.js) ───────────────────────────

@'
#!/usr/bin/env node
import { readFileSync, existsSync, mkdirSync, writeFileSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';

const claudeDir = join(homedir(), '.claude');
const clawgodDir = join(homedir(), '.clawgod');
const configDir = process.env.CLAUDE_CONFIG_DIR || (existsSync(claudeDir) ? claudeDir : clawgodDir);
const providerDir = clawgodDir;
const configFile = join(providerDir, 'provider.json');

const defaultConfig = {
  apiKey: '',
  baseURL: 'https://api.anthropic.com',
  model: '',
  smallModel: '',
  timeoutMs: 3000000,
};

let config = { ...defaultConfig };
if (existsSync(configFile)) {
  try {
    const raw = JSON.parse(readFileSync(configFile, 'utf8'));
    config = { ...defaultConfig, ...raw };
  } catch {}
} else {
  mkdirSync(providerDir, { recursive: true });
  writeFileSync(configFile, JSON.stringify(defaultConfig, null, 2) + '\n');
}

if (config.apiKey) {
  process.env.ANTHROPIC_API_KEY ??= config.apiKey;
}
if (config.baseURL && config.baseURL !== defaultConfig.baseURL) {
  process.env.ANTHROPIC_BASE_URL ??= config.baseURL;
}
if (config.apiKey && config.model) {
  process.env.ANTHROPIC_MODEL ??= config.model;
}
if (config.apiKey && config.smallModel) {
  process.env.ANTHROPIC_SMALL_FAST_MODEL ??= config.smallModel;
}
if (config.timeoutMs) {
  process.env.API_TIMEOUT_MS ??= String(config.timeoutMs);
}
process.env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC ??= '1';
process.env.DISABLE_INSTALLATION_CHECKS ??= '1';
process.env.CLAUDE_CONFIG_DIR ??= configDir;

const featuresFile = join(providerDir, 'features.json');
if (!process.env.CLAUDE_INTERNAL_FC_OVERRIDES && existsSync(featuresFile)) {
  try {
    const raw = readFileSync(featuresFile, 'utf8');
    JSON.parse(raw);
    process.env.CLAUDE_INTERNAL_FC_OVERRIDES = raw;
  } catch {}
}

await import('./cli.original.js');
'@ | Set-Content (Join-Path $ClawDir "cli.js") -Encoding UTF8
Write-OK "Wrapper created (cli.js)"

# ─── Write universal patcher ──────────────────────────
# (Same Node.js patcher as bash version — extract from install.sh or inline)

$patcherUrl = "https://raw.githubusercontent.com/0Chencc/clawgod/main/patcher.mjs"

# Inline the patcher to avoid extra download
$patcherCode = @'
#!/usr/bin/env node
/**
 * ClawGod Universal Patcher
 */
import { readFileSync, writeFileSync, existsSync, copyFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const TARGET = join(__dirname, 'cli.original.js');
const BACKUP = TARGET + '.bak';

const patches = [
  {
    name: 'USER_TYPE → ant',
    pattern: /function (\w+)\(\)\{return"external"\}/g,
    replacer: (m, fn) => `function ${fn}(){return"ant"}`,
  },
  {
    name: 'GrowthBook env overrides',
    pattern: /function (\w+)\(\)\{if\(!(\w+)\)(\w+)=!0;return (\w+)\}/g,
    replacer: (m, fn, flag, flag2, val) =>
      `function ${fn}(){if(!${flag}){${flag2}=!0;try{let e=process.env.CLAUDE_INTERNAL_FC_OVERRIDES;if(e)${val}=JSON.parse(e)}catch(e){}}return ${val}}`,
    unique: true,
  },
  {
    name: 'GrowthBook config overrides',
    pattern: /function (\w+)\(\)\{return\}(function)/g,
    replacer: (m, fn, next) =>
      `function ${fn}(){try{return j8().growthBookOverrides??null}catch{return null}}${next}`,
    selectIndex: 0,
    validate: (match, code) => {
      const pos = code.indexOf(match);
      const nearby = code.substring(Math.max(0, pos - 500), pos + 500);
      return nearby.includes('growthBook') || nearby.includes('GrowthBook') || nearby.includes('FeatureValue');
    },
  },
  {
    name: 'Agent Teams always enabled',
    pattern: /function (\w+)\(\)\{if\(!\w+\(process\.env\.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS\)&&!\w+\(\)\)return!1;if\(!\w+\("tengu_amber_flint",!0\)\)return!1;return!0\}/g,
    replacer: (m, fn) => `function ${fn}(){return!0}`,
  },
  {
    name: 'Computer Use subscription bypass',
    pattern: /function (\w+)\(\)\{let \w+=\w+\(\);return \w+==="max"\|\|\w+==="pro"\}/g,
    replacer: (m, fn) => `function ${fn}(){return!0}`,
  },
  {
    name: 'Computer Use default enabled',
    pattern: /(\w+=)\{enabled:!1,pixelValidation/g,
    replacer: (m, prefix) => `${prefix}{enabled:!0,pixelValidation`,
  },
  {
    name: 'Ultraplan enable',
    pattern: /(name:"ultraplan",description:`[^`]+`,argumentHint:"<prompt>",isEnabled:\(\)=>)!1/g,
    replacer: (m, prefix) => `${prefix}!0`,
    optional: true,
  },
  {
    name: 'Ultrareview enable',
    pattern: /function (\w+)\(\)\{return \w+\("tengu_review_bughunter_config",null\)\?\.enabled===!0\}/g,
    replacer: (m, fn) => `function ${fn}(){return!0}`,
  },
  {
    name: 'Logo + brand color → green (RGB dark)',
    pattern: /clawd_body:"rgb\(215,119,87\)"/g,
    replacer: () => 'clawd_body:"rgb(34,197,94)"',
  },
  {
    name: 'Logo + brand color → green (ANSI)',
    pattern: /clawd_body:"ansi:redBright"/g,
    replacer: () => 'clawd_body:"ansi:greenBright"',
  },
  {
    name: 'Theme claude color → green (dark)',
    pattern: /claude:"rgb\(215,119,87\)"/g,
    replacer: () => 'claude:"rgb(34,197,94)"',
  },
  {
    name: 'Theme claude color → green (light)',
    pattern: /claude:"rgb\(255,153,51\)"/g,
    replacer: () => 'claude:"rgb(22,163,74)"',
  },
  {
    name: 'Shimmer → green',
    pattern: /claudeShimmer:"rgb\(2[34]5,1[45]9,1[12]7\)"/g,
    replacer: () => 'claudeShimmer:"rgb(74,222,128)"',
  },
  {
    name: 'Shimmer light → green',
    pattern: /claudeShimmer:"rgb\(255,183,101\)"/g,
    replacer: () => 'claudeShimmer:"rgb(34,197,94)"',
  },
  {
    name: 'Hex brand color → green',
    pattern: /#da7756/g,
    replacer: () => '#22c55e',
  },
  {
    name: 'Remove CYBER_RISK_INSTRUCTION',
    pattern: /(\w+)="IMPORTANT: Assist with authorized security testing[^"]*"/g,
    replacer: (m, varName) => `${varName}=""`,
  },
  {
    name: 'Remove URL generation restriction',
    pattern: /\n\$\{\w+\}\nIMPORTANT: You must NEVER generate or guess URLs[^.]*\. You may use URLs provided by the user in their messages or local files\./g,
    replacer: () => '',
  },
  {
    name: 'Remove cautious actions section',
    pattern: /function (\w+)\(\)\{return`# Executing actions with care\n\n[\s\S]*?`\}/g,
    replacer: (m, fn) => `function ${fn}(){return\`\`}`,
  },
  {
    name: 'Remove "Not logged in" notice',
    pattern: /Not logged in\. Run [\w ]+ to authenticate\./g,
    replacer: () => '',
    optional: true,
  },
  {
    name: 'Attachment filter bypass',
    pattern: /(\w+\(\)!=="ant"\)\{if\(\w+\.attachment\.type==="hook_additional_context")/g,
    replacer: (m, orig) => m.replace(/\w+\(\)!=="ant"/, 'false'),
  },
  {
    name: 'Message list filter bypass',
    pattern: /(\w+)\(\)!=="ant"\?(\w+)\((\w+),(\w+)\((\w+)\)\):(\w+)/g,
    replacer: (m, fn, tRY, underscore, sRY, K, fallback) => fallback,
  },
];

const args = process.argv.slice(2);
const dryRun = args.includes('--dry-run');
const verify = args.includes('--verify');
const revert = args.includes('--revert');

if (revert) {
  if (!existsSync(BACKUP)) { console.error('No backup found'); process.exit(1); }
  copyFileSync(BACKUP, TARGET);
  console.log('Reverted from backup');
  process.exit(0);
}

if (!existsSync(TARGET)) {
  console.error('Target not found:', TARGET);
  process.exit(1);
}

let code = readFileSync(TARGET, 'utf8');
const origSize = code.length;
const verMatch = code.match(/Version:\s*([\d.]+)/);
const version = verMatch ? verMatch[1] : 'unknown';

console.log(`\n${'='.repeat(55)}`);
console.log(`  ClawGod (universal)`);
console.log(`  Target: cli.original.js (v${version})`);
console.log(`  Mode: ${dryRun ? 'DRY RUN' : verify ? 'VERIFY' : 'APPLY'}`);
console.log(`${'='.repeat(55)}\n`);

let applied = 0, skipped = 0, failed = 0;

for (const p of patches) {
  const matches = [...code.matchAll(p.pattern)];
  let relevant = matches;
  if (p.validate) relevant = matches.filter(m => p.validate(m[0], code));
  if (p.selectIndex !== undefined) relevant = relevant.length > p.selectIndex ? [relevant[p.selectIndex]] : [];
  if (p.unique && relevant.length !== 1) {
    console.log(`  ?? ${p.name} — ${relevant.length} matches`);
    failed++; continue;
  }
  if (relevant.length === 0) {
    if (p.optional) { console.log(`  >> ${p.name} (not in this version)`); skipped++; }
    else { console.log(`  OK ${p.name} (already applied)`); applied++; }
    continue;
  }
  if (verify) { console.log(`  -- ${p.name} — not yet applied`); skipped++; continue; }
  let count = 0;
  for (const m of relevant) {
    const replacement = p.replacer(m[0], ...m.slice(1));
    if (replacement !== m[0]) { if (!dryRun) code = code.replace(m[0], replacement); count++; }
  }
  if (count > 0) { console.log(`  OK ${p.name} (${count})`); applied++; }
  else { console.log(`  >> ${p.name} (no change)`); skipped++; }
}

console.log(`\n${'-'.repeat(55)}`);
console.log(`  Result: ${applied} applied, ${skipped} skipped, ${failed} failed`);

if (!dryRun && !verify && applied > 0) {
  if (!existsSync(BACKUP)) { copyFileSync(TARGET, BACKUP); console.log(`  Backup: ${BACKUP}`); }
  writeFileSync(TARGET, code, 'utf8');
  console.log(`  Written: cli.original.js (${code.length - origSize} bytes)`);
}
console.log(`${'='.repeat(55)}\n`);
'@

Set-Content (Join-Path $ClawDir "patch.js") $patcherCode -Encoding UTF8
Write-OK "Patcher created (patch.js)"

# ─── Apply patches ────────────────────────────────────

Write-Dim "Applying patches ..."
node (Join-Path $ClawDir "patch.js")

# ─── Create default configs ───────────────────────────

$featuresFile = Join-Path $ClawDir "features.json"
if (-not (Test-Path $featuresFile)) {
    @'
{
  "tengu_harbor": true,
  "tengu_session_memory": true,
  "tengu_amber_flint": true,
  "tengu_auto_background_agents": true,
  "tengu_destructive_command_warning": true,
  "tengu_immediate_model_command": true,
  "tengu_desktop_upsell": false
}
'@ | Set-Content $featuresFile -Encoding UTF8
    Write-OK "Default features.json created"
}

# ─── Replace claude command ───────────────────────────

$launcherContent = @"
@echo off
node "$ClawDir\cli.js" %*
"@

# Find and back up original claude
$claudeCmd = Join-Path $BinDir "claude.cmd"
$claudeExe = Join-Path $BinDir "claude.exe"
$claudeOrigCmd = Join-Path $BinDir "claude.orig.cmd"
$claudeOrigExe = Join-Path $BinDir "claude.orig.exe"

# Check multiple locations for original claude
$originalFound = $false
foreach ($loc in @(
    (Join-Path $BinDir "claude.exe"),
    (Join-Path $BinDir "claude.cmd"),
    (Join-Path $env:USERPROFILE ".local\share\claude\versions"),
    (Join-Path $env:LOCALAPPDATA "Programs\claude-code")
)) {
    if (Test-Path $loc) {
        # Back up .exe if exists and not already backed up
        if ($loc -like "*.exe" -and -not (Test-Path $claudeOrigExe)) {
            Copy-Item $loc $claudeOrigExe -Force
            Write-OK "Original claude.exe backed up → claude.orig.exe"
            $originalFound = $true
        }
        # Back up .cmd if exists and not already backed up
        if ($loc -like "*.cmd" -and -not (Test-Path $claudeOrigCmd)) {
            Copy-Item $loc $claudeOrigCmd -Force
            Write-OK "Original claude.cmd backed up → claude.orig.cmd"
            $originalFound = $true
        }
        # If it's a versions directory, find the latest exe
        if (Test-Path $loc -PathType Container) {
            $latestExe = Get-ChildItem $loc -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latestExe -and -not (Test-Path $claudeOrigExe)) {
                Copy-Item $latestExe.FullName $claudeOrigExe -Force
                Write-OK "Original claude backed up → claude.orig.exe ($($latestExe.Name))"
                $originalFound = $true
            }
        }
        break
    }
}

# Write .cmd launcher for 'claude'
foreach ($cmd in @("claude")) {
    $launcherContent | Set-Content (Join-Path $BinDir "$cmd.cmd") -Encoding ASCII
}
Write-OK "Command 'claude' → patched"

# ─── Ensure BinDir is in PATH ─────────────────────────

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$BinDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$BinDir;$userPath", "User")
    $env:Path = "$BinDir;$env:Path"
    Write-OK "Added $BinDir to user PATH"
    Write-Dim "(restart terminal for PATH to take effect)"
}

# ─── Done ─────────────────────────────────────────────

Write-Host ""
Write-Host "  ClawGod installed!" -ForegroundColor Green
Write-Host ""
Write-Dim "  claude            — Start patched Claude Code (green logo)"
Write-Dim "  claude.orig       — Run original unpatched Claude Code"
Write-Host ""
Write-Err "  If 'claude' still runs the old version, restart your terminal."
Write-Host ""
Write-Dim "  Config: ~/.clawgod/provider.json"
Write-Dim "  Flags:  ~/.clawgod/features.json"
Write-Host ""
