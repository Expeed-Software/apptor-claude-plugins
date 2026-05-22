# apptorID API Specification

> **The live OpenAPI spec is the source of truth — this file is a curated quick reference.** Before writing integration code, fetch `https://{realm-authDomain}/swagger/apptor-auth-server-0.5.yml` (or browse `/swagger-ui/`). This file covers the endpoints the plugin uses most, verified against the server source — but when the two disagree, **the live spec wins** and you should flag the drift. Do NOT guess parameter names, endpoint paths, or URL patterns; fetch, then read.

## OpenAPI / Swagger

The auth server has a live OpenAPI spec:
- **Swagger UI:** `https://{any-realm-url}/swagger-ui/`
- **OpenAPI YAML:** `https://{any-realm-url}/swagger/apptor-auth-server-0.5.yml`

If you're unsure about any endpoint, parameter, or response format — **check the Swagger UI first.**

## Mandatory vs Optional Fields — Quick Reference

### User Creation (`POST /realms/{realmId}/users`)
| Field | Required? | Notes |
|---|---|---|
| `firstName` | **MANDATORY** | |
| `email` | **MANDATORY** | |
| `accountId` | **MANDATORY** | Account UUID |
| `appClientId` | **MANDATORY if no password** | Needed for welcome email links. Optional if password is provided in the creation request. |
| `lastName` | optional | |
| `userName` | optional | Defaults to email if not provided |
| `orgRefId` | optional | Maps to `org_id` JWT claim. Include if app uses org-level tenancy. |
| `userRefId` | optional | Maps to `user_id` JWT claim. Include if app needs a user external ID. |
| `roles` | optional | Array of `{ "id": "role-uuid" }` |
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
| `token` | **MANDATORY** | From email link query param |
| `password` | **MANDATORY** | New password |
| `userName` | **MANDATORY** | User's username/email |
| `appClientId` | **MANDATORY** | From email link query param `client_id` |

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

---

## Onboarding / Admin API (realm, app client, URLs, IdP, access keys, RBAC)

These are the endpoints a SaaS app calls at **customer-onboarding time** (Model A) or during dev setup. All require an admin Bearer token from the `client_credentials` grant. Auth column: `M+R` = role `master_realm_manage` OR `realm_manage`; `M` = `master_realm_manage` only. A customer's Apptor-issued access key carries `realm_manage` scoped to its account — it can do every `M+R` operation within its own account and nothing in another account.

> **There is NO account-create endpoint in scope.** Apptor provisions accounts and hands over the access key. Do not attempt `POST /accounts` — it requires `master_realm_manage`, which customer keys do not have.

> **Always cross-check against the live OpenAPI** at `/swagger/apptor-auth-server-0.5.yml`. The list below is verified against the server source but the live spec is authoritative.

### Realm

| Method | Path | Auth | Notes |
|---|---|---|---|
| POST | `accounts/{accountId}/realms` | M+R | Body = `Realm` DTO. `accountId` comes from your admin token's `account_id` claim. Returns `realmId`, `authDomain`. |
| GET | `accounts/{accountId}/realms` | M+R | List realms in the account |
| GET | `realms/{realmId}` | M+R | Includes password-policy fields |
| DELETE | `realms/{realmId}` | M+R | Cascade delete |
| PUT | `realms/{realmId}/password-policy` | M+R | **Password-policy update ONLY** (despite taking a full `Realm` body, only the policy fields are persisted). There is no general realm-update HTTP endpoint. |
| GET / PUT | `realms/{realmId}/branding` | M+R | `BrandingConfig` |

**`Realm` DTO fields:** `realmName` (NOT `name`), `authDomain`, `accountId`, `productOwnerRefId`, `defaultPasswordPolicy` (required on create), `passwordMinLength`, `passwordRequiresNumber`, `passwordRequiresSpecialChar`, `passwordRequiresUpperCase`, `passwordRequiresLowerCase`.

### App Client

| Method | Path | Auth | Notes |
|---|---|---|---|
| POST | `realms/{realmId}/app-clients` | M+R | Body = `AppClient`. Returns `clientId` + `clientSecret` (secret shown once). |
| PUT | `realms/{realmId}/app-clients` | M+R | Body's `clientId` selects which one |
| GET | `realms/{realmId}/app-clients` | M+R | |
| GET | `app-clients/{clientId}` | M+R | |
| DELETE | `app-clients/{appClientId}` | M+R | |
| POST | `app-clients/{clientId}/reset-secret` | M+R | Rotates secret; new secret in response |
| POST | `app-clients/{appClientId}/resource-servers/{resourceServerName}` | M+R | Link one RS **by name** |
| PUT | `app-clients/{appClientId}/resource-servers` | M+R | Replace all RS links; body = `List<String>` of names |

**`AppClient` DTO fields:** `name`, `appType` (`spa`/`web`/`mobile`/`m2m`), `realmId`, `idpClient` (**always send `false`**), `multiTenant` (**always send `false`** — no-op server-side), `accessTokenExpirationInMin`, `idTokenExpirationInMin`, `refreshTokenExpirationInDays`, `requiresMfa`, `resourceServerNames`, `passwordTokenExpiryInSeconds`, `otpValidityInSeconds`.

### App URLs

`UrlType` values: `login`, `logout`, `redirect`, `reset_password`, `post_reset_password`.

| Method | Path | Auth | Notes |
|---|---|---|---|
| POST | `app-clients/{clientId}/url-type/{urlType}/app-urls` | M+R | **URL type is mid-path**, not in the body. Body = `List<AppUrl>` where each `AppUrl` = `{ "type": "...", "url": "...", "appClientId": "..." }`. |
| GET | `app-clients/{clientId}/app-urls` | M+R | |
| DELETE | `app-clients/{clientId}/app-urls/{urlType}/url/{url}` | M+R | URL value in path (URL-encode it). Note the path ordering differs from POST. There is no PUT — delete then re-create. |

**Register `login`, `redirect`, `logout` BEFORE testing login.** See hosted-login fallback below.

### Identity Provider Connections

| Method | Path | Auth | Notes |
|---|---|---|---|
| GET | `identity-providers` | authenticated | Global list of supported providers |
| POST | `app-clients/{clientId}/idp-connections` | M+R | Body = `IdpConnection` |
| GET | `app-clients/{clientId}/idp-connections` | M+R | |
| GET | `idp-connections/{idpConnectionId}` | M+R | |
| PUT | `app-clients/{clientId}/idp-connections/{idpConnectionId}` | M+R | |
| DELETE | `app-clients/{clientId}/idp-connections/{idpConnectionId}` | M+R | |

**`IdpConnection` DTO fields:** `providerId` (`local`/`google`/`microsoft`), `clientId` (the EXTERNAL provider's OAuth client id), `clientSecret` (external secret), `issuerUrl`, `metadataUrl`, `grantType`, `authUrl`. See "Identity Provider Configuration" for required-field rules and the Microsoft tenant URL handling.

### Access Keys

| Method | Path | Auth | Notes |
|---|---|---|---|
| POST | `users/{userId}/access-keys` | M+R | No body. Returns `accessKeyId` + `accessKeySecret` (secret shown once). |
| GET | `users/{userId}/access-keys` | M+R | secret nulled |
| GET | `access-keys/{accessKeyId}` | M+R | secret nulled |
| POST | `access-keys/{accessKeyId}/revoke` | M+R | Destructive; no DELETE |

A newly created access key gets `master_realm_manage` only if created under a user in realm `master` of account `master`; in any other realm it gets **no role by default** and must be granted via `POST /resource-servers/{resourceServerId}/access-keys/{accessKeyId}/roles`.

### Resource Servers / Roles / Permissions

Resource servers are scoped to the **account**, not the realm (`POST /accounts/{accountId}/resource-servers`). Roles + permissions hang off a resource server. For per-tenant role isolation across realms in one account, plan resource-server ownership deliberately.

| Method | Path | Auth |
|---|---|---|
| POST / GET | `accounts/{accountId}/resource-servers` | M+R |
| GET / PUT | `resource-servers/{resourceServerId}` | M+R |
| POST / GET | `resource-servers/{resourceServerId}/roles` | M+R |
| PUT / DELETE | `roles/{roleId}` | M+R |
| POST / GET | `resource-servers/{resourceServerId}/permissions` | M+R |
| PUT / DELETE | `permissions/{permissionId}` | M+R |
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

**Required fields:**
```json
{
  "firstName": "John",
  "email": "john@company.com",
  "accountId": "{account-uuid}"
}
```

**Common optional fields:**
```json
{
  "lastName": "Doe",
  "userName": "john@company.com",
  "orgRefId": "company-123",
  "userRefId": "user-456",
  "appClientId": "{app-client-uuid}",
  "roles": [{ "id": "role-uuid" }]
}
```

**When is `appClientId` needed?**
- User created WITHOUT password → `appClientId` is REQUIRED. The system sends a welcome/invitation email and needs the app client's registered URLs (login URL, reset password URL) to build the email links.
- User created WITH password (via MCP `apptorID_set_password` tool — there is no HTTP endpoint for this) → `appClientId` is optional. User is immediately active, no email sent.

**Auto-generated fields — NEVER pass these:**
- `userId` — auto-generated UUID. Do NOT generate or pass a user ID.
- `realmId` — taken from the URL path parameter.
- `createdAt`, `updatedAt` — auto-generated timestamps.

**Query parameters:**
- `appHandlesNotification=true` — if set, returns the invitation token in the response instead of sending email. Use this when the app wants to send its own welcome email.

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

There is a `/secured` variant (`POST /app-clients/{appClientId}/users/{userName}/forgot-password/secured`) that requires admin auth (Bearer token) and supports the `appHandlesNotification` query param (returns the reset token in the response instead of sending email, for apps that send their own branded email).

**What this does:**
1. Generates a password reset token
2. Sends an email to the user with a reset link
3. The reset link URL is built from the `reset_password` app URL registered for the app client

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
  "userName": "{username}",
  "appClientId": "{app-client-uuid}"
}
```

**All fields are required.**

### Set Password (MCP only)

**There is NO HTTP endpoint for set-password.** Use the MCP tool `apptorID_set_password` instead.

If the developer's app needs to set a password programmatically via HTTP, use the reset-password flow: trigger forgot-password (or the `/secured` variant with `appHandlesNotification=true` to get the token), then call `POST /reset-password` with the token.

---

## Reset Password Page — IMPORTANT

**The auth server's hosted login does NOT have a working reset password page at `/hosted-login/reset-password`.**

The developer's app MUST provide its own reset password page. The flow is:

1. App calls forgot-password API → apptorID sends email to user
2. Email contains a link to the `reset_password` URL registered for the app client
3. **That URL MUST point to a page IN THE DEVELOPER'S APP** (e.g., `https://myapp.com/reset-password`)
4. The page receives `?token={reset-token}&client_id={app-client-id}` as query parameters
5. The page shows a "new password" form
6. On submit, the page calls `POST /reset-password` with the token + new password + userName + appClientId
7. On success, redirect to the `post_reset_password` URL registered for the app client

**App URL types to register via MCP (`apptorID_add_app_urls`):**
- `reset_password` → `https://myapp.com/reset-password` (the app's own page)
- `post_reset_password` → `https://myapp.com/login` (redirect after success)

**If `reset_password` URL is not registered**, the email link will either fail or point to a non-existent page on the auth server. Always register it.

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

**Available pages in hosted login:** Login page only. The hosted login does NOT provide pages for reset-password, signup, or profile management. The app must build these.

### Pre-Authorize (client-hosted login — LOCAL username/password ONLY)

```
POST /oidc/pre-authorize
Content-Type: application/x-www-form-urlencoded

username={string}&password={string}
```

Query params: `client_id`, `redirect_uri`, `scope`, `response_type=code`, `state`, `nonce`, `code_challenge`, `code_challenge_method`

Returns a `preAuthToken` that can be passed to `/oidc/auth?preAuthToken={token}` to skip the login page.

> **`pre-authorize` is for the LOCAL identity provider only.** For Microsoft / Google / other IdP-based logins, do NOT call `pre-authorize`. Instead, redirect the user's browser directly to `GET /oidc/auth?...&provider_id={microsoft|google}` and let apptorID hand off to the upstream IdP. Trying to "pre-authorize" a social login will not work — there are no local credentials to validate.

### Logout

```
GET /oidc/logout?id_token_hint={id_token}&post_logout_redirect_uri={url}&state={state}
```

### Revoke Token

```
POST /oidc/revoke
Content-Type: application/x-www-form-urlencoded

refresh_token={token}&token_type_hint=refresh_token
```

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
| `microsoft` | `externalClientId`, `externalClientSecret` | Pass `tenantId` to single-tenant; defaults to `common` (multi-tenant) when omitted |
| `google` | `externalClientId`, `externalClientSecret` | |

The MCP tool `apptorID_add_idp_connection` rejects the call with `IllegalArgumentException` if a required field is missing for `microsoft` or `google`. For Microsoft, the server builds `issuerUrl` / `metadataUrl` from the supplied `tenantId` (or `common` if omitted), so there is no `{tenantid}`-style placeholder in the stored value. The tool's response includes the resolved `issuerUrl` and `metadataUrl`.

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

When the upstream IdP rejects the request, apptorID now 302s the browser back to the original OAuth2 `redirect_uri` with `?error=...&error_description=...&state=...` per RFC 6749 §4.1.2.1. Your callback page should check for `?error=` before attempting code exchange — same pattern you'd use for any standards-compliant OAuth2 provider. If `redirect_uri` cannot be recovered (unknown state), apptorID falls back to HTTP 500.

---

## App URL Types

Register via MCP (`apptorID_add_app_urls`):

| Type | Purpose | Example |
|---|---|---|
| `login` | Hosted login page URL | `https://{realm-url}/hosted-login/` |
| `logout` | Post-logout redirect | `https://myapp.com/` |
| `redirect` | OAuth callback URL | `https://myapp.com/auth/callback` |
| `reset_password` | Password reset page (IN THE APP) | `https://myapp.com/reset-password` |
| `post_reset_password` | Redirect after password reset | `https://myapp.com/login` |

---

## JWT Token Claims

Standard claims: `sub`, `iss`, `aud`, `exp`, `iat`, `email`, `name`, `roles`

Custom claims from orgRefId/userRefId:
- `org_id` → value of `orgRefId` set during user creation
- `user_id` → value of `userRefId` set during user creation

---

## Quick Reference — Common Mistakes to Avoid

1. **NEVER use camelCase in form-encoded params.** It's `access_key_id`, NOT `accessKeyId`.
2. **NEVER pass a `userId` in user creation.** It's auto-generated.
3. **NEVER assume hosted login has a reset password page.** Build your own.
4. **NEVER call forgot-password without `appClientId` in the path.** The endpoint is `/app-clients/{appClientId}/users/{userName}/forgot-password`.
5. **ALWAYS use the created realm URL** for integration code, not the master URL.
6. **ALWAYS register app URLs** (`reset_password`, `post_reset_password`, `redirect`, `login`, `logout`) before the flows that need them.
7. **User endpoints use `{userName}` in the path**, not a UUID. userName is typically the email.
8. **`apptorID_add_idp_connection` enforces required fields for microsoft/google** — the call fails if `externalClientId` / `externalClientSecret` are missing. For Microsoft, pass `tenantId` so the issuer/metadata URLs are scoped to your tenant (defaults to `common` multi-tenant otherwise). Verify the response's resolved `issuerUrl` / `metadataUrl`.
9. **NEVER use `pre-authorize` for Microsoft/Google login.** It is local-username/password only. For IdP logins, redirect directly to `/oidc/auth?...&provider_id={microsoft|google}`.
10. **ALWAYS register the IdP redirect URI in Azure / Google** before testing the flow: `https://{realm-auth-domain}/oidc/callback/{providerId}`. apptorID does not surface this URI in any tool response.
