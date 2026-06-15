#!/usr/bin/env node
/*
 * Sync Senity Chat Proxy models into Claude Code's model picker cache.
 *
 * Claude Code already reads additionalModelOptionsCache from ~/.claude.json for
 * /model. The stock bootstrap discovery only covers selected Anthropic/Gateway
 * models, so this helper fills the cache from the Senity-compatible /v1/models
 * endpoint before the TUI starts.
 */
const fs = require('fs');
const path = require('path');

const HOME = process.env.HOME || '/workspace';
const CLAUDE_JSON = path.join(HOME, '.claude.json');
const TIMEOUT_MS = parsePositiveInt(process.env.SENITY_MODEL_SYNC_TIMEOUT_MS, 5000);
const DEBUG = isTruthy(process.env.SENITY_MODEL_SYNC_DEBUG);

const PROVIDERS = {
  Anthropic: { rank: 0 },
  Senity: { rank: 1 },
};

main().catch((error) => {
  if (DEBUG) console.error(`[models] sync failed: ${error.message}`);
  process.exit(0);
});

async function main() {
  if (process.env.SENITY_MODEL_SYNC === '0') return;

  const baseUrl = normalizeBaseUrl(
    process.env.SENITY_CHAT_PROXY_URL || process.env.ANTHROPIC_BASE_URL || '',
  );
  const apiKey = process.env.SENITY_CHAT_PROXY_KEY || process.env.ANTHROPIC_API_KEY || '';

  if (!baseUrl || !apiKey) {
    if (DEBUG) console.error('[models] skipped: missing base URL or API key');
    return;
  }

  const models = await fetchModels(baseUrl, apiKey);
  const options = toModelOptions(models);
  if (options.length === 0) {
    if (DEBUG) console.error('[models] skipped: API returned no usable models');
    return;
  }

  const config = readJson(CLAUDE_JSON);
  const current = JSON.stringify(config.additionalModelOptionsCache || []);
  const next = JSON.stringify(options);
  if (current === next) {
    if (DEBUG) console.error(`[models] unchanged: ${options.length} models`);
    return;
  }

  config.additionalModelOptionsCache = options;
  writeJsonAtomic(CLAUDE_JSON, config);
  if (DEBUG) console.error(`[models] synced: ${options.length} models`);
}

async function fetchModels(baseUrl, apiKey) {
  const endpoint = `${baseUrl}/v1/models?limit=1000`;
  const response = await fetch(endpoint, {
    method: 'GET',
    headers: {
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
      'user-agent': 'senity-workspace/1.0',
    },
    signal: AbortSignal.timeout(TIMEOUT_MS),
    redirect: 'error',
  });

  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  const payload = await response.json();
  if (!payload || !Array.isArray(payload.data)) throw new Error('invalid response shape');
  return payload.data;
}

function toModelOptions(models) {
  const seen = new Set();
  return models
    .map((model, index) => normalizeModel(model, index))
    .filter((model) => {
      if (!model || seen.has(model.id)) return false;
      seen.add(model.id);
      return true;
    })
    .sort((a, b) => {
      const providerDelta = providerRank(a.provider) - providerRank(b.provider);
      return providerDelta || a.index - b.index;
    })
    .map((model) => ({
      value: model.id,
      label: `${model.provider} - ${model.displayName}`,
      description: model.description || `Provider: ${model.provider}`,
    }));
}

function normalizeModel(model, index) {
  if (!model || typeof model.id !== 'string') return null;
  const id = model.id.trim();
  if (!id) return null;
  const displayName = typeof model.display_name === 'string' && model.display_name.trim()
    ? model.display_name.trim()
    : id;
  const description = typeof model.description === 'string' && model.description.trim()
    ? `Provider: ${providerFor(id)} - ${model.description.trim()}`
    : `Provider: ${providerFor(id)}`;
  return {
    id,
    displayName,
    description,
    provider: providerFor(id),
    index,
  };
}

function providerFor(id) {
  const lower = id.toLowerCase();
  if (
    lower.startsWith('claude-') ||
    lower.startsWith('anthropic.') ||
    lower.includes('.anthropic.') ||
    lower.startsWith('us.anthropic.')
  ) {
    return 'Anthropic';
  }
  return 'Senity';
}

function providerRank(provider) {
  return PROVIDERS[provider]?.rank ?? 99;
}

function normalizeBaseUrl(value) {
  return String(value || '').trim().replace(/\/+$/, '');
}

function parsePositiveInt(value, fallback) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function isTruthy(value) {
  return /^(1|true|yes|on)$/i.test(String(value || ''));
}

function readJson(file) {
  try {
    const raw = fs.readFileSync(file, 'utf8').trim();
    return raw ? JSON.parse(raw) : {};
  } catch (error) {
    if (error && error.code === 'ENOENT') return {};
    throw error;
  }
}

function writeJsonAtomic(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, `${JSON.stringify(data, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(tmp, file);
}
