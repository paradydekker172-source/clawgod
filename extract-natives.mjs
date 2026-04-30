#!/usr/bin/env node
/**
 * ClawGod native module extractor
 *
 * Extracts embedded .node NAPI modules from a Bun single-file executable
 * (the official Claude Code native binary).
 *
 * Supports:
 *   - Mach-O (macOS) — arm64 + x86_64 thin binaries
 *   - ELF (Linux)    — arm64 + x86_64
 *   - PE (Windows)   — x86_64 + arm64
 *
 * Usage:
 *   node extract-natives.mjs <binary-path> <output-dir>
 *   bun extract-natives.mjs <binary-path> <output-dir>
 */

import { readFileSync, writeFileSync, mkdirSync, existsSync, statSync } from 'fs';
import { join, basename, resolve } from 'path';

// ─── Path anchoring ───────────────────────────────────────────────────

const [, , binaryPath, outputDir] = process.argv;

if (!binaryPath || !outputDir) {
  console.error('Usage: extract-natives.mjs <binary-path> <output-dir>');
  process.exit(1);
}

const VENDOR_DIR = resolve(outputDir);
const MANIFEST_FILE = join(VENDOR_DIR, '.manifest.json');

// ─── Mach-O constants ────────────────────────────────────────────────

const MH_MAGIC_64 = 0xfeedfacf;           // little-endian 64-bit
const LC_SEGMENT_64 = 0x19;
const LC_ID_DYLIB = 0x0d;
const MH_DYLIB = 6;
const CPU_TYPE_X86_64 = 0x01000007;
const CPU_TYPE_ARM64 = 0x0100000c;

// ─── ELF constants ───────────────────────────────────────────────────

const ELF_MAGIC = Buffer.from([0x7f, 0x45, 0x4c, 0x46]); // 7f 'E' 'L' 'F'
const ET_DYN = 3;                          // shared object
const EM_X86_64 = 62;
const EM_AARCH64 = 183;

// ─── PE constants ────────────────────────────────────────────────────

const MZ_MAGIC = Buffer.from([0x4d, 0x5a]);   // "MZ"
const PE_MAGIC = Buffer.from([0x50, 0x45, 0, 0]); // "PE\0\0"
const IMAGE_FILE_MACHINE_AMD64 = 0x8664;
const IMAGE_FILE_MACHINE_ARM64 = 0xaa64;
const IMAGE_FILE_DLL = 0x2000;

// ─── Helpers ─────────────────────────────────────────────────────────

function archName(format, cputype) {
  if (format === 'macho') {
    if (cputype === CPU_TYPE_ARM64) return 'arm64';
    if (cputype === CPU_TYPE_X86_64) return 'x64';
  }
  if (format === 'elf') {
    if (cputype === EM_AARCH64) return 'arm64';
    if (cputype === EM_X86_64) return 'x64';
  }
  if (format === 'pe') {
    if (cputype === IMAGE_FILE_MACHINE_ARM64) return 'arm64';
    if (cputype === IMAGE_FILE_MACHINE_AMD64) return 'x64';
  }
  return null;
}

function platformSuffix(format, arch) {
  const os = format === 'macho' ? 'darwin' : format === 'elf' ? 'linux' : 'win32';
  return `${arch}-${os}`;
}

// ─── Mach-O parser ───────────────────────────────────────────────────

function parseMachODylib(buf, off) {
  const magic = buf.readUInt32LE(off);
  if (magic !== MH_MAGIC_64) return null;

  const cputype = buf.readUInt32LE(off + 4);
  if (cputype !== CPU_TYPE_ARM64 && cputype !== CPU_TYPE_X86_64) return null;

  const filetype = buf.readUInt32LE(off + 12);
  if (filetype !== MH_DYLIB) return null;

  const ncmds = buf.readUInt32LE(off + 16);
  if (ncmds === 0 || ncmds > 500) return null;

  let totalFileEnd = 0;
  let installName = null;
  let cmdOff = off + 32;

  for (let i = 0; i < ncmds; i++) {
    if (cmdOff + 8 > buf.length) return null;

    const cmd = buf.readUInt32LE(cmdOff);
    const cmdsize = buf.readUInt32LE(cmdOff + 4);
    if (cmdsize === 0 || cmdsize > 65536) return null;

    if (cmd === LC_SEGMENT_64) {
      const fileoff = Number(buf.readBigUInt64LE(cmdOff + 40));
      const filesize = Number(buf.readBigUInt64LE(cmdOff + 48));
      const end = fileoff + filesize;
      if (end > totalFileEnd) totalFileEnd = end;
    } else if (cmd === LC_ID_DYLIB) {
      const strOff = buf.readUInt32LE(cmdOff + 8);
      const nameStart = cmdOff + strOff;
      const nameEnd = buf.indexOf(0, nameStart);
      if (nameEnd !== -1 && nameEnd - nameStart < 1024) {
        installName = buf.slice(nameStart, nameEnd).toString('utf8');
      }
    }

    cmdOff += cmdsize;
  }

  if (totalFileEnd === 0) return null;

  return {
    offset: off,
    size: totalFileEnd,
    arch: archName('macho', cputype),
    installName,
  };
}

function extractMachODylibs(buf) {
  const dylibs = [];
  const magicBytes = Buffer.from([0xcf, 0xfa, 0xed, 0xfe]);

  let off = 1;
  while ((off = buf.indexOf(magicBytes, off)) !== -1) {
    const info = parseMachODylib(buf, off);
    if (info && off + info.size <= buf.length) {
      dylibs.push(info);
      off += info.size;
    } else {
      off += 4;
    }
  }

  return dylibs;
}

// ─── ELF parser ──────────────────────────────────────────────────────

function parseELFSharedObject(buf, off) {
  if (buf.length - off < 64) return null;
  if (!buf.slice(off, off + 4).equals(ELF_MAGIC)) return null;

  const eiClass = buf.readUInt8(off + 4);
  if (eiClass !== 2) return null;

  const eiData = buf.readUInt8(off + 5);
  if (eiData !== 1) return null;

  const eType = buf.readUInt16LE(off + 16);
  if (eType !== ET_DYN) return null;

  const eMachine = buf.readUInt16LE(off + 18);
  if (eMachine !== EM_X86_64 && eMachine !== EM_AARCH64) return null;

  const shoff = Number(buf.readBigUInt64LE(off + 40));
  const shentsize = buf.readUInt16LE(off + 58);
  const shnum = buf.readUInt16LE(off + 60);

  if (shentsize !== 64 || shnum === 0 || shnum > 1000) return null;

  const totalSize = shoff + shnum * shentsize;
  if (totalSize > buf.length - off) return null;

  return {
    offset: off,
    size: totalSize,
    arch: archName('elf', eMachine),
    installName: null,
  };
}

function extractELFSharedObjects(buf) {
  const sos = [];

  for (let off = 4; off < buf.length - 64; off += 4) {
    if (buf.readUInt8(off) !== 0x7f) continue;
    const info = parseELFSharedObject(buf, off);
    if (!info) continue;
    if (off + info.size > buf.length) continue;
    sos.push(info);
  }

  return sos;
}

// ─── PE parser ───────────────────────────────────────────────────────

function parsePEDll(buf, off) {
  if (buf.length - off < 1024) return null;
  if (!buf.slice(off, off + 2).equals(MZ_MAGIC)) return null;

  const peOff = buf.readUInt32LE(off + 0x3c);
  if (peOff > 4096) return null;

  if (off + peOff + 24 > buf.length) return null;
  if (!buf.slice(off + peOff, off + peOff + 4).equals(PE_MAGIC)) return null;

  const machine = buf.readUInt16LE(off + peOff + 4);
  if (machine !== IMAGE_FILE_MACHINE_AMD64 && machine !== IMAGE_FILE_MACHINE_ARM64) return null;

  const numberOfSections = buf.readUInt16LE(off + peOff + 6);
  const sizeOfOptionalHeader = buf.readUInt16LE(off + peOff + 20);
  const characteristics = buf.readUInt16LE(off + peOff + 22);
  if (!(characteristics & IMAGE_FILE_DLL)) return null;

  const sectionHeaderOff = off + peOff + 24 + sizeOfOptionalHeader;
  let totalSize = sectionHeaderOff - off;

  for (let i = 0; i < numberOfSections; i++) {
    const secOff = sectionHeaderOff + i * 40;
    if (secOff + 40 > buf.length) return null;
    const sizeOfRawData = buf.readUInt32LE(secOff + 16);
    const pointerToRawData = buf.readUInt32LE(secOff + 20);
    const end = pointerToRawData + sizeOfRawData;
    if (end > totalSize) totalSize = end;
  }

  if (totalSize === 0 || totalSize > 50 * 1024 * 1024) return null;

  return {
    offset: off,
    size: totalSize,
    arch: archName('pe', machine),
    installName: null,
  };
}

function extractPEDlls(buf) {
  const dlls = [];

  for (let off = 0; off < buf.length - 1024; off++) {
    if (buf.readUInt8(off) !== 0x4d) continue;
    if (buf.readUInt8(off + 1) !== 0x5a) continue;
    const info = parsePEDll(buf, off);
    if (!info) continue;
    if (off + info.size > buf.length) continue;
    dlls.push(info);
  }

  return dlls;
}

// ─── Main dispatch ───────────────────────────────────────────────────

function detectFormat(buf) {
  if (buf.readUInt32LE(0) === MH_MAGIC_64) return 'macho';
  if (buf.slice(0, 4).equals(ELF_MAGIC)) return 'elf';
  if (buf.slice(0, 2).equals(MZ_MAGIC)) return 'pe';
  return null;
}

const KNOWN_MODULES = [
  'image-processor',
  'audio-capture',
  'computer-use-input',
  'computer-use-swift',
  'url-handler',
];

function identifyDylib(buf, dylib) {
  const body = buf.slice(dylib.offset, dylib.offset + dylib.size);

  // Audio detection: ALSA (Linux) or WASAPI (Windows) - use binary search
  if (body.indexOf(Buffer.from('snd_pcm_open')) !== -1 ||
      body.indexOf(Buffer.from('wasapi')) !== -1 ||
      body.indexOf(Buffer.from('WASAPI')) !== -1) {
    return 'audio-capture';
  }

  // Image processor detection - use binary search
  if (body.indexOf(Buffer.from('webp')) !== -1 ||
      body.indexOf(Buffer.from('WEBP')) !== -1 ||
      body.indexOf(Buffer.from('ImagePro')) !== -1) {
    return 'image-processor';
  }

  if (dylib.installName) {
    const base = basename(dylib.installName).replace(/\.(node|dylib|so|dll)$/, '');
    for (const m of KNOWN_MODULES) {
      if (base === m) return m;
      if (base === `lib${m.replace(/-/g, '_')}`) return m;
      if (base === `lib${m.replace(/-/g, '')}`) return m;
      if (base.toLowerCase().includes(m.replace(/-/g, ''))) return m;
    }
  }

  for (const m of KNOWN_MODULES) {
    if (body.indexOf(Buffer.from(m)) !== -1) return m;
  }

  return null;
}

// ─── Main ─────────────────────────────────────────────────────────────

if (!existsSync(binaryPath)) {
  console.error(`Binary not found: ${binaryPath}`);
  process.exit(1);
}

const stat = statSync(binaryPath);
if (stat.size < 10 * 1024 * 1024) {
  console.error(`Binary too small (${stat.size} bytes) — not a native Claude Code binary`);
  process.exit(1);
}

const buf = readFileSync(binaryPath);
const format = detectFormat(buf);

if (!format) {
  console.error('Unknown binary format (expected Mach-O / ELF / PE)');
  process.exit(1);
}

console.log(`Format:  ${format}`);
console.log(`Size:    ${(buf.length / 1024 / 1024).toFixed(1)} MB`);
console.log(`Output:  ${VENDOR_DIR}`);

let libs = [];
if (format === 'macho') libs = extractMachODylibs(buf);
else if (format === 'elf') libs = extractELFSharedObjects(buf);
else if (format === 'pe') libs = extractPEDlls(buf);

libs = libs.filter(l => l.offset !== 0);

console.log(`Found:   ${libs.length} embedded native libraries`);
console.log();

// Ensure output directory exists
mkdirSync(VENDOR_DIR, { recursive: true });

const summary = { extracted: [], skipped: [] };

for (const lib of libs) {
  const name = identifyDylib(buf, lib);
  if (!name) {
    summary.skipped.push({ ...lib, reason: 'unidentified' });
    continue;
  }

  const platform = platformSuffix(format, lib.arch);
  const targetDir = join(VENDOR_DIR, name, platform);
  mkdirSync(targetDir, { recursive: true });
  const targetFile = join(targetDir, `${name}.node`);

  const data = buf.slice(lib.offset, lib.offset + lib.size);
  writeFileSync(targetFile, data);

  console.log(`  ✓ ${name.padEnd(20)} ${lib.arch.padEnd(6)} ${(lib.size / 1024).toFixed(0).padStart(5)} KB → ${targetFile}`);
  summary.extracted.push({ name, platform, size: lib.size });
}

console.log();
console.log(`Extracted ${summary.extracted.length}, skipped ${summary.skipped.length}`);

if (summary.skipped.length > 0) {
  console.log('\nSkipped (unidentified):');
  for (const s of summary.skipped) {
    console.log(`  offset=${s.offset} arch=${s.arch} size=${(s.size / 1024).toFixed(0)}KB`);
  }
}

// Write manifest for verification
const manifest = {
  version: '1.0',
  source: binaryPath,
  format,
  extractedAt: new Date().toISOString(),
  modules: summary.extracted,
};

writeFileSync(MANIFEST_FILE, JSON.stringify(manifest, null, 2));
console.log(`\nManifest: ${MANIFEST_FILE}`);
