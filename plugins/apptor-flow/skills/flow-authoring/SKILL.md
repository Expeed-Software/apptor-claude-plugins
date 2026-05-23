---
name: flow-authoring
description: >-
  Author an Apptor Flow workflow as flow JSON (and optionally create it as a
  draft via REST). Use when the user asks to "create a workflow/flow", "build an
  apptor-flow flow", "author flow JSON", or "make a flow that …". Produces parser-
  valid flow JSON using the live node schema, validated through the real JSON
  parser harness; creates DRAFTS only — a human publishes in the designer UI.
---

# Flow Authoring

Author Apptor Flow workflows as **flow JSON** that parses cleanly through the
real engine parser, then either return the JSON or create it as a **draft** via
REST. Never publish — publishing is a human action in the designer UI.

## References (read these while authoring)

- `references/grammar.md` — the structural grammar the schema doesn't carry:
  top-level process object, node object, property placement (properties[] vs
  node top-level), the link object, connection-type semantics, variable syntax,
  positioning.
- `references/examples.md` — six redacted, harness-validated templates (linear
  REST, ifElse+setVariable, aiTask+tool, split/join, setVariable, waitNode).
- The **live node vocabulary** (authoritative, v3): `GET /api/metadata/node-types`.
  This is the single source of truth for which nodes exist and their
  properties / valid outbound connections / outputs. Always reconcile node and
  property names against it.

## Hard rules (never violate)

1. **Never write `process_version.process_text` directly in the DB.** Flow
   definitions are cached by the engine; a direct DB write has no effect until
   restart. Go through the REST endpoint (this skill's script) or the UI.
2. **`{var}` in node properties; `${juel}` only in conditions.** Using `${var}`
   in a property leaves the literal text unresolved. Using bare `{var}` in a
   JUEL condition won't evaluate. Nested paths (`{a.b.c}`, `${a.b == 'x'}`) work.
3. **Every link needs `connectionType`.** The parser rejects any link missing
   it. `from`/`to` must reference existing node keys. `ifElse` uses
   `trueFlow`/`falseFlow`; a `tool` connects to its `aiTask` via `toolConnection`
   (edge goes FROM tool TO aiTask).
4. **Draft only.** This skill creates drafts (`stateCd` = draft). A human
   reviews and publishes from the designer UI. Never call any publish endpoint.
5. **Never invent connection ids / secrets.** If you can't resolve a real one,
   insert a clearly-marked placeholder and tell the user.

## Procedure

### 1. Gather intent
Understand what the flow should do end to end. Ask **targeted** questions only
for missing *critical* details — chiefly: which external provider/connection
each integration step uses (REST API, AI provider, database, email/SMS,
WhatsApp), the trigger, and the branch conditions. Don't over-interrogate;
infer node structure from the description.

### 2. Resolve connection ids
Integration steps (`serviceTask`, `aiTask`, `tool`, `waitNode`, `voiceTask`,
`domainTask`) reference connection ids. Resolve real ids before authoring:
- Query `GET /api/integrations` and `GET /api/integrations/connections`, OR
- Query the DB `integration` / `connection` tables (read-only).

Match by provider/type/name. If exactly one matches, use it. If several match,
ask the user which. **If none match, insert a clearly-labeled placeholder**
(e.g. `<REST_CONNECTION_ID>`) and explicitly tell the user it must be filled in
— **never fabricate an id.**

### 3. Author the JSON
Build the flow per `references/grammar.md` + the live node schema +
`references/examples.md`. Start from the closest template. Get node `nodeType`
values and property names from the live schema. Remember property placement:
`ifElse.condition`, split/join `mode`, scriptTask `scriptFormat`/`script`, and
`timeout`/`retry`/`loop` live at the **node top-level**, not in `properties[]`.
Generate a fresh UUID for the process `key`. Give every node a unique `key` and
reasonable `loc`.

### 4. Validate (mandatory)
Pick the strongest validation available in the current context:

**(a) Inside an `apptor-flow-server` checkout — real parser harness (strongest).**
Write the JSON to a temp file and run:
```bash
FLOW_JSON_FILE=/abs/path/flow.json ./gradlew :apptor-flow-json-parser:test \
  --tests "io.apptor.flow.json.parser.FlowJsonValidationHarness" --rerun-tasks
```
`BUILD SUCCESSFUL` = valid. If it fails, read the error (it names the offending
node/link), fix, and re-run until it passes.

**(b) Anywhere else (skill installed standalone, no apptor-flow-server repo).**
The gradle harness does not exist here. Self-validate against the schema + grammar:
every `nodeType` is in the live `/api/metadata/node-types`; every link has a
`connectionType` and `from`/`to` that resolve to a node; `{var}` vs `${juel}` used
correctly; `storageLocation:"node"` properties placed at node top-level. Then rely on
**Mode B's server-side validation** — `POST /api/processes` makes the engine parse the
definition, so a malformed flow is rejected by the API (a real check, not a guess).

Do not return or submit JSON you could not validate by at least one of these.

### 5. Deliver
- **Mode A (return JSON):** hand the validated JSON back to the user, listing
  any placeholders they must fill in. This is the default when the env vars for
  Mode B are not available.
- **Mode B (create a draft):** run the script — draft only. It authenticates via
  an **Apptor Flow API key** (`apk_…`). `POST /api/processes` accepts the key in
  the `X-API-Key` header; the server's `ApiKeyAuthenticationFilter` authenticates
  it, derives the org from the key, and authorizes the call against the key's RBAC
  role. The key's role MUST grant the `workflow.create` permission (e.g. the
  built-in "Flow Creator" role, or any custom role with `workflow.create`); a key
  lacking it gets HTTP 403. The draft is always scoped to the key's own org — there
  is no cross-org override for ordinary keys.

  ```bash
  APPTOR_FLOW_BASE_URL=http://localhost:8090 \
  APPTOR_FLOW_API_KEY=apk_xxxxx \
  node scripts/create-draft.mjs /abs/path/flow.json
  ```

  The script POSTs `{ "definition": <file contents> }` to `/api/processes` with
  the `X-API-Key` header and prints `processVersionId` / `processId` / `stateCd`.

  Env: `APPTOR_FLOW_API_KEY` is **required** (an `apk_` key whose role grants
  `workflow.create`); `APPTOR_FLOW_BASE_URL` defaults to `http://localhost:8090`.

  **If the script fails for any reason, fall back to Mode A** (return the
  validated JSON) and report the error.

After a draft is created, tell the user it is a draft and that they publish it
from the designer UI.
