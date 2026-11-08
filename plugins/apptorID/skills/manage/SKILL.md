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
  password: "TempPass123!"           (optional — checked against the realm password policy; if provided, user is `active` immediately)
```

**Important:**
- If `password` is omitted → user is created with status `force_change_password` and **NO welcome email is sent**. Either (a) provide a password, or (b) follow up with `apptorID_set_password`, or `apptorID_forgot_password` (needs an app client) to email a reset link.
- A password that fails the realm policy is rejected with the policy message.
- The MCP `create_user` tool does NOT support `orgRefId`, `userRefId`, or `appClientId`. To create users WITH these fields, the developer's app must use the HTTP API directly (see `references/apptorID-api-spec.md`).
- `userId` is auto-generated. Never pass it.

### Set Up a New Realm + App Client (from scratch)

**Option A — One-shot with `full_setup`:**
```
Tool: apptorID_full_setup
  realmName: "My App"
  appName: "My App Client"
  appType: "web"                     (one of: spa, web, mobile, desktop; anything else is rejected)
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
| `reset_password` | App's own reset password page (e.g., `/reset-password`). If unregistered, links fall back to the hosted reset page `https://{authDomain}/hosted-login/`. | Only if the app has its own reset page |
| `post_reset_password` | Accepted, but nothing in apptorID reads it, so don't register it | Not needed |

> **Note:** Any other URL type (including uppercase like `LOGIN`) is rejected with 400.

### Save an Email Template

```
Tool: apptorID_save_email_template
  realmId: "{from list_realms}"        ← MUST be realmId, NOT accountId
  emailType: "reset_password"           ← see email types below
  subject: "Reset your password"
  body: "<h1>Hi {{user_name}},</h1><p><a href=\"{{password_reset_url}}\">Reset Password</a> (valid for {{link_expiry}})</p>"
```

`emailType` must be one of `welcome_email`, `reset_password`, `password_changed`, `magic_link`; anything else is rejected.

**Mandatory template variables.** The server rejects a template whose subject, body and footer lack one of these, with `{{var}} is mandatory`:

| Email Type | Required by the server | Description |
|---|---|---|
| `welcome_email` | `{{password_reset_url}}`, `{{user_name}}` | Welcome/set-password link |
| `reset_password` | `{{password_reset_url}}`, `{{user_name}}`, `{{link_expiry}}` | Password reset link |
| `password_changed` | _(none)_ | Confirmation email |
| `magic_link` | _(none enforced — include `{{link}}` or the email is useless)_ | Magic link URL |

**Available variables per email type:**

For `welcome_email` and `reset_password`: `{{password_reset_url}}`, `{{link_expiry}}`, `{{user_name}}`, `{{login_url}}`

For `magic_link`: `{{link}}`, `{{expiry}}`, `{{user_name}}`

Unknown variables are not checked; they stay as literal text in the email.

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
- `reset_password` app URL registered only if the app has its own reset page; otherwise the link goes to the hosted reset page
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

**The server does NOT validate microsoft/google credentials** — a connection created without `externalClientId` or `externalClientSecret` is saved, then fails at login. Always pass both:

**For `providerId: "microsoft"`:**

| Field | Required? | Notes |
|---|---|---|
| `externalClientId` | **MANDATORY** | The Application (client) ID from your Azure app registration |
| `externalClientSecret` | **MANDATORY** | The client secret value from Azure (not the secret ID) |
| `issuerUrl` | optional (MCP) | Defaults to the multi-tenant `https://login.microsoftonline.com/common/v2.0`. For a single Azure tenant pass `https://login.microsoftonline.com/{tenantId}/v2.0`. There is no `tenantId` parameter. |
| `metadataUrl` | optional | Defaults to the `common` `/.well-known/openid-configuration`. For a single tenant pass `https://login.microsoftonline.com/{tenantId}/v2.0/.well-known/openid-configuration`. |

The response does not include the issuer/metadata URLs — check them with `apptorID_get_idp_connections`.

**For `providerId: "google"`:**

| Field | Required? | Notes |
|---|---|---|
| `externalClientId` | **MANDATORY** | OAuth 2.0 Client ID from Google Cloud Console |
| `externalClientSecret` | **MANDATORY** | OAuth 2.0 Client Secret |

**For `providerId: "local"`:** No external fields. Just `clientId` + `providerId: "local"`.

**Provider token vault fields (optional — any external provider):**

| Field | Required? | Notes |
|---|---|---|
| `returnProviderTokens` | optional (default `false`) | Return the external provider's own access/id token inline in the `/oidc/token` login response. Requires the app client to authenticate with **S256 PKCE or a client secret**. |
| `storeProviderTokens` | optional (default `false`) | Persist the provider's tokens encrypted so your backend can retrieve/refresh them later via the **token-exchange** grant. Enabling this AUTO-requests a provider refresh token — do **not** add `offline_access` yourself. |
| `providerScopes` | optional | Space-delimited extra scopes to request from the provider (e.g. `https://www.googleapis.com/auth/calendar.readonly`). Only needed to call the provider's own APIs; omit for plain SSO. |

Use these only when your app needs the *external provider's* token (e.g. to call Google/Microsoft APIs as the user). For plain sign-in, leave them unset. Retrieve a stored token later with `grant_type=urn:ietf:params:oauth:grant-type:token-exchange` (`subject_token` + `idp_connection_id`) — it comes back fresh, auto-refreshed.

**Redirect URI to register in Azure / Google:**

This URI must be added to your Azure app registration ("Web → Redirect URIs") or Google OAuth client ("Authorized redirect URIs") BEFORE the social login flow will work. apptorID does NOT return this URI in the `add_idp_connection` response. Use:

```
https://{realm-auth-domain}/oidc/callback/{providerId}
```

Example: `https://acme-x1y2.sandbox.auth.apptor.io/oidc/callback/microsoft`

Verify by calling `apptorID_get_idp_connections` after creation and confirm the connection has the external fields populated.

**Verifying the IdP works:** Start a login from your app with `prompt=login` (or via the hosted login). The redirect should land on Microsoft/Google. If the upstream IdP rejects the request, the auth server's callback returns an error itself; the browser is not redirected back to your `redirect_uri`, so check the error shown on the auth server page.

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

> **Teardown order:** `delete_realm` fails while the realm still has users or app clients. `delete_user` fails with "User should be disabled" unless the user is disabled first, and there is NO MCP disable tool: disable over HTTP (`PUT /realms/{realmId}/users/{userName}/disable`, admin token), then `delete_user`, then `delete_app_client`, delete any realm email templates over HTTP (`DELETE /email-templates/{id}`; IDs from `get_email_templates` per `emailType`), then `delete_realm`.
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

- **Hosted login URL:** Always register a `login` URL (for hosted login, `https://{authDomain}/hosted-login/`). Without one, a plain `/oidc/auth` fails with `no_login_url_registered`; only `provider_id=local` requests and email links fall back to the hosted SPA.
- **Hosted login includes Forgot password and Reset password pages.** Register a `reset_password` URL only if the app builds its own reset page.
- **Default SMTP:** Works without email config. Fallback: realm → account → master.
- **MCP `create_user`:** with password → `active`; without → `force_change_password`. Neither sends an email. The HTTP API (`POST /realms/{realmId}/users`) sends a welcome email for every local user unless `appHandlesNotification=true`.
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
