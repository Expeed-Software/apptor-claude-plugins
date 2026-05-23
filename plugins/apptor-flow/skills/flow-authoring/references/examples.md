# Validated Flow Templates

Each template below was derived from a **real flow** in the local
`apptor_flow_db` (`process_version` table), redacted to remove all secrets /
connection ids / phone numbers / emails, and **validated through the real
parser harness**:

```bash
FLOW_JSON_FILE=/abs/path/flow.json ./gradlew :apptor-flow-json-parser:test \
  --tests "io.apptor.flow.json.parser.FlowJsonValidationHarness" --rerun-tasks
```

All six templates below produced `BUILD SUCCESSFUL`. The `source pv` column is
the `process_version_id` each was derived from.

| Pattern | source pv | Harness |
|---------|-----------|---------|
| Linear REST serviceTask        | 131 | PASS |
| ifElse + setVariable           | 66  | PASS |
| aiTask + tool (toolConnection) | 74  | PASS |
| split / join (parallel branches) | 157 | PASS |
| setVariable (mappings-as-JSON-string) | derived from 66's contract | PASS |
| waitNode                       | 100 | PASS |

**Before using any template:** replace every `<PLACEHOLDER>` and
`REPLACE_WITH_UUID`. Resolve real connection ids from `/api/integrations` and
`/api/integrations/connections` — never invent an id.

---

## 1. Linear REST serviceTask  (source pv 131)

Start → REST `serviceTask` → End. The happy path uses `successFlow`.

Placeholders: `REPLACE_WITH_UUID`, `<REST_CONNECTION_ID>`.

```json
{
  "key": "REPLACE_WITH_UUID",
  "nodeType": "process",
  "inputs": [],
  "properties": [
    { "key": "name", "value": "Linear REST Call" },
    { "key": "description", "value": "Start -> REST serviceTask -> End" },
    { "key": "flowType", "value": "WORKFLOW" },
    { "key": "executionMethod", "value": "start" },
    { "key": "version", "value": 1 },
    { "key": "layoutDirection", "value": "LR" }
  ],
  "nodes": [
    { "key": "start_1", "nodeType": "startEvent", "name": "Start", "properties": [], "loc": "0 0" },
    {
      "key": "rest_1",
      "nodeType": "serviceTask",
      "name": "Call Shipments API",
      "properties": [
        { "key": "taskType", "value": "rest" },
        { "key": "restApiConnectionId", "value": "<REST_CONNECTION_ID>" },
        { "key": "endpointPath", "value": "/shipments/{shipmentId}" },
        { "key": "method", "value": "POST" },
        { "key": "body", "value": "{\"status\":\"shipped\",\"trackingId\":\"{trackingId}\"}" }
      ],
      "loc": "260 0"
    },
    { "key": "end_1", "nodeType": "endEvent", "name": "End", "properties": [], "loc": "560 0" }
  ],
  "links": [
    { "from": "start_1", "to": "rest_1", "connectionType": "sequenceFlow", "routing": "start_1_to_rest_1" },
    { "from": "rest_1", "to": "end_1", "connectionType": "successFlow", "routing": "rest_1_to_end_1" }
  ]
}
```

Notes: REST response body lands in `{result}` (access fields as `{result.x}`).
For SQL/email/sms swap `taskType` and the matching connection property
(`databaseConnectionId` / `mailConnectionId` / `smsConnectionId`) per the live
schema's `serviceTask` subtypes.

---

## 2. ifElse + setVariable  (source pv 66)

`setVariable` seeds a value, `ifElse` routes by a JUEL condition to two
`outputNode`s. Note the `condition` is a **top-level** field on the ifElse node,
and the branches use `trueFlow` / `falseFlow`.

Placeholders: `REPLACE_WITH_UUID`.

```json
{
  "key": "REPLACE_WITH_UUID",
  "nodeType": "process",
  "name": "Customer Score Router",
  "description": "setVariable -> ifElse branches to two outputNodes",
  "properties": [
    { "key": "name", "value": "Customer Score Router" },
    { "key": "flowType", "value": "WORKFLOW" },
    { "key": "executionMethod", "value": "start" },
    { "key": "version", "value": 1 },
    { "key": "layoutDirection", "value": "LR" }
  ],
  "nodes": [
    { "key": "start_1", "nodeType": "startEvent", "name": "Start", "loc": "0 0" },
    {
      "key": "setvar_1",
      "nodeType": "setVariable",
      "name": "Set Credit Score",
      "properties": [
        { "key": "mappings", "value": "[{\"variable\":\"creditScore\",\"value\":\"750\",\"type\":\"number\"}]" }
      ],
      "loc": "250 0"
    },
    {
      "key": "ifelse_1",
      "nodeType": "ifElse",
      "name": "Score >= 700?",
      "condition": { "expression": "${creditScore >= 700}", "language": "juel" },
      "loc": "500 0"
    },
    {
      "key": "out_approve",
      "nodeType": "outputNode",
      "name": "Approved",
      "properties": [
        { "key": "outputType", "value": "success" },
        { "key": "prompt", "value": "Credit application APPROVED. Score: {creditScore}" }
      ],
      "loc": "750 -70"
    },
    {
      "key": "out_review",
      "nodeType": "outputNode",
      "name": "Manual Review",
      "properties": [
        { "key": "outputType", "value": "warning" },
        { "key": "prompt", "value": "Score {creditScore} is below threshold. Sent to manual review." }
      ],
      "loc": "750 70"
    },
    { "key": "end_1", "nodeType": "endEvent", "name": "End", "loc": "1050 0" }
  ],
  "links": [
    { "from": "start_1", "to": "setvar_1", "connectionType": "sequenceFlow", "routing": "start_1_to_setvar_1" },
    { "from": "setvar_1", "to": "ifelse_1", "connectionType": "sequenceFlow", "routing": "setvar_1_to_ifelse_1" },
    { "from": "ifelse_1", "to": "out_approve", "connectionType": "trueFlow", "routing": "ifelse_1_to_out_approve" },
    { "from": "ifelse_1", "to": "out_review", "connectionType": "falseFlow", "routing": "ifelse_1_to_out_review" },
    { "from": "out_approve", "to": "end_1", "connectionType": "sequenceFlow", "routing": "out_approve_to_end_1" },
    { "from": "out_review", "to": "end_1", "connectionType": "sequenceFlow", "routing": "out_review_to_end_1" }
  ]
}
```

---

## 3. aiTask + tool  (source pv 74)

An `aiTask` with a `tool` node wired in via `toolConnection`. The tool edge goes
**FROM the tool node TO the aiTask** — the tool is not on the main sequence.

Placeholders: `REPLACE_WITH_UUID`, `<AI_PROVIDER_CONNECTION_ID>`,
`<WEB_SEARCH_API_KEY>`.

```json
{
  "key": "REPLACE_WITH_UUID",
  "nodeType": "process",
  "name": "AI Agent with Tool",
  "description": "aiTask with a tool wired in via toolConnection (Tool -> AiTask)",
  "properties": [
    { "key": "name", "value": "AI Agent with Tool" },
    { "key": "flowType", "value": "WORKFLOW" },
    { "key": "executionMethod", "value": "start" },
    { "key": "version", "value": 1 },
    { "key": "layoutDirection", "value": "LR" }
  ],
  "nodes": [
    { "key": "start_1", "nodeType": "startEvent", "name": "Start", "loc": "0 0" },
    {
      "key": "ai_1",
      "nodeType": "aiTask",
      "name": "Research Agent",
      "properties": [
        { "key": "aiProviderConnectionId", "value": "<AI_PROVIDER_CONNECTION_ID>" },
        { "key": "systemPrompt", "value": "You are a research assistant. Use the available tools when helpful." },
        { "key": "prompt", "value": "Research the topic: {topic}" }
      ],
      "loc": "260 0"
    },
    {
      "key": "tool_1",
      "nodeType": "tool",
      "name": "Web Search",
      "properties": [
        { "key": "source", "value": "web_search" },
        { "key": "provider", "value": "google" },
        { "key": "apiKey", "value": "<WEB_SEARCH_API_KEY>" }
      ],
      "loc": "260 160"
    },
    { "key": "end_1", "nodeType": "endEvent", "name": "End", "loc": "560 0" }
  ],
  "links": [
    { "from": "start_1", "to": "ai_1", "connectionType": "sequenceFlow", "routing": "start_1_to_ai_1" },
    { "from": "tool_1", "to": "ai_1", "connectionType": "toolConnection", "routing": "tool_1_to_ai_1" },
    { "from": "ai_1", "to": "end_1", "connectionType": "sequenceFlow", "routing": "ai_1_to_end_1" }
  ]
}
```

Notes: AI answer lands in `{result}`. Other tool `source` values (e.g.
`knowledge_base`, `mcp`, `rest`, `email`, `sql`, `file_manager`) carry different
properties — consult the live schema's `tool` subtypes. Prefer a real
connection (`aiProviderConnectionId`) over `provider`/`model` overrides.

---

## 4. split / join  (source pv 157)

Inclusive `split` fans out to two `scriptTask` branches, each guarded by a link
`condition`; a `join` fans them back in. `mode` is a **top-level** field on the
split/join nodes (mirrored into `properties[]` for designer fidelity).
`scriptTask` stores `scriptFormat`/`script` at the **node top-level**.

Placeholders: `REPLACE_WITH_UUID`.

```json
{
  "key": "REPLACE_WITH_UUID",
  "nodeType": "process",
  "inputs": [],
  "properties": [
    { "key": "name", "value": "Inclusive Split Join" },
    { "key": "flowType", "value": "WORKFLOW" },
    { "key": "executionMethod", "value": "start" },
    { "key": "version", "value": 1 },
    { "key": "layoutDirection", "value": "LR" }
  ],
  "nodes": [
    { "key": "start_1", "nodeType": "startEvent", "name": "Start", "properties": [], "loc": "0 0" },
    {
      "key": "script_seed",
      "nodeType": "scriptTask",
      "name": "Set Variables",
      "scriptFormat": "javascript",
      "script": "function process(context) {\n  context.setVariable('priority', 'high');\n  context.setVariable('category', 'urgent');\n}",
      "properties": [],
      "loc": "200 0"
    },
    {
      "key": "split_1",
      "nodeType": "split",
      "name": "Split Paths",
      "mode": "inclusive",
      "properties": [ { "key": "mode", "value": "inclusive" } ],
      "loc": "420 0"
    },
    {
      "key": "script_a",
      "nodeType": "scriptTask",
      "name": "Path A Handler",
      "scriptFormat": "javascript",
      "script": "function process(context) {\n  context.setVariable('pathA_result', 'done');\n}",
      "properties": [],
      "loc": "640 -90"
    },
    {
      "key": "script_b",
      "nodeType": "scriptTask",
      "name": "Path B Handler",
      "scriptFormat": "javascript",
      "script": "function process(context) {\n  context.setVariable('pathB_result', 'done');\n}",
      "properties": [],
      "loc": "640 90"
    },
    {
      "key": "join_1",
      "nodeType": "join",
      "name": "Join Paths",
      "mode": "inclusive",
      "properties": [ { "key": "mode", "value": "inclusive" } ],
      "loc": "860 0"
    },
    { "key": "end_1", "nodeType": "endEvent", "name": "End", "properties": [], "loc": "1080 0" }
  ],
  "links": [
    { "from": "start_1", "to": "script_seed", "connectionType": "sequenceFlow", "routing": "start_1_to_script_seed" },
    { "from": "script_seed", "to": "split_1", "connectionType": "successFlow", "routing": "script_seed_to_split_1" },
    { "from": "split_1", "to": "script_a", "connectionType": "sequenceFlow", "condition": { "expression": "${priority == 'high'}", "language": "juel" }, "routing": "split_1_to_script_a" },
    { "from": "split_1", "to": "script_b", "connectionType": "sequenceFlow", "condition": { "expression": "${category == 'urgent'}", "language": "juel" }, "routing": "split_1_to_script_b" },
    { "from": "script_a", "to": "join_1", "connectionType": "successFlow", "routing": "script_a_to_join_1" },
    { "from": "script_b", "to": "join_1", "connectionType": "successFlow", "routing": "script_b_to_join_1" },
    { "from": "join_1", "to": "end_1", "connectionType": "sequenceFlow", "routing": "join_1_to_end_1" }
  ]
}
```

Notes: use `mode` `"parallel"` to take all branches unconditionally (drop the
link conditions), `"exclusive"` for choose-one. Keep split `mode` and join
`mode` consistent.

---

## 5. setVariable — mappings as a JSON string

A standalone `setVariable` whose `mappings` property `value` is a **JSON
string** (escaped). Each mapping has `variable` / `value` / optional `type`.
Values can interpolate other variables and nested paths.

Placeholders: `REPLACE_WITH_UUID`.

```json
{
  "key": "REPLACE_WITH_UUID",
  "nodeType": "process",
  "inputs": [],
  "properties": [
    { "key": "name", "value": "Set Variable Mappings" },
    { "key": "description", "value": "setVariable with mappings serialized as a JSON string" },
    { "key": "flowType", "value": "WORKFLOW" },
    { "key": "executionMethod", "value": "start" },
    { "key": "version", "value": 1 },
    { "key": "layoutDirection", "value": "LR" }
  ],
  "nodes": [
    { "key": "start_1", "nodeType": "startEvent", "name": "Start", "properties": [], "loc": "0 0" },
    {
      "key": "setvar_1",
      "nodeType": "setVariable",
      "name": "Map Order Data",
      "properties": [
        { "key": "mappings", "value": "[{\"variable\":\"orderId\",\"value\":\"{webhookPayload.order.id}\",\"type\":\"string\"},{\"variable\":\"orderTotal\",\"value\":\"{webhookPayload.order.total}\",\"type\":\"number\"},{\"variable\":\"orderSummary\",\"value\":\"Order {orderId} total {orderTotal}\",\"type\":\"string\"}]" }
      ],
      "loc": "260 0"
    },
    { "key": "end_1", "nodeType": "endEvent", "name": "End", "properties": [], "loc": "560 0" }
  ],
  "links": [
    { "from": "start_1", "to": "setvar_1", "connectionType": "sequenceFlow", "routing": "start_1_to_setvar_1" },
    { "from": "setvar_1", "to": "end_1", "connectionType": "sequenceFlow", "routing": "setvar_1_to_end_1" }
  ]
}
```

> The mapping field name is `variable` (not `target`). Some older real flows used
> a non-standard `variables` property with `name`/`value` pairs — that form is
> **not** read by `SetVariableParser` (which only consumes the `mappings`
> property). Always use `mappings` with `variable`.

---

## 6. waitNode  (source pv 100)

Pause the flow until a reply arrives on a channel (here WhatsApp). The source
flow had no links (the node was unconnected on the canvas); this redacted
version wires Start → wait → End so it is a usable template.

Placeholders: `REPLACE_WITH_UUID`, `<WHATSAPP_CONNECTION_ID>`.

```json
{
  "key": "REPLACE_WITH_UUID",
  "nodeType": "process",
  "inputs": [],
  "properties": [
    { "key": "name", "value": "WhatsApp Wait" },
    { "key": "description", "value": "Pause for a WhatsApp reply via a waitNode" },
    { "key": "flowType", "value": "WORKFLOW" },
    { "key": "executionMethod", "value": "start" },
    { "key": "version", "value": 1 },
    { "key": "layoutDirection", "value": "LR" }
  ],
  "nodes": [
    { "key": "start_1", "nodeType": "startEvent", "name": "Start", "properties": [], "loc": "0 0" },
    {
      "key": "wait_1",
      "nodeType": "waitNode",
      "name": "Wait For Reply",
      "properties": [
        { "key": "channelType", "value": "whatsapp" },
        { "key": "sendBeforePause", "value": "false" },
        { "key": "waitTimeoutAction", "value": "fail" },
        { "key": "whatsappConnectionId", "value": "<WHATSAPP_CONNECTION_ID>" },
        { "key": "interactiveType", "value": "none" },
        { "key": "listButtonText", "value": "Select an option" }
      ],
      "loc": "260 0"
    },
    { "key": "end_1", "nodeType": "endEvent", "name": "End", "properties": [], "loc": "560 0" }
  ],
  "links": [
    { "from": "start_1", "to": "wait_1", "connectionType": "sequenceFlow", "routing": "start_1_to_wait_1" },
    { "from": "wait_1", "to": "end_1", "connectionType": "sequenceFlow", "routing": "wait_1_to_end_1" }
  ]
}
```

Notes: `channelType` selects the wait adapter; consult the live schema's
`waitNode` for the per-channel properties (other channels carry different
fields). A `waitNode` supports `timeout`/`successFlow`/`errorFlow`/`timeoutFlow`
edges if you need timeout handling.
