# apptor-flow

Claude Code plugin for authoring [Apptor Flow](https://apptor.io) workflows.

## What it does

Given a natural-language description ("build a flow that takes a webhook, classifies it with AI, and emails the result"), the `flow-authoring` skill:

1. **Gathers intent** — asks only for genuinely missing details (which provider/connection, etc.).
2. **Resolves connection IDs** from your environment (`/api/integrations`), or inserts a clearly-marked placeholder — it never invents IDs.
3. **Authors flow JSON** using the **live node schema** (`/api/metadata/node-types`, the single source of truth) plus the flow grammar and validated templates bundled in the skill.
4. **Validates** the result.
5. Either **returns the JSON** for you to import in the designer, or **creates it as a draft** via the REST API.

## Two output modes

| Mode | What you get | Setup |
|------|--------------|-------|
| **A — emit JSON** | Validated `process_text` to import in the designer, then publish | none |
| **B — create draft** | A **draft** flow created via `POST /api/processes` (you publish in the UI) | env vars below |

### Mode B configuration
- `APPTOR_FLOW_BASE_URL` — flow-server base URL (default `http://localhost:8090`)
- `APPTOR_FLOW_API_KEY` — an `apk_…` API key whose role includes **`workflow.create`**

Drafts are created **scoped to the key's organization**. The skill never publishes — a human publishes in the designer.

## Validation

- **Inside an `apptor-flow-server` checkout**, the skill validates authored JSON through the real parser harness (`./gradlew :apptor-flow-json-parser:test --tests "…FlowJsonValidationHarness"`).
- **Anywhere else**, it self-validates against the schema + grammar; Mode B additionally gets **real server-side validation** — the engine parses the definition on create, so a malformed flow is rejected by the API.

## Scope & limits

- Authors any combination of the **node types in the live schema** (start/end, serviceTask REST/SQL/email/SMS/WhatsApp, aiTask, voiceTask, scriptTask, setVariable, ifElse, split/join, loop, tool, input/output, domainTask, waitNode, callProcess, callAgent, memory, knowledge/distill, subProcess, userTask).
- Guarantees **structural** validity (parses, links wired, correct variable syntax) — not business-logic correctness; review complex flows.
- **JSON dialect only** (not BPMN). Drafts only.

## Install

```
/plugin marketplace add https://github.com/expeedsoftware/apptor-claude-plugins
/plugin install apptor-flow
```

## About

Built and maintained by [Expeed Software](https://expeed.com).
