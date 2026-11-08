# apptorID API Specification

> **The live OpenAPI spec is the source of truth — this file is a curated quick reference.** Before writing integration code, fetch `https://{realm-authDomain}/swagger/apptor-auth-server-{version}.yml` (or browse `/swagger-ui/`). This file covers the endpoints the plugin uses most, verified against the server source — but when the two disagree, **the live spec wins** and you should flag the drift. Do NOT guess parameter names, endpoint paths, or URL patterns; fetch, then read.

## OpenAPI / Swagger

The auth server has a live OpenAPI spec:
- **Swagger UI:** `https://{any-realm-url}/swagger-ui/`
- **OpenAPI YAML:** `https://{any-realm-url}/swagger/apptor-auth-server-{version}.yml` — read the current file name from `https://{any-realm-url}/swagger-ui/index.html`

If you're unsure about any endpoint, parameter, or response format — **check the Swagger UI first.**

## Mandatory vs Optional Fields — Quick Reference

### User Creation (`POST /realms/{realmId}/users`)
| Field | Required? | Notes |
|---|---|---|
| `firstName` | **MANDATORY** | |
| `email` | **MANDATORY unless `phone` + `phonePrefix` given** | Always required for federated users. Decides the notification channel (email if present, else SMS) |
| `userName` | **MANDATORY** | Not defaulted — pass the email if usernames are emails. Federated users: must equal `email` |
| `appClientId` | **MANDATORY for local users** | 400 if missing or unknown. Needed for welcome email links. Not used for federated users |
| `accountId` | optional | Defaults to the admin token's account |
| `password` | optional | Validated against the realm policy; user becomes active. Not allowed for federated users |
| `localIdp` | optional | Defaults to `true`. `false` = federated (Google/Microsoft) user: no password, no welcome email |
| `lastName` | optional | |
| `orgRefId` | optional | Maps to `org_id` JWT claim. Include if app uses org-level tenancy. |
| `userRefId` | optional | Maps to `user_id` JWT claim. Include if app needs a user external ID. |
| `roles` | optional | Array of `{ "roleName": "...", "resourceServerName": "..." }` (both required per entry) |
| `phone` | optional | |
| `phonePrefix` | optional | |
| `userId` | **NEVER PASS** | Auto-generated |
| `realmId` | **NEVER PASS** | From URL path |

### Forgot Password (`POST /app-clients/{appClientId}/users/{userName}/forgot-password`)
| Field | Required? | Notes |
|---|---|---|
| `appClientId` | **MANDATORY** | In URL path — needed for email link URLs |
| `userName` | **MANDATORY** | In URL path — the user's username/email |

**This is a PUBLIC endpoint — no authentication required.** There is a `/secured` variant (`POST /app-clients/{appClientId}/users/{userName}/forgot-password/secured`) that requires admin auth and supports the `appHandlesNotification` query param.

### Reset Password (`POST /reset-password`)
| Field | Required? | Notes |
|---|---|---|
| `token` | **MANDATORY** | From email link query param. Single-use |
| `password` | **MANDATORY** | New password |
| `appClientId` | **MANDATORY** | From email link query param `client_id` |
| `userName` | not used | The user is resolved from the token |

### Admin Token (`POST /oidc/token` with `grant_type=client_credentials`)
| Field | Required? | Notes |
|---|---|---|
| `grant_type` | **MANDATORY** | Must be `client_credentials` |
| `access_key_id` | **MANDATORY** | snake_case, form-encoded |
| `access_key_secret` | **MANDATORY** | snake_case, form-encoded |

### Email Template (`POST /accounts/{accountId}/email-types/{emailType}/email-templates` or realm-level equivalent)
| Field | Required? | Notes |
|---|---|---|
| `accountId` or `realmId` | **MANDATORY** | In URL path |
| `emailType` | **MANDATORY** | In URL path — e.g., `welcome_email`, `reset_password`, `password_changed`, `magic_link` |
| `subject` | **MANDATORY** | Email subject line |
| `body` | **MANDATORY** | HTML body with template variables |
| `active` | optional | Defaults to true |

### Resend Invitation (`POST /app-clients/{appClientId}/users/{userName}/resend-invitation`)
| Field | Required? | Notes |
|---|---|---|
| `appClientId` | **MANDATORY** | In URL path |
| `userName` | **MANDATORY** | In URL path |

**This is a PUBLIC endpoint — no authentication required.** There is a `/secured` variant (`POST /app-clients/{appClientId}/users/{userName}/resend-invitation/secured`) that requires admin auth.

## URL Routing — How Realm URLs Work

**All routing is HOST-HEADER based.** The auth server resolves the realm from the hostname you're calling:

- `master.sandbox.auth.apptor.io` → master realm (MCP operations, account management)
- `acme-x1y2.sandbox.auth.apptor.io` → the "acme" realm created for a specific app

**URL rules for integration code (verified against source code):**

### OIDC user-facing endpoints — MUST use created realm URL

These endpoints resolve the realm from the Host header. The realm determines which users, clients, and keys are valid. Using the wrong URL means login/token operations target the wrong realm.

| Endpoint | URL | Why |
|---|---|---|
| `GET /.well-known/openid-configuration` | **Created realm** | Returns this realm's endpoints and keys |
| `GET /oidc/auth` (start login) | **Created realm** | Authenticates against this realm's users |
| `POST /oidc/login` | **Created realm** | Validates credentials for this realm |
| `POST /oidc/pre-authorize` | **Created realm** | Validates credentials for this realm |
| `POST /oidc/token` (authorization_code) | **Created realm** | Exchanges code for this realm's tokens |
| `POST /oidc/token` (refresh_token) | **Created realm** | Refreshes token for this realm |
| `GET /oidc/jwks` | **Created realm** | Public keys for this realm's tokens |
| `GET /oidc/userinfo` | **Created realm** | User info for this realm |
| `GET /oidc/logout` | **Created realm** | Logout from this realm |
| `POST /oidc/revoke` | **Created realm** | Revokes token for this realm |
| `GET /hosted-login/` | **Created realm** | Hosted login page for this realm |

### Admin API endpoints — any realm host in YOUR account works (security is token-based)

The admin CRUD controllers validate the Bearer token's `account_id`, NOT the Host header. You can call them on the master URL or any of your realm URLs — they resolve the target from the path's `realmId`/`accountId` and check it against your token's account.

**Exception — the token endpoint itself DOES use the Host header.** `POST /oidc/token` resolves a realm from the Host before issuing the token; the host must map to *some* valid realm in your account, or it fails with realm-not-found. So "any URL" is only true once you hold the token — minting it requires a host that resolves to a real realm (the master URL always works for this).

| Endpoint | URL | Auth |
|---|---|---|
| `POST /oidc/token` (client_credentials + access_key) | **Host must resolve to a real realm** (master URL works) | None (generates token) |
| `POST /realms/{realmId}/users` (create user) | **Any realm host in your account** — realmId is in the path | Bearer admin token |
| `GET /realms/{realmId}/users` (list users) | **Any** | Bearer admin token |
| `GET /realms/{realmId}/users/by-username/{userName}` | **Any** | Bearer admin token |
| `PUT /realms/{realmId}/users/{userName}` | **Any** | Bearer admin token |
| `DELETE /realms/{realmId}/users/{userName}` | **Any** | Bearer admin token |
| `PUT /realms/{realmId}/users/{userName}/disable` | **Any** | Bearer admin token |
| `PUT /realms/{realmId}/users/{userName}/enable` | **Any** | Bearer admin token |

### Public endpoints — ANY URL, no auth needed

| Endpoint | URL | Auth |
|---|---|---|
| `POST /app-clients/{appClientId}/users/{userName}/forgot-password` | **Any** | **None** (public) |
| `POST /reset-password` | **Any** | **None** (public) |
| `POST /app-clients/{appClientId}/users/{userName}/resend-invitation` | **Any** | **None** (public) |

### Simple rule for integration code

**Use the created realm URL for everything.** It works for all endpoint types. The distinction above is documented so Claude understands WHY things work, not to suggest using different URLs for different calls.

```
# Store ONE URL in config — the created realm URL:
APPTOR_REALM_URL=https://acme-x1y2.sandbox.auth.apptor.io

# Use it for everything:
GET  ${APPTOR_REALM_URL}/.well-known/openid-configuration
POST ${APPTOR_REALM_URL}/oidc/token
POST ${APPTOR_REALM_URL}/realms/{realmId}/users
POST ${APPTOR_REALM_URL}/app-clients/{appClientId}/users/{userName}/forgot-password
POST ${APPTOR_REALM_URL}/reset-password
```

---

## CRITICAL: Parameter Naming

**ALL HTTP request parameters are snake_case. NEVER use camelCase in HTTP requests.**

```
CORRECT: access_key_id, access_key_secret, grant_type, client_id, client_secret, refresh_token
WRONG:   accessKeyId,   accessKeySecret,   grantType,  clientId,  clientSecret,  refreshToken
```

**JSON request BODIES use camelCase** (Java DTO convention):
```
CORRECT: { "firstName": "John", "orgRefId": "company-123", "appClientId": "uuid" }
WRONG:   { "first_name": "John", "org_ref_id": "company-123" }
```

**Summary:**
- Form-encoded params (token endpoint, login, pre-authorize) → **snake_case**
- JSON body fields (user creation, reset password) → **camelCase**

---

## Token Endpoint

```
POST /oidc/token
Content-Type: application/x-www-form-urlencoded
```

### Grant Type: authorization_code (user login)

```bash
curl -X POST https://{realm-url}/oidc/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=authorization_code" \
  -d "client_id={uuid}" \
  -d "client_secret={string}" \
  -d "code={authorization-code}"
```

If the IdP connection has `returnProviderTokens=true`, the response ALSO includes a `provider_tokens` object carrying the external provider's own `access_token`/`id_token` (so your backend can call that provider's APIs as the user). This requires the app client to authenticate with **S256 PKCE or a client secret** — plain/no PKCE is rejected. The provider refresh token is never returned inline (it stays server-side).

### Grant Type: client_credentials (admin API token)

```bash
curl -X POST https://{realm-url}/oidc/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  -d "access_key_id={string}" \
  -d "access_key_secret={string}"
```

**CRITICAL:** The parameters are `access_key_id` and `access_key_secret` — snake_case, form-encoded. NOT `accessKeyId` / `accessKeySecret`.

Returns:
```json
{ "access_token": "admin-jwt-token", "token_type": "Bearer", "expires_in": 3600 }
```

### Grant Type: refresh_token

`client_secret` is required — a client without a matching secret (e.g. a browser SPA) cannot refresh; start a new `/oidc/auth` login instead.

```bash
curl -X POST https://{realm-url}/oidc/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=refresh_token" \
  -d "refresh_token={token}" \
  -d "client_id={uuid}" \
  -d "client_secret={string}"
```

### Grant Type: password (direct login — avoid in production)

```bash
curl -X POST https://{realm-url}/oidc/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "username={string}" \
  -d "password={string}" \
  -d "client_id={uuid}" \
  -d "client_secret={string}"
```

### Grant Type: token-exchange (RFC 8693 — get/refresh a provider token)

Exchange an Apptor ID token for the **external provider's** token held in the vault (requires the IdP connection's `storeProviderTokens=true`). The provider token is auto-refreshed if expired — you never call a separate refresh endpoint.

```bash
curl -X POST https://{realm-url}/oidc/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "subject_token={apptorID access or refresh token}" \
  -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "idp_connection_id={idpConnectionId}" \
  -d "client_id={uuid}" \
  -d "client_secret={string}"
```

- **Confidential client:** send `client_id`+`client_secret`; `subject_token` = Apptor ID **access** token; `subject_token_type=urn:ietf:params:oauth:token-type:access_token`.
- **Public client:** no secret; `subject_token` = Apptor ID **refresh** token; `subject_token_type=urn:ietf:params:oauth:token-type:refresh_token`.
- Returns `{ "access_token": "<provider token — fresh>", "issued_token_type": "urn:apptorid:oauth:token-type:provider-token", "token_type": "Bearer", "expires_in": <int> }`.
- The user is resolved from the validated `subject_token`, never a parameter — you cannot request another user's provider token.

---

## Onboarding / Admin API (realm, app client, URLs, IdP, access keys, RBAC)

These are the endpoints a SaaS app calls at **customer-onboarding time** (Model A) or during dev setup. All require an admin Bearer token from the `client_credentials` grant. Auth column: `M+R` = role `master_realm_manage` OR `realm_manage`; `M` = `master_realm_manage` only. A customer's Apptor-issued access key carries `realm_manage` scoped to its account — it can do every `M+R` operation within its own account and nothing in another account.

> **There is NO account-create endpoint in scope.** Apptor provisions accounts and hands over the access key. Do not attempt `POST /accounts` — it requires `master_realm_manage`, which customer keys do not have.

> **Always cross-check against the live OpenAPI** at `/swagger/apptor-auth-server-{version}.yml`. The list below is verified against the server source but the live spec is authoritative.

### Realm

| Method | Path | Auth | Notes |
|---|---|---|---|
| POST | `accounts/{accountId}/realms` | M+R | Body = `Realm` DTO. `accountId` comes from your admin token's `account_id` claim. Returns `realmId`, `authDomain`. |
| GET | `accounts/{accountId}/realms` | M+R | List realms in the account |
| GET | `realms/{realmId}` | M+R | Includes password-policy fields |
| DELETE | `realms/{realmId}` | M+R | Cascade delete |
| PUT | `realms/{realmId}/password-policy` | M+R | Persists only the password-policy fields and `allowUserNameChange` (despite taking a full `Realm` body). `defaultPasswordPolicy` is required. There is no general realm-update HTTP endpoint. |
| GET / PUT | `realms/{realmId}/branding` | M+R | `BrandingConfig` |

**`Realm` DTO fields:** `realmName` (NOT `name`), `authDomain`, `accountId`, `productOwnerRefId`, `defaultPasswordPolicy` (defaults to `true` on create; when `false`, all five `password*` fields are required), `passwordMinLength`, `passwordRequiresNumber`, `passwordRequiresSpecialChar`, `passwordRequiresUpperCase`, `passwordRequiresLowerCase`, `allowUserNameChange` (lets `PUT .../users/{userName}` change a user's `userName`).

> **Allowed characters (validated server-side — build your forms to match):**
> - **`authDomain`** — letters, digits, and hyphens only (`^[a-zA-Z0-9-]+$`). It is the subdomain label (e.g. `acme-corp`), so hyphens are valid; do not restrict it to alphanumerics.
> - **Password** — every password may contain **only** letters, digits, and `!@#$%^&*()-_+=[]{}|;:,.<>?/~`, whatever the policy; any other character (double/single quote, backtick, backslash, whitespace, unicode) is rejected server-side with a message naming the offending character. When `passwordRequiresSpecialChar` is enabled, at least one character from that set is required.

### App Client

| Method | Path | Auth | Notes |
|---|---|---|---|
| POST | `realms/{realmId}/app-clients` | M+R | Body = `AppClient`. Returns `clientId` + `clientSecret` (secret shown once). |
| PUT | `realms/{realmId}/app-clients` | M+R | Body's `clientId` selects which one |
| GET | `realms/{realmId}/app-clients` | M+R | |
| GET | `app-clients/{clientId}` | M+R | |
| DELETE | `app-clients/{appClientId}` | M+R | |
| POST | `app-clients/{clientId}/reset-secret` | M+R | Rotates secret; new secret in response. **Returns 400 on servers older than the admin-API fix release** — use MCP `apptorID_reset_client_secret` there |
| POST | `app-clients/{appClientId}/resource-servers/{resourceServerName}` | M+R | Link one RS **by name** |
| PUT | `app-clients/{appClientId}/resource-servers` | M+R | Replace all RS links; body = `List<String>` of names |

**`AppClient` DTO fields:** `name`, `appType` (`spa`/`web`/`mobile`/`desktop`), `realmId`, `idpClient` (**always send `false`**), `multiTenant` (**always send `false`** — no-op server-side), `accessTokenExpirationInMin`, `idTokenExpirationInMin`, `refreshTokenExpirationInDays`, `requiresMfa`, `resourceServerNames`, `passwordTokenExpiryInSeconds`, `otpValidityInSeconds`, `maxConcurrentSessions` (optional cap on concurrent login/refresh-token sessions a single user may hold with this client; leave blank or `0` for unlimited — when a positive cap is exceeded the oldest session is evicted).

### App URLs

`UrlType` values: `login`, `logout`, `redirect`, `reset_password`, `post_reset_password`. Any other value is rejected with 400, on add and on app-client create/update.

| Method | Path | Auth | Notes |
|---|---|---|---|
| POST | `app-clients/{clientId}/url-type/{urlType}/app-urls` | M+R | **URL type is mid-path**, not in the body. Body = `List<AppUrl>` where each `AppUrl` = `{ "type": "...", "url": "...", "appClientId": "..." }`. |
| GET | `app-clients/{clientId}/app-urls` | M+R | |
| DELETE | `app-clients/{clientId}/app-urls/{urlType}/url/{url}` | M+R | URL value in path (URL-encode it). Note the path ordering differs from POST. There is no PUT — delete then re-create. |

**Register `login`, `redirect`, `logout` BEFORE testing login.** Without a `login` URL, a plain `/oidc/auth` fails with `no_login_url_registered`; only `provider_id=local` requests (not `idpClient` apps) and email links fall back to `https://{authDomain}/hosted-login/`.

**Matching rules (multi-tenant / multi-origin apps):**
- `redirect_uri`, `login_uri` and `post_logout_redirect_uri` must equal a registered URL of that type: whole string, case-insensitive. No wildcards, no prefix matching. Register every tenant origin separately.
- A registered `https://` URL never accepts `http://`. A registration without a scheme accepts itself and its `https://` form only.
- `login_uri` selects among several registered login URLs; omitted → the first one.
- Email links (reset, welcome, login link) always use the app client's FIRST registered `reset_password` / `login` URL. For per-tenant links use one app client per tenant, or `appHandlesNotification=true` and build the link in the app.

### Identity Provider Connections

| Method | Path | Auth | Notes |
|---|---|---|---|
| GET | `identity-providers` | authenticated | Global list of supported providers |
| POST | `app-clients/{clientId}/idp-connections` | M+R | Body = `IdpConnection` |
| GET | `app-clients/{clientId}/idp-connections` | M+R | |
| GET | `idp-connections/{idpConnectionId}` | M+R | |
| PUT | `app-clients/{clientId}/idp-connections/{idpConnectionId}` | M+R | |
| DELETE | `app-clients/{clientId}/idp-connections/{idpConnectionId}` | M+R | |

**`IdpConnection` DTO fields:** `providerId` (`local`/`google`/`microsoft`), `clientId` (the EXTERNAL provider's OAuth client id), `clientSecret` (external secret), `issuerUrl`, `metadataUrl`, `grantType`, `authUrl`, `returnProviderTokens` (bool, default `false`), `storeProviderTokens` (bool, default `false`), `providerScopes` (space-delimited extra scopes to request from the external provider). See "Identity Provider Configuration" for required-field rules and the Microsoft tenant URL handling.

> **Over HTTP, always send `grantType: "authorization_code"`, `issuerUrl` and `metadataUrl`.** Older servers don't default them: without `grantType` the call fails with a database error, and without the URLs the login fails at `/oidc/auth` ("outbound IdP url is null/blank"). Google: `https://accounts.google.com` and `https://accounts.google.com/.well-known/openid-configuration`. Microsoft: `https://login.microsoftonline.com/common/v2.0` (or `/{tenant-id}/v2.0`) and `{issuerUrl}/.well-known/openid-configuration`. The MCP tool fills these in itself.

> **Provider token vault (optional, opt-in).** `returnProviderTokens`/`storeProviderTokens` let your backend obtain the *external* provider's own token (e.g. call Google/Microsoft APIs as the user):
> - `returnProviderTokens` → the provider token comes back inline in the `authorization_code` `/oidc/token` response (see Token Endpoint; requires S256 PKCE or a client secret).
> - `storeProviderTokens` → the provider token is stored encrypted and retrieved/auto-refreshed later via the **token-exchange** grant. Enabling this AUTO-requests a provider refresh token — you do **not** add `offline_access` yourself.
> - `providerScopes` is only needed to request extra *provider API* scopes (e.g. `https://www.googleapis.com/auth/calendar.readonly`); it is admin-set on the connection and never passed by the login app.

### Access Keys

| Method | Path | Auth | Notes |
|---|---|---|---|
| POST | `users/{userId}/access-keys` | M+R | No body. Returns `accessKeyId` + `accessKeySecret` (secret shown once). |
| GET | `users/{userId}/access-keys` | M+R | secret nulled |
| GET | `access-keys/{accessKeyId}` | M+R | secret nulled |
| POST | `access-keys/{accessKeyId}/revoke` | M+R | Destructive; no DELETE |

A newly created access key gets `master_realm_manage` if created under a user in realm `master` of account `master`, and `realm_manage` if created under a user in realm `master` of any other account; in any other realm it gets **no role by default** and must be granted via `POST /resource-servers/{resourceServerId}/access-keys/{accessKeyId}/roles`.

### Resource Servers / Roles / Permissions

Resource servers are scoped to the **account**, not the realm (`POST /accounts/{accountId}/resource-servers`). Roles + permissions hang off a resource server. For per-tenant role isolation across realms in one account, plan resource-server ownership deliberately.

| Method | Path | Auth |
|---|---|---|
| POST / GET | `accounts/{accountId}/resource-servers` | M+R |
| GET / PUT | `resource-servers/{resourceServerId}` | M+R |
| POST / GET | `resource-servers/{resourceServerId}/roles` | M+R |
| PUT / DELETE | `roles/{roleId}` | M+R | DELETE removes the role and its user, access-key and permission assignments; users are kept. Older servers fail on both PUT and DELETE (duplicate key) |
| POST / GET | `resource-servers/{resourceServerId}/permissions` | M+R |
| PUT / DELETE | `permissions/{permissionId}` | M+R | DELETE removes the permission and its role links. Older servers fail on both PUT and DELETE |
| POST | `roles/{roleId}/permissions` | M+R |
| POST | `resource-servers/{resourceServerId}/realms/{realmId}/users/{userName}/roles` | M+R | assign roles to a user |
| POST | `resource-servers/{resourceServerId}/access-keys/{accessKeyId}/roles` | M+R | assign roles to an access key |

### Email / SMS config + templates, password policy

- Email config: `POST realms/{realmId}/email-configs` or `accounts/{accountId}/email-configs`; `PUT|DELETE email-configs/{id}`; `POST email-configs/test`; `GET .../email-configs/effective` (shows the realm→account→master fallback resolution).
- Email templates: `POST realms/{realmId}/email-types/{emailType}/email-templates` (or account-level); `PUT|DELETE email-templates/{id}`; `.../effective` variants.
- SMS: same shape under `sms-configs` / `sms-templates`.
- Password policy: `PUT realms/{realmId}/password-policy` (see Realm table).

All M+R. Full field lists are in the live OpenAPI spec.

## User Management API

All user endpoints require an admin token (from `client_credentials` grant above).

### Create User

```
POST /realms/{realmId}/users
Authorization: Bearer {admin-token}
Content-Type: application/json
```

**Required fields (local user):**
```json
{
  "firstName": "John",
  "email": "john@company.com",
  "userName": "john@company.com",
  "appClientId": "{app-client-uuid}"
}
```

**Common optional fields:**
```json
{
  "lastName": "Doe",
  "password": "{initial-password}",
  "orgRefId": "company-123",
  "userRefId": "user-456",
  "roles": [{ "roleName": "admin", "resourceServerName": "my-api" }]
}
```

**`appClientId` and the welcome notification:**
- Local users (`localIdp` omitted or `true`) → `appClientId` is REQUIRED (400 otherwise). A welcome notification is sent, built from the app client's registered URLs, unless `appHandlesNotification=true`.
- `password` in the body → validated against the realm policy, stored hashed, user is immediately active.
- Federated users (`localIdp: false`) → `appClientId` not needed, `userName` must equal `email`, no `password`, no notification; user is immediately active.

**Auto-generated fields — NEVER pass these:**
- `userId` — auto-generated UUID. Do NOT generate or pass a user ID.
- `realmId` — taken from the URL path parameter.
- `createdAt`, `updatedAt` — auto-generated timestamps.

**Query parameters:**
- `appHandlesNotification=true` — if set, nothing is sent and the invitation token is returned in the response's `notificationToken` field. Use this when the app wants to send its own welcome email.

### List Users

```
GET /realms/{realmId}/users
Authorization: Bearer {admin-token}
```

This endpoint has NO query parameters — it returns all users.

### Get User by Username

```
GET /realms/{realmId}/users/by-username/{userName}
Authorization: Bearer {admin-token}
```

### Update User

```
PUT /realms/{realmId}/users/{userName}
Authorization: Bearer {admin-token}
Content-Type: application/json

{ "firstName": "Jane", "lastName": "Updated" }
```

### Disable / Enable / Delete User

```
PUT /realms/{realmId}/users/{userName}/disable
PUT /realms/{realmId}/users/{userName}/enable
DELETE /realms/{realmId}/users/{userName}
Authorization: Bearer {admin-token}
```

**Delete requires a disabled user** ("User should be disabled" otherwise): disable first, then delete. A realm cannot be deleted while it still has users or app clients (foreign keys).

**Note:** User operations use `{userName}` in the path (typically the email), NOT a UUID.

**CRITICAL: `{userName}` MUST be URL-encoded** when used in URL paths. Emails contain `+`, `@`, `.` which are reserved/special characters in URLs. Without encoding, API calls will fail or hit the wrong resource.

| Raw userName | URL-encoded |
|---|---|
| `mahesh.oa+1@expeed.com` | `mahesh.oa%2B1%40expeed.com` |
| `john@company.com` | `john%40company.com` |

**Per language:**
- Java: `URLEncoder.encode(userName, StandardCharsets.UTF_8)`
- JavaScript/TypeScript: `encodeURIComponent(userName)`
- Python: `urllib.parse.quote(userName, safe="")`

---

## Forgot Password / Reset Password

### Forgot Password (trigger reset email)

```
POST /app-clients/{appClientId}/users/{userName}/forgot-password
```

**This is a PUBLIC endpoint — no authentication required.**

**CRITICAL:** The path includes BOTH `appClientId` AND `userName`. Not just email in a body.

There is a `/secured` variant (`POST /app-clients/{appClientId}/users/{userName}/forgot-password/secured`) that requires admin auth (Bearer token) and supports the `appHandlesNotification` query param (returns the reset token as a **plain-text** body instead of sending email, for apps that send their own branded email).

**Unknown user:** older servers return 500 `User not found`; after the admin-API fix release the public route returns 200 (no account enumeration) and `/secured` returns 404. Show the same "if the account exists, we sent an email" message for any non-200/400 response. A Google/Microsoft user returns 400 on `/secured`; on the public route, 400 on older servers and a silent 200 after the fix release (unknown, disabled and federated users all look the same).

**What this does:**
1. Generates a password reset token
2. Sends an email to the user with a reset link
3. The reset link URL is built from the `reset_password` app URL registered for the app client, or the hosted reset page if none is registered

**For phone-based reset:**
```
POST /app-clients/{appClientId}/phone-prefix/{phonePrefix}/phone/{phone}/forgot-password
```

### Reset Password (user submits new password)

```
POST /reset-password
Content-Type: application/json

{
  "token": "{reset-token-from-email-link}",
  "password": "{new-password}",
  "appClientId": "{app-client-uuid}"
}
```

**All three fields are required.** The user is resolved from the token, which is single-use; a password that fails the realm policy is rejected without consuming the token. On success the user's sessions are cleared.

### Set Password (MCP only)

**There is NO HTTP endpoint to set an existing user's password.** Use the MCP tool `apptorID_set_password` instead. (A new user's initial password can be passed as `password` in `POST /realms/{realmId}/users`.)

If the developer's app needs to set a password programmatically via HTTP, use the reset-password flow: trigger forgot-password (or the `/secured` variant with `appHandlesNotification=true` to get the token), then call `POST /reset-password` with the token.

---

## Reset Password Page

The reset link is `{reset page}?token={reset-token}&client_id={app-client-id}`. The reset page is either:

- **apptorID's hosted reset page** — `https://{realm-authDomain}/hosted-login/?token=...&client_id=...`. It validates the token, enforces the realm's password policy and sets the password. If no `reset_password` URL is registered, apptorID builds reset and welcome email links against this page automatically.
- **The app's own page** — register it first, then the page reads `token` and `client_id`, shows a "new password" form, calls `POST /reset-password`, and on success redirects to the app's login page.

**The reset token is opaque — never decode it.** Treat it as a random string: no username, expiry or client id can be read from it. To show the user's name or check the link before showing the form, call:

```
GET /api/hosted-login/reset-config?token={token}&client_id={client-id}
```

No auth. Always HTTP 200; the body says whether the link is usable:
- valid → `{"valid": true, "userName": "...", "passwordPolicy": {...}, "branding": {...}, "realmId": "...", "clientId": "..."}`
- expired, used, unknown client or inactive user → `{"valid": false, "errorMessage": "..."}` with no `userName`

`userName` in this response comes with apptor-auth-server PR #317; confirm it in the live OpenAPI spec before relying on it, and fall back to not showing a name when it is absent.

**App URL types to register via MCP (`apptorID_add_app_urls`), own page only:**
- `reset_password` → `https://myapp.com/reset-password`

`post_reset_password` is accepted but nothing in apptorID reads it, so don't register it.

## Who Sends Notification Emails

| | apptorID sends | App sends (`appHandlesNotification=true`) |
|---|---|---|
| Transport | SMTP only (SendGrid/SES via SMTP relay only) | Any provider the app chooses |
| Templates | Stored in apptorID | Owned by the app |
| Forgot password | Public `.../forgot-password` | `.../forgot-password/secured` → returns reset token |
| Welcome / invitation | Sent on user creation | `POST /realms/{realmId}/users?appHandlesNotification=true`, then `.../resend-invitation/secured` → returns token |
| SMS reset | apptorID sends OTP | `.../phone/{phone}/forgot-password/secured` → returns OTP; complete with `POST /reset-password-by-otp` |
| Login page | Hosted login OK | **Client-hosted login required** (`/oidc/pre-authorize`) |

The `/secured` endpoints need an admin Bearer token (`realm_manage` / `master_realm_manage`). The hosted login page always shows its own "Forgot password?" link, which always makes apptorID send the email — there is no setting to hide it or redirect it — so an app that must own its emails must host its own login page.

---

## OIDC Endpoints

### Discovery

```
GET /.well-known/openid-configuration
```

### Authorization (start login flow)

```
GET /oidc/auth?response_type=code&client_id={uuid}&redirect_uri={url}&scope=openid%20email%20profile&state={random}&nonce={random}&code_challenge={challenge}&code_challenge_method=S256
```

### Hosted Login

```
GET /hosted-login/
```

The hosted login is a React SPA. The login URL to register is `https://{realm-url}/hosted-login/`.

**Available pages in hosted login:** Login (default), Forgot password (`?view=forgot`, sends the email from apptorID) and Reset password (any URL with `?token=...&client_id=...`). No signup or profile pages — the app must build these.

### Pre-Authorize (client-hosted login — LOCAL username/password ONLY)

```
POST /oidc/pre-authorize
Content-Type: application/x-www-form-urlencoded

username={string}&password={string}
```

Query params: `client_id`, `redirect_uri`, `scope`, `response_type=code`, `state`, `nonce`, `code_challenge`, `code_challenge_method`

Returns `{ "preAuthToken": "...", "state": "...", "expiresIn": 60 }`. The `preAuthToken` is passed to `/oidc/auth?...&preAuthToken={token}` to skip the login page. The token is single-use and expires after 60 seconds.

- `scope` must contain `openid` here **and** on `/oidc/auth`; both return 400 without it.
- An unregistered `redirect_uri` returns 400 `invalid_redirect_url`. Matching ignores case but not `http` vs `https` or a trailing `/`.
- Credential failures are always 401: `{"error":"invalid_credentials"}` (wrong password, disabled user, Google/Microsoft-only user) or `{"error":"password_setup_incomplete"}` (user has not set a password yet). There is no 403 or 429.

> **`pre-authorize` is for the LOCAL identity provider only.** For Microsoft / Google / other IdP-based logins, do NOT call `pre-authorize`. Instead, redirect the user's browser directly to `GET /oidc/auth?...&provider_id={microsoft|google}` and let apptorID hand off to the upstream IdP. Trying to "pre-authorize" a social login will not work — there are no local credentials to validate.

### Logout

```
GET /oidc/logout?id_token_hint={id_token}&post_logout_redirect_uri={url}&state={state}
```

### Custom Token — not recommended (current limitation)

`POST /oidc/custom-token` adds extra form fields as claims to an apptorID-signed token, but a refresh (`/oidc/token`, `grant_type=refresh_token`) rebuilds claims from the database and drops them, and `/oidc/custom-token` does not accept `refresh_token`. Do not build on it. If the app needs its own claims, verify apptorID's tokens at the callback and mint the app's own session/JWT.

### Revoke Token

```
POST /oidc/revoke
Content-Type: application/x-www-form-urlencoded

refresh_token={token}&token_type_hint=refresh_token
```

Send both parameters: older servers reject a request without `token_type_hint` with a Java error message. The parameter is `refresh_token`, not RFC 7009's `token`. An unknown token returns 200.

### JWKS (public keys for JWT verification)

```
GET /oidc/jwks
```

### UserInfo

```
GET /oidc/userinfo
Authorization: Bearer {access-token}
```

---

## Identity Provider (IdP) Configuration

apptorID currently supports three identity providers per app client: `local` (username/password), `microsoft` (Azure AD / Entra ID), and `google`. Configure via MCP `apptorID_add_idp_connection` (see `skills/manage/SKILL.md` for the full field-by-field guide) — these are the protocol-level details:

### Provider-specific required fields

| `providerId` | Mandatory fields | Notes |
|---|---|---|
| `local` | _(none beyond `clientId` + `providerId`)_ | Built-in username/password |
| `microsoft` | `externalClientId`, `externalClientSecret` | `issuerUrl`/`metadataUrl` default to the multi-tenant `https://login.microsoftonline.com/common/v2.0` endpoints. For a single tenant, pass `issuerUrl=https://login.microsoftonline.com/{tenant-id}/v2.0` and `metadataUrl={issuerUrl}/.well-known/openid-configuration` |
| `google` | `externalClientId`, `externalClientSecret` | `issuerUrl`/`metadataUrl` default to Google's |

The MCP tool `apptorID_add_idp_connection` does **not** reject a missing `externalClientId`/`externalClientSecret` — it stores an empty value and the login then fails at the provider. Always pass both for `microsoft`/`google`. There is no `tenantId` parameter. The tool's response contains `idpConnectionId`, `providerId`, `appClientId` and the vault flags, not the URLs — read them back with `apptorID_get_idp_connections`.

**Optional vault fields (any external `microsoft`/`google`/OIDC provider):** `returnProviderTokens`, `storeProviderTokens`, `providerScopes` — see the "Provider token vault" note under `IdpConnection` DTO fields. Use them only when your backend needs the external provider's own token (e.g. call the provider's APIs as the user); omit them for plain SSO.

### Redirect URI to register in Azure / Google

apptorID does NOT return this URI in any tool response. For each IdP you configure, register this URI in the upstream provider's app/registration:

```
https://{realm-auth-domain}/oidc/callback/{providerId}
```

Examples:
- Microsoft (Azure portal → App registrations → Authentication → Web → Redirect URIs): `https://acme-x1y2.sandbox.auth.apptor.io/oidc/callback/microsoft`
- Google (Cloud Console → Credentials → OAuth 2.0 Client → Authorized redirect URIs): `https://acme-x1y2.sandbox.auth.apptor.io/oidc/callback/google`

### Starting an IdP login flow

To initiate Microsoft/Google login (rather than local password), redirect the browser to:

```
GET /oidc/auth?response_type=code
              &client_id={uuid}
              &redirect_uri={app-callback}
              &scope=openid email profile
              &state={random}
              &nonce={random}
              &code_challenge={challenge}
              &code_challenge_method=S256
              &provider_id={microsoft|google}
```

apptorID will redirect the user to the upstream IdP. After successful upstream auth, the user lands back at apptorID's `/oidc/callback/{providerId}`, then is redirected to your app's `redirect_uri` with `?code=...&state=...`.

Errors raised by `/oidc/auth` itself (e.g. `unsupported_response_type`, `unauthorized_client`) are 302'd back to the `redirect_uri` with `?error=...&state=...`, but only when that `redirect_uri` is registered for the client; otherwise the error is returned directly. Your callback page should check for `?error=` before attempting code exchange. When the **upstream IdP** rejects the login (user cancels, consent denied), apptorID's `/oidc/callback/{providerId}` returns HTTP 500 "Failed to authenticate" and does not redirect back to the app.

---

## App URL Types

Register via MCP (`apptorID_add_app_urls`):

| Type | Purpose | Example |
|---|---|---|
| `login` | Hosted login page URL | `https://{realm-url}/hosted-login/` |
| `logout` | Post-logout redirect | `https://myapp.com/` |
| `redirect` | OAuth callback URL | `https://myapp.com/auth/callback` |
| `reset_password` | The app's own password reset page. If unregistered, links use the hosted reset page | `https://myapp.com/reset-password` |
| `post_reset_password` | Accepted but unused by apptorID; don't register it | — |

---

## JWT Token Claims

Standard claims: `sub` (the userName, not a UUID), `iss`, `aud`, `exp`, `iat`, `email`, `name`, `given_name`, `family_name`, `nonce` (ID token), `scope`

Custom claims: `user_name`, `app_client_id`, `roles`, `account_id`, `resource_server_id`, `product_owner_ref_id`, plus (present only when set):
- `org_id` → value of `orgRefId` set during user creation
- `user_id` → value of `userRefId` set during user creation

There is no `realm_id` claim.

---

## Quick Reference — Common Mistakes to Avoid

1. **NEVER use camelCase in form-encoded params.** It's `access_key_id`, NOT `accessKeyId`.
2. **NEVER pass a `userId` in user creation.** It's auto-generated.
3. **The hosted login HAS a reset password page.** Build your own only for custom UI, and register it as `reset_password`.
4. **NEVER call forgot-password without `appClientId` in the path.** The endpoint is `/app-clients/{appClientId}/users/{userName}/forgot-password`.
5. **ALWAYS use the created realm URL** for integration code, not the master URL.
6. **ALWAYS register app URLs** (`redirect`, `login`, `logout`, plus `reset_password` when the app has its own reset page) before the flows that need them.
7. **User endpoints use `{userName}` in the path**, not a UUID. userName is typically the email.
8. **ALWAYS pass `externalClientId` / `externalClientSecret` to `apptorID_add_idp_connection` for microsoft/google** — the tool does not reject them missing; login fails later instead. For a single Microsoft tenant, pass tenant-specific `issuerUrl` / `metadataUrl` (default is `common`). Verify with `apptorID_get_idp_connections`.
9. **NEVER use `pre-authorize` for Microsoft/Google login.** It is local-username/password only. For IdP logins, redirect directly to `/oidc/auth?...&provider_id={microsoft|google}`.
10. **ALWAYS register the IdP redirect URI in Azure / Google** before testing the flow: `https://{realm-auth-domain}/oidc/callback/{providerId}`. apptorID does not surface this URI in any tool response.
