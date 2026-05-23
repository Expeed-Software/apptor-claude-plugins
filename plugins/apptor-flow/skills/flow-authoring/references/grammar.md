# Apptor Flow JSON Grammar

The authoritative *node vocabulary* (which nodes exist, their properties, valid
outbound connections, outputs, per-node flags) lives in the live node schema,
fetched at runtime from:

```
GET /api/metadata/node-types        # v3, the single source of truth
```

(Backed by `apptor-mcp/src/main/resources/node-schema.json`, served by
`WorkflowMetadataController` / `WorkflowMetadataService`.)

This document covers the **structural grammar the schema does NOT carry**: the
shape of the top-level process object, where each property is physically placed
(properties array vs node top-level), the link object, connection-type
semantics, and variable syntax. All of it is verified against the real JSON
parser in `apptor-flow-json-parser` (`JSONDSLParser`, `NodeContainerParser`,
`NodeParser`, and the per-node parsers).

Validate any authored flow with the real parser before using it:

```bash
FLOW_JSON_FILE=/abs/path/flow.json ./gradlew :apptor-flow-json-parser:test \
  --tests "io.apptor.flow.json.parser.FlowJsonValidationHarness" --rerun-tasks
```

---

## 1. Top-level process object

```jsonc
{
  "key": "<uuid>",                 // process UUID (a new GUID for a brand-new flow)
  "nodeType": "process",           // MUST be exactly "process" (root container)
  "inputs": [],                    // optional flow-level inputs: [{ "key": "...", "value": "..." }]
  "outputs": [],                   // optional flow-level outputs (same shape)
  "properties": [                  // flow metadata, as key/value pairs
    { "key": "name",            "value": "My Flow" },
    { "key": "description",     "value": "what it does" },
    { "key": "flowType",        "value": "WORKFLOW" },
    { "key": "executionMethod", "value": "start" },
    { "key": "version",         "value": 1 },
    { "key": "layoutDirection", "value": "LR" }
  ],
  "nodes": [ /* node objects, see §2 */ ],
  "links": [ /* link objects, see §3 */ ]
}
```

Parser-enforced rules (`NodeContainerParser.parse`):
- `nodeType` must resolve to `PROCESS` (value `"process"`) for the root.
- `nodes` array is **required** (missing → `"Nodes array is required in the container!"`).
- `links` array is **required** — the connections key is literally `"links"`
  (`ATTRIBUTE_CONNECTIONS = "links"`). An empty `[]` is allowed; a missing key throws.
- `name`/`description` may also appear as top-level fields on the process object
  (both forms are seen in real flows); the `properties[]` entries above are the
  portable form. Include `name` either way.

`flowType` is `WORKFLOW` for normal flows. `layoutDirection` `"LR"` lays the
diagram left-to-right (matches the positioning guidance in §6).

A `subProcess` node is itself a container with the same `nodes`/`links` shape
(parsed by the same `NodeContainerParser`).

---

## 2. Node object

```jsonc
{
  "key": "node_1",            // REQUIRED, unique within the container (this is the node id)
  "nodeType": "serviceTask",  // REQUIRED, must map to a known NodeType (see live schema)
  "name": "Human label",      // optional but recommended
  "loc": "260 0",             // "x y" canvas position (string, space-separated)
  "properties": [             // most config goes here, as { key, value } pairs
    { "key": "taskType", "value": "rest" }
  ]
}
```

- `key` is the node id used by links' `from`/`to`. Must be unique; duplicate
  ids or links referencing a missing id are rejected by the parser.
- Every entry in `properties[]` is read generically as an input variable
  (`NodeParser.parseProperties`). The parser does **not** validate property names
  against the schema — a misspelled property is silently ignored at parse time
  and simply has no effect at run time. Use the live schema to get names right.
- An optional `type` hint on a property converts the value
  (`"boolean"`→Boolean, `"integer"`→Integer, `"number"`→Double); otherwise the
  value stays a string/object.

### Property placement: properties[] vs node top-level

Most properties live inside `properties[]`. **Some are read from the node
top-level instead** — the live schema marks these with
`storageLocation: "node"`. The parser reads them directly off the node object,
NOT from `properties[]`:

| nodeType            | top-level field(s)                          | shape |
|---------------------|---------------------------------------------|-------|
| `ifElse`            | `condition`                                 | `{ "expression": "${...}", "language": "juel" }` |
| `split` / `join`    | `mode`                                       | `"exclusive"` \| `"inclusive"` \| `"parallel"` |
| `scriptTask`        | `scriptFormat`, `script`                     | `scriptFormat`: `"javascript"`/`"python"`; `script`: source string |
| any node            | `timeout`, `retry`, `loop`                   | framework-level, see §5 |

Real flows commonly mirror these into `properties[]` **as well** (the designer
emits both), e.g. a `split` carries `"mode":"inclusive"` at top-level *and*
`{ "key": "mode", "value": "inclusive" }` in `properties[]`. Mirroring is
harmless. What is **load-bearing** is the top-level field — that is the one the
parser reads:
- `IfElseNodeParser` reads `node.condition.expression` (a top-level `condition`
  object is **required**; missing → parse error).
- `GatewayParser` reads top-level `mode` to choose exclusive/inclusive/parallel.
- `LoopNodeParser` / framework reads top-level `loop`.

When in doubt, set the top-level field; mirror into `properties[]` for designer
fidelity.

### setVariable — `mappings`

`setVariable` carries one property whose key is `mappings`. Its `value` is a
**JSON string** encoding an array of mapping objects (the parser,
`SetVariableParser.parseMappings`, accepts a JSON string *or* a real array; the
JSON-string form is what the designer persists and what these templates use):

```jsonc
{
  "key": "setvar_1",
  "nodeType": "setVariable",
  "name": "Map Order Data",
  "properties": [
    {
      "key": "mappings",
      "value": "[{\"variable\":\"orderId\",\"value\":\"{webhookPayload.order.id}\",\"type\":\"string\"}]"
    }
  ]
}
```

Each mapping object: `variable` (target name, required), `value` (literal or
`{var}` expression), and optional `type` (`string`/`number`/`boolean`/`auto`;
defaults to `auto`). Note the field is `variable`, **not** `target` or `name`.

---

## 3. Link object

```jsonc
{
  "from": "node_1",                  // REQUIRED — source node key
  "to": "node_3",                    // REQUIRED — target node key
  "connectionType": "sequenceFlow",  // REQUIRED — see §4
  "routing": "node_1_to_node_3",     // string id; make it unique per link
  "condition": {                     // optional (used on gateway/branch outputs)
    "expression": "${priority == 'high'}",
    "language": "juel"
  }
}
```

Parser-enforced rules (`NodeContainerParser.parseConnections`):
- `from`, `to`, `connectionType` are all **required** — any missing throws.
- `from` and `to` must reference existing node keys, or the parser throws
  (`"From/To node with id X not found in container!"`).
- `connectionType` must be one of the supported types (§4) or the parser throws
  `"Connection type X is not supported."`.
- `routing` is a free-form string id. It is NOT unique by itself in older flows;
  always make it unique (e.g. `"{from}_to_{to}"`) to avoid map-key collisions.
- `condition` is optional; when present, `expression` is required and `language`
  defaults to `"juel"`. Use it on gateway split outputs and any conditional edge.
  (`ifElse` does NOT need link conditions — it routes by `trueFlow`/`falseFlow`
  using the node's own top-level `condition`.)

---

## 4. Connection-type semantics

Supported `connectionType` values (the 6 sequence-style + the tool edge):

| connectionType   | label (registry `connectionTypeLabels`) | meaning |
|------------------|-----------------------------------------|---------|
| `sequenceFlow`   | Default  | normal next-step edge |
| `successFlow`    | Success  | taken when the source step succeeds |
| `errorFlow`      | Error    | taken when the source step fails |
| `timeoutFlow`    | Timeout  | taken when the source step times out |
| `trueFlow`       | True     | `ifElse` branch when condition is true |
| `falseFlow`      | False    | `ifElse` branch when condition is false |
| `toolConnection` | Tool     | wires a `tool` node into an `aiTask` |

Which nodes emit which (from each node's `validOutboundConnections` in the live
schema):

- **`startEvent`** → `sequenceFlow` only.
- **`endEvent`** → nothing (terminal).
- **Task/handler nodes** (`serviceTask`, `aiTask`, `voiceTask`, `scriptTask`,
  `loopNode`, …) → `sequenceFlow`, `successFlow`, `errorFlow`, `timeoutFlow`.
  Use `successFlow` for the happy path and optional `errorFlow`/`timeoutFlow`
  for failure handling. (`successFlow` is the common happy-path choice in real
  flows; `sequenceFlow` also works for an unconditional next step.)
- **`ifElse`** → `trueFlow` and `falseFlow` (exactly these two). No `sequenceFlow`.
- **`setVariable`, `split`, `join`** → `sequenceFlow` only. Branch logic on a
  `split` lives in each outbound link's `condition`.
- **`tool`** → `toolConnection` only, and it must point **FROM the tool node TO
  an `aiTask` node**. The parser verifies the source is a `Tool` and the target
  is an `AiTask`, then registers the tool on the AI task (it does not create a
  normal edge). Wrong source/target types throw.

A tool node has no normal outgoing edge and is not on the main sequence — it
just attaches to its AI task via `toolConnection`.

---

## 5. Framework-level node config (timeout / retry / loop)

These are read for **every** node from the node top-level (not `properties[]`):

```jsonc
"timeout": { "duration": 30, "uom": "SECONDS", "action": "CANCEL" }
"retry":   { "maxAttempts": 3, "delay": 5, "uom": "SECONDS" }
"loop":    { "type": "standard", "maxIterations": 10,
             "condition": { "expression": "${status != 'done'}", "language": "juel" } }
```

Parser field names (verified in `NodeParser`):
- timeout reads `duration`, `uom`, `action` (note: `uom`, not `durationUom`).
- retry reads `maxAttempts`, `delay`, `uom` (all required if `retry` present).
- loop `type` is `"standard"` (uses `maxIterations` + optional `condition`) or
  `"collection"` (requires `inputCollection` + `inputDataItem`).

Only include these blocks when you actually want the behavior; otherwise omit.

---

## 6. Variable syntax (CRITICAL)

| Context | Syntax | Example |
|---------|--------|---------|
| Any node property (prompt, body, subject, endpointPath, value fields, …) | `{var}` | `Hello {customerName}` / `/users/{userId}` |
| JUEL condition expressions (`ifElse.condition`, `split` link `condition`, `loop.condition`) | `${...}` | `${status == 'approved'}` |

- Nested paths work in both: `{webhookPayload.order.id}`, `${result.status == 'ok'}`.
- String interpolation works in properties: `Order {orderId} — Total: {orderTotal}`.
- **NEVER use `${var}` inside a node property.** The `$` is not needed there and
  the variable will NOT resolve — the literal `${var}` text appears in output.
- **NEVER use bare `{var}` inside a JUEL condition.** Conditions need `${...}`.

---

## 7. Positioning (`loc`)

`loc` is a `"x y"` string. Conventions that keep the diagram readable:
- Start node at or near `"0 0"`.
- ~250–300 px horizontal between sequential nodes (left-to-right with `"LR"`).
- ±70 px vertical offset for parallel branches (e.g. true branch at `y = -70`,
  false branch at `y = +70`); tool nodes sit just below their AI task.

Positioning has no effect on execution — it only affects the designer layout —
but good `loc` values make a returned flow pleasant to open in the UI.
