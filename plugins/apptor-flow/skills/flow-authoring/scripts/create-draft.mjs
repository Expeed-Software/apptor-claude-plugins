#!/usr/bin/env node
/**
 * create-draft.mjs — create a DRAFT flow version via the Apptor Flow REST API.
 *
 * DRAFT ONLY. This never publishes. A human publishes from the designer UI after
 * reviewing the draft. (Direct DB writes to process_version.process_text are
 * banned — the engine cache won't refresh; always go through this REST endpoint
 * or the UI.)
 *
 * Authentication: apk_ API key (M2M).
 *   `POST /api/processes` accepts an Apptor Flow API key (the `apk_…` kind). The
 *   server's `ApiKeyAuthenticationFilter` authenticates the key, derives the org
 *   from the key itself, and authorizes the call against the key's RBAC role.
 *   The key's role MUST carry the `workflow.create` permission (e.g. the built-in
 *   "Flow Creator" role, or any custom role granting `workflow.create`); a key
 *   lacking it is rejected with HTTP 403. The created draft is always scoped to
 *   the key's own organization — there is no cross-org override for ordinary keys.
 *
 * Usage:
 *   APPTOR_FLOW_BASE_URL=<your environment/tenant API URL> \
 *   APPTOR_FLOW_API_KEY=apk_xxxxx \
 *   node create-draft.mjs /abs/path/to/flow.json
 *
 * Env:
 *   APPTOR_FLOW_BASE_URL  base URL of the API server — REQUIRED, no default
 *                         (per environment/tenant; e.g. http://localhost:8080 in dev)
 *   APPTOR_FLOW_API_KEY   Apptor Flow API key, starts with `apk_` (REQUIRED)
 *
 * Argv:
 *   argv[2]  absolute (or relative) path to the flow JSON file (REQUIRED)
 *
 * Behavior:
 *   POST { "definition": "<file contents>" } to {base}/api/processes with the API
 *   key in the `X-API-Key` header. On success prints processVersionId / processId /
 *   stateCd. On any failure prints the server error body (or the local error) to
 *   stderr and exits non-zero.
 *
 * Exit codes:
 *   0  draft created
 *   2  bad usage (missing required env var, missing/empty/unreadable file)
 *   1  the server rejected the request (HTTP error) or a network/parse error
 */

import { readFile } from 'node:fs/promises';

function fail(code, message) {
  process.stderr.write(message.endsWith('\n') ? message : message + '\n');
  process.exit(code);
}

const baseUrl = (process.env.APPTOR_FLOW_BASE_URL || '').trim().replace(/\/+$/, '');
const apiKey = process.env.APPTOR_FLOW_API_KEY;

// --- Validate inputs up front (exit 2 on bad usage) ---------------------------
// No default base URL: it is per environment/tenant and MUST be supplied explicitly.
if (!baseUrl) {
  fail(
    2,
    'Error: missing required env var APPTOR_FLOW_BASE_URL.\n' +
      'Set it to your environment/tenant API base URL — there is no default ' +
      '(e.g. http://localhost:8080 in local dev). Ask the user; never assume.'
  );
}
if (!apiKey || !apiKey.trim()) {
  fail(
    2,
    'Error: missing required env var APPTOR_FLOW_API_KEY.\n' +
      'Set APPTOR_FLOW_API_KEY to an Apptor Flow API key (starts with "apk_") whose role ' +
      'grants the workflow.create permission, and retry.'
  );
}

const filePath = process.argv[2];
if (!filePath || !filePath.trim()) {
  fail(2, 'Error: missing flow JSON file path.\nUsage: node create-draft.mjs <path-to-flow.json>');
}

let definition;
try {
  definition = await readFile(filePath, 'utf8');
} catch (err) {
  fail(2, `Error: cannot read flow JSON file "${filePath}": ${err.message}`);
}

if (!definition.trim()) {
  fail(2, `Error: flow JSON file "${filePath}" is empty.`);
}

// Validate it is parseable JSON locally before sending.
let flowObj;
try {
  flowObj = JSON.parse(definition);
} catch (err) {
  fail(2, `Error: flow JSON file "${filePath}" is not valid JSON: ${err.message}`);
}

// --- Lint: catch the things instructions alone cannot enforce -----------------
// Auto-fix safe-rename issues, REJECT hard errors. Instructions ask; this enforces.
function lintAndFix(flow) {
  const fixed = [], errors = [], warnings = [];
  const nodes = Array.isArray(flow.nodes) ? flow.nodes : [];

  // 1) property entry shape: must be {"key","value"}, not {"name","value"} (the #1 trap).
  //    The parser reads property.get("key") — a {"name",...} entry is silently dropped.
  for (const node of nodes) {
    if (!Array.isArray(node.properties)) continue;
    for (const p of node.properties) {
      if (p && typeof p === 'object' && p.key === undefined && typeof p.name === 'string') {
        p.key = p.name;
        delete p.name;
        fixed.push(`node "${node.key}": property "${p.key}" used {"name","value"} (silently dropped by parser) — auto-rewritten to {"key","value"}.`);
      }
    }
  }

  // 2) Integration fields: every "<prefix>ConnectionId" needs its mandatory companion
  //    "<prefix>IntegrationVersionId" in the same node, or the runtime resolves no provider.
  for (const node of nodes) {
    if (!Array.isArray(node.properties)) continue;
    const keySet = new Set(node.properties.filter(p => p && typeof p.key === 'string').map(p => p.key));
    for (const p of node.properties) {
      if (!p || typeof p.key !== 'string') continue;
      const m = p.key.match(/^(.+?)ConnectionId$/);
      if (m) {
        const versionKey = m[1] + 'IntegrationVersionId';
        if (!keySet.has(versionKey)) {
          errors.push(`node "${node.key}": integration field "${p.key}" present but mandatory companion "${versionKey}" is missing — the runtime will resolve no provider and the step will silently do nothing. Set it to the integration's currentVersionId.`);
        }
      }
    }
  }

  // 3) Layout: warn when sequential nodes on the same row are < 280 px apart (diagram cramps).
  const buckets = new Map();
  for (const node of nodes) {
    if (typeof node.loc !== 'string') continue;
    const [x, y] = node.loc.split(/\s+/).map(Number);
    if (!Number.isFinite(x) || !Number.isFinite(y)) continue;
    const bucket = Math.round(y / 60) * 60;
    (buckets.get(bucket) || buckets.set(bucket, []).get(bucket)).push({ key: node.key, x });
  }
  for (const row of buckets.values()) {
    row.sort((a, b) => a.x - b.x);
    for (let i = 1; i < row.length; i++) {
      const dx = row[i].x - row[i - 1].x;
      if (dx < 280) {
        warnings.push(`spacing: nodes "${row[i - 1].key}" -> "${row[i].key}" have dx=${dx}px (recommend >=280px) — diagram will look cramped.`);
      }
    }
  }

  return { fixed, errors, warnings };
}

const { fixed, errors, warnings } = lintAndFix(flowObj);
for (const w of warnings) process.stderr.write(`Lint warning: ${w}\n`);
for (const f of fixed)    process.stderr.write(`Lint auto-fixed: ${f}\n`);
if (errors.length) {
  for (const e of errors) process.stderr.write(`Lint error: ${e}\n`);
  fail(1, `\nFlow rejected by lint (${errors.length} hard error${errors.length === 1 ? '' : 's'}). Fix and retry — these would silently dead-flow at runtime.`);
}

// Submit the (possibly auto-fixed) flow.
const definitionToSend = JSON.stringify(flowObj);

// --- POST the draft with the API key ------------------------------------------
const url = `${baseUrl}/api/processes`;
const headers = {
  'Content-Type': 'application/json',
  'X-API-Key': apiKey.trim(),
};

let res;
try {
  res = await fetch(url, {
    method: 'POST',
    headers,
    body: JSON.stringify({ definition: definitionToSend }),
  });
} catch (err) {
  fail(1, `Error: request to ${url} failed: ${err.message}`);
}

const bodyText = await res.text();

if (!res.ok) {
  fail(1, `Error: server returned HTTP ${res.status} ${res.statusText} from POST ${url}\n${bodyText}`);
}

// --- Report success -----------------------------------------------------------
let parsed;
try {
  parsed = JSON.parse(bodyText);
} catch {
  // Success status but non-JSON body — print raw and succeed.
  process.stdout.write(`Draft created. Server response:\n${bodyText}\n`);
  process.exit(0);
}

const pvId = parsed.processVersionId ?? parsed.id ?? '(unknown)';
const pId = parsed.processId ?? parsed.process_id ?? '(unknown)';
const stateCd = parsed.stateCd ?? parsed.state_cd ?? '(unknown)';

process.stdout.write(
  `Draft created (NOT published — publish from the designer UI).\n` +
  `  processVersionId: ${pvId}\n` +
  `  processId:        ${pId}\n` +
  `  stateCd:          ${stateCd}\n`
);
process.exit(0);
