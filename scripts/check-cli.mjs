#!/usr/bin/env node
// Check the actual packed CLI, not just its version string or source checkout.
// Default: the exact npm release used by production. --from-local is for
// pre-publish integration and the explicitly bundled external-test variant.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');

export function releasePackage() {
  const source = readFileSync(join(projectRoot, 'VibeUsage/Services/RuntimeDetector.swift'), 'utf8');
  const specifier = source.match(/static let defaultPackageSpecifier = "([^"]+)"/)?.[1];
  assert.match(specifier || '', /^@vibe-cafe\/vibe-usage@(latest|\d+\.\d+\.\d+)$/, 'CLI must be an explicit package reference');
  return specifier;
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: 'utf8', timeout: 60_000, maxBuffer: 2 * 1024 * 1024, ...options,
  });
  if (result.error || result.status !== 0) {
    throw new Error(`${command} ${args[0]} failed (${result.error?.code || result.status})`);
  }
  return result.stdout;
}

export function verifyPackage(packageRoot, specifier = releasePackage()) {
  const version = specifier.slice(specifier.lastIndexOf('@') + 1);
  const manifest = JSON.parse(readFileSync(join(packageRoot, 'package.json'), 'utf8'));
  assert.equal(manifest.name, '@vibe-cafe/vibe-usage', 'Unexpected CLI package');
  assert.equal(typeof manifest.version, 'string', 'Packed CLI has no version');
  assert.ok(manifest.version.length > 0, 'Packed CLI has an empty version');
  assert.equal(manifest.bin?.['vibe-usage'], 'bin/vibe-usage.js', 'CLI entry point changed');

  const fixtureRoot = mkdtempSync(join(tmpdir(), 'vibe-cli-contract-'));
  try {
    // No inherited credentials, NODE_OPTIONS, or user config. The selected
    // providers have no credentials/logs in these disposable directories.
    const environment = {
      PATH: process.env.PATH || '',
      TMPDIR: fixtureRoot,
      VIBE_USAGE_CONFIG_DIR: join(fixtureRoot, 'config'),
      VIBE_USAGE_STATE_DIR: join(fixtureRoot, 'state'),
      VIBE_USAGE_QUOTA_CACHE_DIR: join(fixtureRoot, 'quota-cache'),
      KIMI_CODE_HOME: join(fixtureRoot, 'kimi-code'),
      KIMI_SHARE_DIR: join(fixtureRoot, 'kimi'),
      GROK_HOME: join(fixtureRoot, 'grok'),
    };
    const invoke = args => JSON.parse(run(process.execPath,
      [join(packageRoot, 'bin/vibe-usage.js'), ...args], { env: environment, cwd: fixtureRoot }));
    assert.deepEqual(invoke(['config', 'roots']), {}, 'Config output must stay JSON-only');
    const discovery = invoke(['quota', 'discover', '--json']);
    assert.equal(discovery.schemaVersion, 1, 'Unsupported quota discovery schema');
    const products = ['kimi-code', 'zcode', 'grok'];
    for (const id of products) {
      assert.equal(discovery.products.find(product => product.id === id)?.fetchable, true,
        `Missing quota adapter: ${id}`);
    }
    assert.equal(discovery.products.find(product => product.id === 'cursor')?.fetchable, false);
    const quota = invoke(['quota', 'fetch', ...products.flatMap(id => ['--product', id]), '--json']);
    assert.equal(quota.schemaVersion, 1, 'Unsupported quota fetch schema');
    assert.deepEqual(quota.products.map(product => product.id), products);
    assert.deepEqual(quota.products.map(product => product.status),
      ['missing_credentials', 'missing_credentials', 'no_data']);
    for (const product of quota.products) {
      assert.deepEqual(product.meters, []);
      assert.ok(Number.isFinite(Date.parse(product.fetchedAt)), 'Missing quota timestamp');
      assert.equal(typeof product.source, 'string');
    }
  } finally {
    rmSync(fixtureRoot, { recursive: true, force: true });
  }
}

export function checkCLI(localSource) {
  const specifier = releasePackage();
  const packRoot = mkdtempSync(join(tmpdir(), 'vibe-cli-pack-'));
  try {
    const source = localSource ? resolve(localSource) : specifier;
    let packed;
    try {
      packed = JSON.parse(run('npm', ['pack', source, '--ignore-scripts', '--json',
        '--prefer-online', '--pack-destination', packRoot], { cwd: packRoot }));
    } catch {
      throw new Error(`无法获取 ${source}。正式打包前必须先发布并验证 CLI（${specifier}）及其配额协议。`);
    }
    // `npm pack --json` returns an array of entries, or — for a single package
    // on npm 12 — an object keyed by package name. Accept both: a local npm
    // upgrade must not fail the packaging preflight for a reason that has
    // nothing to do with the CLI contract.
    const packedEntries = Array.isArray(packed) ? packed : Object.values(packed);
    assert.equal(packedEntries.length, 1, 'Expected one CLI package');
    const filename = packedEntries[0].filename;
    assert.ok(filename && !filename.includes('/') && !filename.includes('\\'));
    run('tar', ['-xzf', join(packRoot, filename), '-C', packRoot]);
    verifyPackage(join(packRoot, 'package'), specifier);
    console.log(`CLI contract OK: ${specifier} (${localSource ? 'local package; publication still required' : 'published npm package'})`);
  } finally {
    rmSync(packRoot, { recursive: true, force: true });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = process.argv.slice(2);
    assert.ok(args.length === 0 || (args.length === 2 && args[0] === '--from-local'),
      'Usage: node scripts/check-cli.mjs [--from-local <CLI checkout or tarball>]');
    checkCLI(args[1]);
  } catch (error) {
    console.error(`CLI contract check failed: ${error.message}`);
    process.exitCode = 1;
  }
}
