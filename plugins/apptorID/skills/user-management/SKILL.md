---
name: user-management
description: >
  Add user management endpoints to an app using apptorID's admin API. Use when the user wants to:
  create users, list users, disable/delete users, manage users from their app, wire orgRefId/userRefId,
  set up admin API access. Triggers on: "create user", "list users", "disable user", "delete user",
  "user management", "orgRefId", "userRefId", "admin API", "access key".
---

# apptorID User Management Agent

You add user management capabilities to an app that already has (or is getting) apptorID authentication. You build backend endpoints that call apptorID's admin API for user CRUD operations.

## What This Does

Generates backend endpoints for creating, listing, getting, updating, disabling, and deleting users via apptorID. Wires `orgRefId` → `org_id` and `userRefId` → `user_id` in JWT tokens so the developer's app can map apptorID users to its own records.

## MANDATORY: Read API Spec First

Before writing ANY code, read `references/apptorID-api-spec.md`. This is the single source of truth for all endpoint URLs, parameter names, and request formats. Do NOT guess parameter names or endpoint paths.

## HARD GATE: Explore and Confirm Before Building

**You MUST complete ALL of these steps before writing ANY code. No exceptions.**

1. **Scan the codebase** — find existing user management pages, team pages, admin panels, user-related components
2. **Check for a set-password / reset-password page** — scan for any existing page where new users can set their password (e.g., `/reset-password`, `/set-password`, `/welcome`). Also check if a `reset_password` app URL is registered via MCP (`apptorID_list_app_urls`).
3. **Present findings** — "I found these existing pages/components related to users: [list]. [Set-password page exists / does NOT exist]."
4. **If NO set-password page exists, tell the user:** "Users created without a password receive an email with a link to set their password. That link needs a page in your app. I'll build a set-password page as part of this so the flow works end-to-end."
5. **Ask where to add user management** —
   "Where should user management endpoints and UI go?
   (A) Integrate into your existing [page/component I found]
   (B) Create new endpoints + new page
   (C) Backend endpoints only, no UI"
   **Wait for the user's answer. Do NOT proceed without it.**
6. **Confirm the plan** — summarize what you'll build (including the set-password page if needed), which files you'll modify, get approval
7. **Only then start writing code**

## How to Work

- **Explore first.** Read existing auth code, config files, and project conventions.
- **One question at a time.** Interactive format — multiple choice, yes/no.
- **Adaptive follow-ups.** After building endpoints, offer relevant next steps based on project state.
- Read the API spec reference file FIRST, then the stack-specific reference file.

## Admin API Authentication

apptorID's admin API uses **access keys** (separate from the OAuth client credentials used for login).

**Step 1: Get admin token**
```bash
curl -X POST https://{realm-url}/oidc/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  -d "access_key_id={your-access-key-id}" \
  -d "access_key_secret={your-access-key-secret}"
```

**CRITICAL:** Parameters are `access_key_id` and `access_key_secret` — snake_case, form-encoded. **NEVER use camelCase** (`accessKeyId` is WRONG and will fail).

Use the **created realm URL** (e.g., `https://acme-x1y2.sandbox.auth.apptor.io`), NOT the master URL.

Returns: `{ "access_token": "admin-jwt-token", "token_type": "Bearer" }`

**Step 2: Call user API with admin token**
```bash
curl -X POST https://{realm-url}/realms/{realmId}/users \
  -H "Authorization: Bearer {admin-jwt-token}" \
  -H "Content-Type: application/json" \
  -d '{ "email": "user@company.com", "firstName": "John", "accountId": "{account-uuid}", "appClientId": "{app-client-uuid}", "orgRefId": "company-123", "userRefId": "user-456" }'
```

Use the **same created realm URL** for user management calls.

## Credential Security (HARD RULES)

- **ALL credentials** (access_key_id, access_key_secret) go in **backend config file only**
- **NEVER** expose in frontend, committed .env files, or client-side bundles
- **NEVER** hardcode or log secrets
- After wiring, suggest: "For production, store secrets securely — K8s Secrets, Vault, or your cloud's secret manager."

## Process

1. **Detect** — find existing auth setup, config file, backend framework, frontend framework
2. **Check credentials** — does the config already have admin API credentials? If not, ask user for them or provision via MCP (`apptorID_create_access_key`)
3. **Check for set-password page** — does the app have a page where new users can set their password? If not, plan to build one.
4. **Read reference** — read `references/apptorID-api-spec.md` first, then the stack-specific reference file's admin API section
5. **Build admin client** — service that acquires admin token, caches it, makes API calls
6. **Build endpoints** — user CRUD routes using the admin client
7. **Build set-password page (if missing)** — frontend page where new users land from the welcome email to set their password. Register the page URL as `reset_password` type via MCP (`apptorID_add_app_urls`). Also register `post_reset_password` redirect URL. See "Set-Password Page" section below for details.
8. **Wire orgRefId/userRefId** — create-user endpoint accepts the developer's org/user IDs and passes them as orgRefId/userRefId
9. **Wire credentials** — add access_key_id/secret to backend config in the apptorID section
10. **Test and review**
11. **Offer next steps** — adaptively suggest relevant features

## Endpoints to Build

- `POST /users` → create user in apptorID with orgRefId/userRefId
- `GET /users` → list users for current realm/org
- `GET /users/:id` → get single user
- `PUT /users/:id` → update user
- `PUT /users/:id/disable` → disable user
- `PUT /users/:id/enable` → enable user
- `DELETE /users/:id` → delete user
- `POST /app-clients/:appClientId/users/:userName/resend-invitation` → resend welcome email (public endpoint, no admin auth needed)

**If set-password page is missing, also build:**
- `GET /set-password` → frontend page (receives `?token=...&client_id=...` from email link)
- `POST /set-password` → backend endpoint that calls apptorID's `POST /reset-password` API

## Set-Password Page (built if missing)

New users created WITHOUT a password receive a welcome email with a link. That link MUST point to a page in the developer's app. If this page doesn't exist, the email link leads to a 404 and the user can never log in.

**The page receives:** `?token={reset-token}&client_id={app-client-id}` as URL query parameters.

**The page does:**
1. Shows a "Set your password" form (new password + confirm password)
2. On submit, calls the backend endpoint which calls apptorID:

```
POST /reset-password
Content-Type: application/json

{
  "token": "{token-from-url}",
  "password": "{new-password}",
  "userName": "{extracted-from-token-sub-claim-or-passed-as-query-param}",
  "appClientId": "{client_id-from-url}"
}
```

3. On success, redirects to the login page (the registered `post_reset_password` URL)

**Register via MCP (`apptorID_add_app_urls`):**
- `reset_password` → URL of this page (e.g., `https://myapp.com/set-password`)
- `post_reset_password` → redirect after success (e.g., `https://myapp.com/login`)

## orgRefId / userRefId Wiring

When creating a user:
```json
{
  "email": "user@company.com",
  "firstName": "John",
  "orgRefId": "company-123",
  "userRefId": "user-456"
}
```

In every JWT token for this user:
```json
{
  "org_id": "company-123",
  "user_id": "user-456"
}
```

The developer's backend extracts `org_id`/`user_id` from the token to look up its own records. No mapping table needed.

## User Creation — Required vs Optional Fields

**Required for ALL user creation:**
- `firstName` (String)
- `email` (String)
- `accountId` (String — the account UUID)

**Required when creating user WITHOUT password (invitation flow):**
- `appClientId` (String — needed so the welcome email contains the correct app URLs)

**Optional:**
- `lastName`, `userName` (defaults to email), `orgRefId`, `userRefId`, `roles`, `phone`, `phonePrefix`

**Auto-generated — NEVER pass these:**
- `userId` — auto-generated UUID. Do NOT generate or pass a user ID.
- `realmId` — taken from the URL path.
- `createdAt`, `updatedAt`

**User endpoints use `{userName}` in the path** (typically the email), NOT a UUID. **`{userName}` MUST be URL-encoded** — emails contain `+`, `@`, `.` which break URLs. Example: `mahesh.oa+1@expeed.com` → `mahesh.oa%2B1%40expeed.com`. Use `URLEncoder.encode()` (Java), `encodeURIComponent()` (JS), `urllib.parse.quote()` (Python).
```
GET    /realms/{realmId}/users/by-username/{userName}
PUT    /realms/{realmId}/users/{userName}
DELETE /realms/{realmId}/users/{userName}
PUT    /realms/{realmId}/users/{userName}/disable
PUT    /realms/{realmId}/users/{userName}/enable
```

## Key Details

- Admin API credentials are SEPARATE from OAuth credentials in the config
- User created WITH password (via set-password after creation) → status ACTIVE immediately (no email)
- User created WITHOUT password → triggers welcome email via default SMTP. Requires `appClientId` in the creation request.
- MCP tools can also do user operations directly: `apptorID_create_user`, `apptorID_list_users`, etc. — use them for one-off operations if user asks
- See `references/apptorID-api-spec.md` for complete endpoint documentation with curl examples

## Reference Files

Read the admin API section of the relevant stack reference:
- Java/Spring → `references/java-spring.md`
- Java/Micronaut → `references/java-micronaut.md`
- Node/Express → `references/nodejs-express.md`
- Python/FastAPI → `references/python-fastapi.md`
- Unlisted stack → build from the API patterns above

## Rules

- Write code, don't describe it.
- Follow project conventions.
- Read reference files FIRST.
- Credentials in backend config only.
- Adapt to any stack.
- After completion, suggest related skills:
  - "Want existing users to be able to reset a forgotten password from the login page?" → `apptorID:forgot-password`
  - "Need to configure email templates or manage apptorID resources?" → `apptorID:manage`
