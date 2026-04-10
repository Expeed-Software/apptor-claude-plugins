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

## How to Work

- **Explore first.** Read existing auth code, config files, and project conventions.
- **One question at a time.** Interactive format — multiple choice, yes/no.
- **Adaptive follow-ups.** After building endpoints, offer relevant next steps based on project state.
- Read the relevant reference file BEFORE writing code.

## Admin API Authentication

apptorID's admin API uses **access keys** (separate from the OAuth client credentials used for login):

```
POST {realm}/oidc/token
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials
&access_key_id={access_key_id}
&access_key_secret={access_key_secret}

→ Returns: { access_token: "admin-jwt-token" }
```

Then use that admin token for API calls:
```
POST {master-realm}/realms/{realmId}/users
Authorization: Bearer {admin-jwt-token}
Content-Type: application/json

{ "email": "user@company.com", "firstName": "John", "orgRefId": "company-123" }
```

## Credential Security (HARD RULES)

- **ALL credentials** (access_key_id, access_key_secret) go in **backend config file only**
- **NEVER** expose in frontend, committed .env files, or client-side bundles
- **NEVER** hardcode or log secrets
- After wiring, suggest: "For production, store secrets securely — K8s Secrets, Vault, or your cloud's secret manager."

## Process

1. **Detect** — find existing auth setup, config file, backend framework
2. **Check credentials** — does the config already have admin API credentials? If not, ask user for them or provision via MCP (`apptorID_create_access_key`)
3. **Read reference** — read the stack-specific reference file's admin API section
4. **Build admin client** — service that acquires admin token, caches it, makes API calls
5. **Build endpoints** — user CRUD routes using the admin client
6. **Wire orgRefId/userRefId** — create-user endpoint accepts the developer's org/user IDs and passes them as orgRefId/userRefId
7. **Wire credentials** — add access_key_id/secret to backend config in the apptorID section
8. **Test and review**
9. **Offer next steps** — adaptively suggest relevant features

## Endpoints to Build

- `POST /users` → create user in apptorID with orgRefId/userRefId
- `GET /users` → list users for current realm/org
- `GET /users/:id` → get single user
- `PUT /users/:id` → update user
- `PUT /users/:id/disable` → disable user
- `PUT /users/:id/enable` → enable user
- `DELETE /users/:id` → delete user
- `POST /users/:id/resend-invitation` → resend welcome email

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

## Key Details

- Admin API credentials are SEPARATE from OAuth credentials in the config
- User created WITH password → status ACTIVE immediately (no email)
- User created WITHOUT password → triggers welcome email via default SMTP
- MCP tools can also do user operations directly: `apptorID_create_user`, `apptorID_list_users`, etc. — use them for one-off operations if user asks

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
  - "Want to add forgot password?" → `apptorID:forgot-password`
  - "Need to configure email or manage resources?" → `apptorID:manage`
