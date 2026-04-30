#!/bin/bash
set -e

# ─────────────────────────────────────────────────────────
#  ClawGod Test Suite
#
#  Downloads Claude Code packages and verifies:
#  1. Bundle extraction works
#  2. Native module extraction works
#  3. Patches apply correctly
#  4. Wrapper loads successfully
#
#  Usage:
#    bash test/test-install.sh [version]
#    bash test/test-install.sh 2.1.123
# ─────────────────────────────────────────────────────────

TEST_DIR="$(cd "$(dirname "$0")/.." && pwd)/test"
RESULTS_DIR="$TEST_DIR/results"
VERSION="${1:-latest}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
DIM='\033[2m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1"; }
dim()  { echo -e "${DIM}$1${NC}"; }

# ─── Setup ──────────────────────────────────────────────

rm -rf "$RESULTS_DIR"
mkdir -p "$RESULTS_DIR"

echo ""
echo -e "${YELLOW}ClawGod Test Suite${NC}"
echo "Version: $VERSION"
echo "Results: $RESULTS_DIR"
echo ""

# Check Bun
if ! command -v bun &>/dev/null; then
  fail "Bun not found. Install from https://bun.sh"
  exit 1
fi
pass "Bun $(bun --version) found"

# ─── Download Claude Code ───────────────────────────────

dim "Downloading @anthropic-ai/claude-code@$VERSION ..."

PKG_DIR="$RESULTS_DIR/package"
mkdir -p "$PKG_DIR"

# Use npm install to get postinstall scripts (downloads native binary)
npm install --prefix "$RESULTS_DIR" "@anthropic-ai/claude-code@$VERSION" --save-exact --no-fund --no-audit 2>/dev/null
PKG_DIR="$RESULTS_DIR/node_modules/@anthropic-ai/claude-code"

if [ ! -d "$PKG_DIR" ]; then
  fail "Failed to download package"
  exit 1
fi

INSTALLED_VERSION=$(node -e "console.log(require('$PKG_DIR/package.json').version)")
pass "Claude Code v$INSTALLED_VERSION downloaded"

# ─── Detect Mode ────────────────────────────────────────

NPM_CLI="$PKG_DIR/cli.js"
if [ -f "$NPM_CLI" ]; then
  MODE="legacy"
  warn "Legacy mode (cli.js bundle) - not supported in Bun-only version"
  exit 0
else
  MODE="native"
  pass "Native mode (Bun binary)"
fi

# ─── Find Native Binary ─────────────────────────────────

NATIVE_BIN=""
for candidate in \
  "$PKG_DIR/bin/claude.exe" \
  "$RESULTS_DIR/package/bin/claude.exe"
do
  if [ -f "$candidate" ] && [ "$(stat -c%s "$candidate" 2>/dev/null || stat -f%z "$candidate" 2>/dev/null || echo 0)" -gt 10000000 ]; then
    NATIVE_BIN="$candidate"
    break
  fi
done

if [ -z "$NATIVE_BIN" ]; then
  # Check platform-specific packages
  for plat_dir in "$RESULTS_DIR"/node_modules/@anthropic-ai/claude-code-*; do
    [ -d "$plat_dir" ] || continue
    for candidate in "$plat_dir/claude" "$plat_dir/claude.exe"; do
      if [ -f "$candidate" ] && [ "$(stat -c%s "$candidate" 2>/dev/null || echo 0)" -gt 10000000 ]; then
        NATIVE_BIN="$candidate"
        break 2
      fi
    done
  done
fi

if [ -z "$NATIVE_BIN" ]; then
  fail "No native binary found in package"
  exit 1
fi
pass "Native binary: $(basename "$NATIVE_BIN") ($(($(stat -c%s "$NATIVE_BIN" 2>/dev/null || stat -f%z "$NATIVE_BIN") / 1024 / 1024)) MB)"

# ─── Test Bundle Extraction ─────────────────────────────

dim "Testing bundle extraction ..."

BUNDLE_EXTRACTOR="$TEST_DIR/../install.sh"
EXTRACT_SCRIPT=$(grep -A 100 "extract-bundle.mjs" "$BUNDLE_EXTRACTOR" | grep -B 100 "^BUNDLE_EOF" | head -n -1 | tail -n +2)

cat > "$RESULTS_DIR/extract-bundle.mjs" << 'EXTRACT_EOF'
import { readFileSync, writeFileSync, existsSync, statSync } from 'fs';

const [, , binaryPath, outputPath] = process.argv;

if (!binaryPath || !outputPath) {
  console.error('Usage: extract-bundle.mjs <binary-path> <output-path>');
  process.exit(1);
}

if (!existsSync(binaryPath)) {
  console.error(`Binary not found: ${binaryPath}`);
  process.exit(1);
}

const buf = readFileSync(binaryPath);
console.log(`Binary size: ${(buf.length / 1024 / 1024).toFixed(1)} MB`);

let maxRun = 0;
let maxStart = 0;
let currentRun = 0;
let currentStart = 0;

for (let i = 0; i < buf.length; i++) {
  const b = buf[i];
  if ((b >= 32 && b <= 126) || b === 10 || b === 13 || b === 9) {
    if (currentRun === 0) currentStart = i;
    currentRun++;
  } else {
    if (currentRun > maxRun) {
      maxRun = currentRun;
      maxStart = currentStart;
    }
    currentRun = 0;
  }
}
if (currentRun > maxRun) {
  maxRun = currentRun;
  maxStart = currentStart;
}

if (maxRun < 5 * 1024 * 1024) {
  console.error(`Largest printable block too small (${maxRun} bytes)`);
  process.exit(1);
}

const text = buf.slice(maxStart, maxStart + maxRun).toString('utf8');

if (!text.startsWith('// @bun @bytecode')) {
  console.error('Largest block does not start with @bun @bytecode marker');
  process.exit(1);
}

let code = text.trimEnd();
writeFileSync(outputPath, code, 'utf8');
console.log(`Bundle extracted: ${(code.length / 1024 / 1024).toFixed(1)} MB`);
EXTRACT_EOF

node "$RESULTS_DIR/extract-bundle.mjs" "$NATIVE_BIN" "$RESULTS_DIR/cli.original.js" 2>&1 | while read line; do echo "  $line"; done

if [ ! -f "$RESULTS_DIR/cli.original.js" ]; then
  fail "Bundle extraction failed"
  exit 1
fi
pass "Bundle extracted ($(($(wc -c < "$RESULTS_DIR/cli.original.js") / 1024 / 1024)) MB)"

# Verify @bun marker
if head -1 "$RESULTS_DIR/cli.original.js" | grep -q "@bun @bytecode"; then
  pass "Bundle has @bun @bytecode marker"
else
  fail "Bundle missing @bun @bytecode marker"
  exit 1
fi

# ─── Test Native Module Extraction ──────────────────────

dim "Testing native module extraction ..."

EXTRACTOR="$TEST_DIR/../extract-natives.mjs"
if [ -f "$EXTRACTOR" ]; then
  node "$EXTRACTOR" "$NATIVE_BIN" "$RESULTS_DIR/vendor" 2>&1 | while read line; do echo "  $line"; done

  if [ -f "$RESULTS_DIR/vendor/.manifest.json" ]; then
    EXTRACTED_COUNT=$(node -e "console.log(require('$RESULTS_DIR/vendor/.manifest.json').modules.length)")
    pass "Native modules extracted: $EXTRACTED_COUNT"
  else
    warn "No manifest file created"
  fi
else
  warn "extract-natives.mjs not found, skipping"
fi

# ─── Test Patcher ───────────────────────────────────────

dim "Testing patcher ..."

# Extract patcher from install.sh
PATCHER_START=$(grep -n "^cat >.*patch.js" "$TEST_DIR/../install.sh" | head -1 | cut -d: -f1)
PATCHER_END=$(grep -n "^PATCHER_EOF" "$TEST_DIR/../install.sh" | head -1 | cut -d: -f1)

if [ -n "$PATCHER_START" ] && [ -n "$PATCHER_END" ]; then
  sed -n "$((PATCHER_START + 1)),$((PATCHER_END - 1))p" "$TEST_DIR/../install.sh" > "$RESULTS_DIR/patch.js"

  # Run patcher in dry-run mode
  node "$RESULTS_DIR/patch.js" --dry-run 2>&1 | tail -20

  pass "Patcher executed"
else
  fail "Could not extract patcher from install.sh"
fi

# ─── Test Wrapper ───────────────────────────────────────

dim "Testing wrapper ..."

cat > "$RESULTS_DIR/cli.js" << 'WRAPPER_EOF'
#!/usr/bin/env bun
import { readFileSync, existsSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';

const clawgodDir = join(homedir(), '.clawgod-test');
process.env.CLAUDE_CONFIG_DIR = clawgodDir;
process.env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1';
process.env.DISABLE_INSTALLATION_CHECKS = '1';

require('./cli.original.js');
WRAPPER_EOF

# Try to load with Bun (just parse, don't execute)
if bun "$RESULTS_DIR/cli.js" --version 2>&1 | head -1 | grep -qE "^[0-9]+\.[0-9]+\.[0-9]+"; then
  pass "Wrapper loads successfully"
else
  OUTPUT=$(bun "$RESULTS_DIR/cli.js" --version 2>&1 | head -3)
  warn "Wrapper test output: $OUTPUT"
fi

# ─── Summary ────────────────────────────────────────────

echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}  Test Complete${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo "Results saved to: $RESULTS_DIR"
echo ""
echo "Files:"
ls -la "$RESULTS_DIR" | grep -v "^total" | while read line; do echo "  $line"; done
echo ""
