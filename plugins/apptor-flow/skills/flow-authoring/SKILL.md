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
- The **live node vocabulary** — the single source of truth for which nodes
  exist and their properties / valid outbound connections / outputs:
  `GET {baseUrl}/api/metadata/node-types`, read with the **same `apk_` API key**
  (header `X-API-Key`). `{baseUrl}` is per environment/tenant — **no hardcoded
  default; ask the user.** Always reconcile node and property names against it,
  and re-read it rather than trusting these docs (which can lag the schema).

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
5. **Never invent integration/connection/version ids or secrets, and never put an
   integration id into a `…ConnectionId` field.** Resolve them via the live API
   (Procedure step 2): ask the user to choose when several exist, use the one when
   exactly one exists, and ask "build without a connection (link later) or stop?"
   when none exist. An integration step also needs its **mandatory** version id
   (`<prefix>IntegrationVersionId` = the integration's `currentVersionId`).
6. **No schema → STOP. Do not guess.** The node vocabulary (which nodes exist,
   their properties, when to use each) comes ONLY from the live schema. If you
   cannot read `GET /api/metadata/node-types` (no base URL, no key, server
   unreachable, or 401), **do not author a flow** — stop and ask the user for the
   base URL + an `apk_` API key. Producing a flow without the real schema yields
   dead, unusable output; refusing is correct.
7. **Pick nodes from the schema's own descriptions — never hardcode "if user
   says X use node Y".** Each node in the schema carries a `description` +
   `useCases` stating when to use it. Match the user's intent against those. In
   particular: when the flow needs **data entered by the user**, the schema's
   `inputNode` says *"Use this whenever the flow needs data FROM the user"* — use
   it (set `inputType` + `variableName`; reference the value later as
   `{variableName}`). **For multiple values in a single user interaction, use
   ONE `inputNode` with `inputType: "form"` and a `formFields` array** — NOT
   two or more sequential `inputNode` steps (which pause the flow twice).
8. **Property entries in flow JSON use `key`, NOT `name`. This is the #1 trap.**
   The schema *defines* a property as `{"name":"inputType","label":...}` — that
   `name` is the property's identifier. But in the **flow JSON** that the parser
   reads, every entry in a node's `properties[]` array is a `{key, value}` pair
   where `key` is the schema's `name` value. The parser reads `property.get("key")`;
   if the entry is named `name`, the parser **silently ignores the whole property**
   and the field reaches the runtime as null — a flow that looks valid but is
   dead. Always emit:
   ```jsonc
   // RIGHT — parser reads this:
   "properties": [
     { "key": "inputType",    "value": "textbox" },
     { "key": "variableName", "value": "topic" }
   ]
   // WRONG — silently dropped at parse time, flow won't run:
   "properties": [
     { "name": "inputType",    "value": "textbox" },
     { "name": "variableName", "value": "topic" }
   ]
   ```
   The script's lint will reject/auto-rewrite `{name,value}` entries, but emit
   the right shape from the start.

## Procedure

### 0. Read the live schema FIRST (mandatory — fail loud if you can't)
Before anything else, get the base URL + an `apk_` API key from the user (the URL
is per-environment/tenant — there is NO default; ask). Then fetch the live node
schema:
```
GET {baseUrl}/api/metadata/node-types     # header: X-API-Key: apk_...
```
If you cannot reach it (no URL/key, server down, 401), **STOP per hard rule 6** —
tell the user exactly what you need and do not author anything. Everything below
depends on knowing the real nodes.

### 1. Gather intent + PROPOSE and CONFIRM (interactive — do not silently build)
Understand what the flow should do end to end. Ask **targeted** questions only
for missing *critical* details — chiefly: where the user/data enters (a person
typing into a form → `inputNode`; a webhook/API; a channel), which
provider/connection each integration step uses, and any branch conditions.

Then **propose the flow back to the user and wait for confirmation before
authoring** — e.g.:
> "Here's what I'll build: **start → inputNode (collect `topic`) → aiTask (write
> a joke about `{topic}`) → outputNode (show the joke) → end**. The aiTask needs
> an AI connection — which one? Confirm and I'll generate it."

Only author after they confirm. Map each requirement to a node by reading that
node's `description`/`useCases` in the schema (hard rule 7) — never a hardcoded
keyword→node mapping.

### 2. Resolve integrations + connections (ask only when ambiguous or absent)
Integration steps (`serviceTask`, `aiTask`, `tool`, `waitNode`, `voiceTask`,
`domainTask`, `whatsappConversation`, …) need **TWO** node properties per
integration, NOT one — get the exact names from the schema / `IntegrationType`
(e.g. AI_PROVIDER → `aiProviderConnectionId` + `aiProviderIntegrationVersionId`):
- `<prefix>IntegrationVersionId` — **MANDATORY.** Without it the runtime resolves
  no provider and the step silently does nothing (a dead flow that looks valid).
- `<prefix>ConnectionId` — the specific credentialed connection (or leave unset
  to use the integration's default connection).

Resolve both from the live API only (never the DB, never invented):

**(a) Pick the integration.** `GET {baseUrl}/api/integrations` (header
`X-API-Key`) → filter by the needed `type` (e.g. `AI_PROVIDER`, `REST_API`):
- several of that type → **ASK the user which**, showing `name` + `type`;
- exactly one → use it;
- none → you cannot build this step → tell the user.

**(b) Set the version id.** `GET {baseUrl}/api/integrations/{integrationId}` →
use its `currentVersionId` as `<prefix>IntegrationVersionId`. (NEVER guess it.)

**(c) Pick the connection.** `GET {baseUrl}/api/integrations/{integrationId}/connections`:
- several → **ASK the user which**, showing integration name + connection name;
- exactly one → use it as `<prefix>ConnectionId`;
- **none → ASK the user**: "create the flow **without a connection** (link one
  later in the designer) or **stop**?" If they proceed, leave `<prefix>ConnectionId`
  unset and **tell them plainly the flow will NOT run until a connection is linked.**

**Never** fabricate an integration id, connection id, or version id; **never** put
an integration id into the `…ConnectionId` field; the value MUST come from these
API calls.

### 3. Author the JSON
Build the flow per `references/grammar.md` + the live node schema +
`references/examples.md`. Start from the closest template. Get node `nodeType`
values and property names from the live schema. Remember property placement:
`ifElse.condition`, split/join `mode`, scriptTask `scriptFormat`/`script`, and
`timeout`/`retry`/`loop` live at the **node top-level**, not in `properties[]`.
Generate a fresh UUID for the process `key`. Give every node a unique `key` and
`loc` with **at least 280 px between sequential nodes horizontally** (and ±70–120
vertical offset for branches) — tighter spacing produces a cramped, unreadable
diagram. Use the `{ "key": ..., "value": ... }` property shape per hard rule 8,
never `{"name", "value"}`.

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

**First, ASK the user which delivery mode they want** — do not silently choose:
> "How should I deliver this flow? **(A)** return the validated JSON for you to
> import/publish in the designer, or **(B)** create it directly as a draft via
> REST (needs an `apk_` API key with `workflow.create`)?"

Respect their answer. Only fall back to Mode A without asking if creating a draft
is clearly impossible (no API key available) AND the user has expressed no
preference — and say so explicitly.

- **Mode A (return JSON):** hand the validated JSON back to the user, listing
  any placeholders they must fill in.
- **Mode B (create a draft):** run the script — draft only. It authenticates via
  an **Apptor Flow API key** (`apk_…`). `POST /api/processes` accepts the key in
  the `X-API-Key` header; the server's `ApiKeyAuthenticationFilter` authenticates
  it, derives the org from the key, and authorizes the call against the key's RBAC
  role. The key's role MUST grant the `workflow.create` permission (e.g. the
  built-in "Flow Creator" role, or any custom role with `workflow.create`); a key
  lacking it gets HTTP 403. The draft is always scoped to the key's own org — there
  is no cross-org override for ordinary keys.

  ```bash
  APPTOR_FLOW_BASE_URL=<the user's environment URL> \
  APPTOR_FLOW_API_KEY=apk_xxxxx \
  node scripts/create-draft.mjs /abs/path/flow.json
  ```

  The script POSTs `{ "definition": <file contents> }` to `/api/processes` with
  the `X-API-Key` header and prints `processVersionId` / `processId` / `stateCd`.

  Env: BOTH are **required, with no defaults** — `APPTOR_FLOW_API_KEY` (an `apk_`
  key whose role grants `workflow.create`) and `APPTOR_FLOW_BASE_URL` (the
  tenant/environment URL — it differs per deployment, e.g. `http://localhost:8080`
  in local dev; **ask the user, never assume**). The same key + URL are what you
  used to read the schema in step 0.

  **If the script fails for any reason, fall back to Mode A** (return the
  validated JSON) and report the error.

After a draft is created, tell the user it is a draft and that they publish it
from the designer UI.
