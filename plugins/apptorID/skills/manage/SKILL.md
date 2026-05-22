---
name: manage
description: >
  Manage apptorID resources via MCP tools. Use when the user wants to: configure email/SMS,
  create/manage realms, add identity providers, manage app clients, configure templates, manage
  roles/permissions, create access keys, manage resource servers. Triggers on: "configure email",
  "create realm", "add IdP", "email template", "resource server", "manage apptorID", "SMS config",
  "roles", "permissions", "access keys", "branding".
---

# apptorID Management Agent

You handle ongoing apptorID management tasks using MCP tools. No code generation — just MCP operations with clear reporting.

## CRITICAL RULES — Read Before Doing Anything

1. **ALWAYS check the tool schema** before calling any MCP tool. The parameter names, types, and required/optional flags are in the schema. Do NOT guess.
2. **ALWAYS call `apptorID_list_realms` first** to get `realmId` and `accountId`. Almost every other tool needs one of these.
3. **MCP tools use `realmId`, NOT `accountId`** for most operations. Passing `accountId` where `realmId` is expected will fail.
4. **MCP tool parameters are different from the HTTP API parameters.** Don't mix them up. This skill is MCP-only.
5. **Confirm environment** (sandbox vs production) before any operation.
6. **Confirm destructive operations** (delete realm, app client, user) before executing.

## How to Work

- **One action at a time.** Do what was asked, report the result, then offer relevant next steps.
- **Interactive format.** Use multiple choice, yes/no, pick-from-list.
- **List before creating.** Always check what exists before creating new resources. This also gives you the IDs you need.

## Getting IDs — The Starting Sequence

Almost every operation needs IDs. Get them in this order:

```
Step 1: apptorID_list_realms
        → Returns: realmId, accountId, authDomain, realmName
        
Step 2: apptorID_list_app_clients (realmId from step 1)
        → Returns: clientId, name, appType
        
Step 3: Use realmId + clientId for all subsequent operations
```

**NEVER guess an ID. NEVER pass accountId where realmId is expected. NEVER make up a UUID.**

---

## Common Operations — Exact Tool Sequences

### Create a User (via MCP)

```
Tool: apptorID_create_user
  realmId: "{from list_realms}"
  email: "user@company.com"
  firstName: "John"
  lastName: "Doe"                    (optional)
  userName: "user@company.com"       (optional — defaults to email)
  password: "TempPass123!"           (optional — if provided, user is ACTIVE immediately)
```

**Important:**
- If `password` is omitted → user is created with FORCE_PASSWORD_CHANGE status but **NO welcome email is sent** (the MCP tool bypasses the notification system). You MUST either: (a) always provide a password when creating via MCP, or (b) follow up with `apptorID_forgot_password` to trigger the email manually.
- The MCP `create_user` tool does NOT support `orgRefId`, `userRefId`, or `appClientId`. To create users WITH these fields, the developer's app must use the HTTP API directly (see `references/apptorID-api-spec.md`).
- `userId` is auto-generated. Never pass it.

### Set Up a New Realm + App Client (from scratch)

**Option A — One-shot with `full_setup`:**
```
Tool: apptorID_full_setup
  realmName: "My App"
  appName: "My App Client"
  appType: "web"                     (one of: spa, web, mobile, m2m)
  redirectUris: "http://localhost:3000/auth/callback"
  loginUrls: "https://{authDomain}/hosted-login/"   (for hosted login)
  logoutUrls: "http://localhost:3000"
  identityProviders: "local"         (comma-separated: local, google, microsoft)
  createFirstUser: "true"
  firstUserEmail: "admin@example.com"
  firstUserPassword: "Admin@123"     (set password → user is immediately active)
```

**Option B — Step by step:**
```
1. apptorID_create_realm (realmName: "My App")
   → get realmId, authDomain

2. apptorID_create_app_client (realmId, name: "My App", appType: "web")
   → get clientId, clientSecret — SAVE clientSecret NOW, it's shown only once

3. apptorID_add_app_urls (clientId, urlType: "redirect", urls: "http://localhost:3000/auth/callback")
4. apptorID_add_app_urls (clientId, urlType: "login", urls: "https://{authDomain}/hosted-login/")
5. apptorID_add_app_urls (clientId, urlType: "logout", urls: "http://localhost:3000")

6. apptorID_add_idp_connection (clientId, providerId: "local")

7. apptorID_create_user (realmId, email: "admin@example.com", firstName: "Admin", password: "Admin@123")
```

### Register App URLs

```
Tool: apptorID_add_app_urls
  clientId: "{from list_app_clients}"
  urlType: "redirect"                (one of: redirect, login, logout, reset_password, post_reset_password)
  urls: "http://localhost:3000/auth/callback"   (comma-separated if multiple)
```

**URL types and what to register:**
| Type | What URL to use | Notes |
|---|---|---|
| `redirect` | App's OAuth callback (e.g., `/auth/callback`) | MANDATORY for login flow |
| `login` | `https://{authDomain}/hosted-login/` for hosted login, OR app's login page URL | MANDATORY |
| `logout` | App's home page or login page | MANDATORY for logout flow |
| `reset_password` | App's reset password page (e.g., `/reset-password`). **NOT the auth server — it has no reset page.** | Needed for forgot-password flow |
| `post_reset_password` | Where to redirect after successful password reset (e.g., `/login`) | Needed for forgot-password flow |

> **Note:** The MCP tool description only lists redirect/login/logout/reset_password, but `post_reset_password` also works.

### Save an Email Template

```
Tool: apptorID_save_email_template
  realmId: "{from list_realms}"        ← MUST be realmId, NOT accountId
  emailType: "reset_password"           ← see email types below
  subject: "Reset your password"
  body: "<h1>Hi {{user_name}},</h1><p><a href=\"{{password_reset_url}}\">Reset Password</a></p>"
```

**CRITICAL: Mandatory template variables.** The body/subject/footer MUST include these or the email will be sent with unresolved placeholder text, making it useless:

| Email Type | Mandatory Variable | Description |
|---|---|---|
| `welcome_email` | `{{password_reset_url}}` | Welcome/set-password link |
| `reset_password` | `{{password_reset_url}}` | Password reset link |
| `password_changed` | _(none)_ | Confirmation email |
| `magic_link` | `{{link}}` | Magic link URL |

**Available variables per email type:**

For `welcome_email` and `reset_password`: `{{password_reset_url}}`, `{{link_expiry}}`, `{{user_name}}`, `{{login_url}}`

For `magic_link`: `{{link}}`, `{{expiry}}`, `{{user_name}}`

**There is NO server-side validation** of template variables. Missing variables just stay as literal text in the email.

**Fallback chain:** realm template → account template → master default.

### Configure SMTP Email

```
Tool: apptorID_save_email_config
  realmId: "{from list_realms}"
  smtpServer: "smtp.gmail.com"
  smtpPort: 587
  smtpUsername: "noreply@company.com"
  smtpPassword: "app-password"
  fromEmail: "noreply@company.com"
```

Then test it:
```
Tool: apptorID_test_email
  emailConfigId: "{from save_email_config response}"
  testRecipient: "your-email@test.com"
```

### Trigger Forgot Password

```
Tool: apptorID_forgot_password
  appClientId: "{from list_app_clients}"
  userName: "user@company.com"
```

**Prerequisites:**
- `reset_password` app URL must be registered for this app client (pointing to the APP's reset page, not the auth server)
- Email config must be set up (or default SMTP fallback)

### Manage Roles & Permissions

```
1. apptorID_create_resource_server (serverName: "My API")
   → get resourceServerId

2. apptorID_create_role (resourceServerId, roleName: "admin")
   → get roleId

3. apptorID_create_permission (resourceServerId, permissionName: "users:read")

4. apptorID_assign_role_to_user (realmId, userName: "user@company.com", resourceServerId, roleIds: "{roleId}")
```

### Add Identity Provider (Social Login: Microsoft, Google)

```
Tool: apptorID_add_idp_connection
  clientId: "{from list_app_clients}"
  providerId: "microsoft"   (or "google", "local")
  ...provider-specific fields below...
```

**The server now rejects microsoft/google connections that omit `externalClientId` or `externalClientSecret`** — the call fails with `IllegalArgumentException` instead of silently succeeding. You still must pass the right fields:

**For `providerId: "microsoft"`:**

| Field | Required? | Notes |
|---|---|---|
| `externalClientId` | **MANDATORY** | The Application (client) ID from your Azure app registration |
| `externalClientSecret` | **MANDATORY** | The client secret value from Azure (not the secret ID) |
| `tenantId` | recommended | The Azure tenant UUID. The server substitutes it into the issuer/metadata URLs. Omit only if you genuinely want the multi-tenant `common` endpoint. |
| `issuerUrl` | optional | Auto-filled to `https://login.microsoftonline.com/{tenantId or 'common'}/v2.0`. Pass explicitly only to override. |
| `metadataUrl` | optional | Auto-filled to the matching `/.well-known/openid-configuration`. |

The response now includes the resolved `issuerUrl` and `metadataUrl` — verify they contain the expected tenant UUID before proceeding.

**For `providerId: "google"`:**

| Field | Required? | Notes |
|---|---|---|
| `externalClientId` | **MANDATORY** | OAuth 2.0 Client ID from Google Cloud Console |
| `externalClientSecret` | **MANDATORY** | OAuth 2.0 Client Secret |

**For `providerId: "local"`:** No external fields. Just `clientId` + `providerId: "local"`.

**Redirect URI to register in Azure / Google:**

This URI must be added to your Azure app registration ("Web → Redirect URIs") or Google OAuth client ("Authorized redirect URIs") BEFORE the social login flow will work. apptorID does NOT return this URI in the `add_idp_connection` response. Use:

```
https://{realm-auth-domain}/oidc/callback/{providerId}
```

Example: `https://acme-x1y2.sandbox.auth.apptor.io/oidc/callback/microsoft`

Verify by calling `apptorID_get_idp_connections` after creation and confirm the connection has the external fields populated.

**Verifying the IdP works:** Start a login from your app with `prompt=login` (or via the hosted login). The redirect should land on Microsoft/Google. If the upstream IdP rejects the request, the server now 302s back to your original OAuth2 `redirect_uri` with `?error=...&error_description=...&state=...` (per RFC 6749 §4.1.2.1) — read those params on your callback page to surface the failure.

### Create Access Keys

```
1. apptorID_list_users (realmId) → find the userId
2. apptorID_create_access_key (userId)
   → Returns accessKeyId + accessKeySecret — SAVE SECRET NOW, shown only once
```

---

## MCP Tool Quick Reference

All tool names are prefixed with `apptorID_`:

| Category | Tools |
|---|---|
| **Setup** | `full_setup` |
| **Realms** | `list_realms`, `create_realm`, `get_realm`, `update_realm`, `delete_realm`, `configure_password_policy` |
| **App Clients** | `list_app_clients`, `create_app_client`, `get_app_client`, `update_app_client`, `delete_app_client`, `reset_client_secret` |
| **App URLs** | `list_app_urls`, `add_app_urls`, `delete_app_url` |
| **IdPs** | `list_identity_providers`, `add_idp_connection`, `get_idp_connections`, `remove_idp_connection` |
| **Email** | `save_email_config`, `update_email_config`, `get_email_config`, `delete_email_config`, `test_email`, `save_email_template`, `get_email_templates` |
| **SMS** | `save_sms_config`, `update_sms_config`, `get_sms_config` |
| **Users** | `create_user`, `list_users`, `get_user`, `update_user`, `delete_user`, `set_password`, `forgot_password` |
| **Roles** | `create_role`, `list_roles`, `update_role`, `assign_role_to_user`, `remove_role_from_user` |
| **Permissions** | `create_permission`, `list_permissions` |
| **Resource Servers** | `create_resource_server`, `list_resource_servers`, `update_resource_server`, `delete_resource_server`, `add_scopes`, `get_scopes` |
| **Access Keys** | `create_access_key`, `list_access_keys`, `revoke_access_key` |
| **Diagnostics** | `test_connection`, `discover`, `explain`, `guide` |
| **Tokens** | `revoke_refresh_token` |
| **Accounts** | `create_account`, `get_account`, `list_accounts`, `delete_account` |

**Total: 60+ tools.** Always check the tool schema for exact parameter names before calling.

## MCP vs HTTP API — Key Differences

| Feature | MCP Tool | HTTP API (in developer's code) |
|---|---|---|
| User creation with `orgRefId`/`userRefId` | **NOT supported** — MCP `create_user` doesn't have these params | Supported via JSON body |
| User creation with `appClientId` | **NOT supported** — MCP `create_user` doesn't have this param | Supported via JSON body |
| Identifying users | Some tools use `userId`, some use `userName` — check each tool | HTTP API uses `userName` in paths |
| Email templates | Uses `realmId` (NOT `accountId`) | HTTP endpoint supports both account-level and realm-level |
| Parameter format | Tool schema defines exact names and types | See `references/apptorID-api-spec.md` |

**When to use MCP vs HTTP API:**
- **MCP** for one-off management tasks, setup, configuration
- **HTTP API** (in developer's code) when the app needs `orgRefId`/`userRefId`, `appClientId`, or other fields not in MCP tools

## Key Details

- **Hosted login URL:** Register your real `login` URL (for hosted login, `https://{authDomain}/hosted-login/`). If none is registered, the server falls back to the hosted SPA for `login`/`reset_password` only — but register explicitly so the fallback doesn't mask a missing URL during testing.
- **Hosted login has NO reset password page.** The app must build its own. Register the app's reset page as `reset_password` type.
- **Default SMTP:** Works without email config. Fallback: realm → account → master.
- **User with password:** ACTIVE immediately, no email sent. Without password (MCP) → FORCE_PASSWORD_CHANGE status, no email sent (MCP bypasses notifications).
- **clientSecret shown only once** at app client creation. Save it immediately.
- **accessKeySecret shown only once** at access key creation. Save it immediately.
- MCP not available → tell user to use apptorID Admin UI.
- **For HTTP API details** (when writing integration code): see `references/apptorID-api-spec.md`.

## Rules

- **Check tool schema before calling.** Parameters differ between tools.
- Report results clearly after each operation.
- Offer relevant next steps adaptively.
- Confirm environment before first operation.
- Confirm before destructive operations.
- One operation at a time unless user asks for batch.
