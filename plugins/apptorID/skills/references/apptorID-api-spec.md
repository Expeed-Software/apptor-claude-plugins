# apptorID API Specification

> **This is the SINGLE SOURCE OF TRUTH for all apptorID API calls.** Every skill MUST read this file before writing any integration code. Do NOT guess parameter names, endpoint paths, or URL patterns. If it's not in this file, check the OpenAPI spec at `/swagger-ui/` on the auth server.

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

### Admin API endpoints — ANY URL works (security is token-based)

Admin operations validate the Bearer token's account_id, NOT the Host header. You can call these from either the master URL or the created realm URL — both work. **Use the created realm URL for consistency.**

| Endpoint | URL | Auth |
|---|---|---|
| `POST /oidc/token` (client_credentials + access_key) | **Any** — access key is validated globally | None (generates token) |
| `POST /realms/{realmId}/users` (create user) | **Any** — realmId is in the path | Bearer admin token |
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

### Pre-Authorize (client-hosted login)

```
POST /oidc/pre-authorize
Content-Type: application/x-www-form-urlencoded

username={string}&password={string}
```

Query params: `client_id`, `redirect_uri`, `scope`, `response_type=code`, `state`, `nonce`, `code_challenge`, `code_challenge_method`

Returns a `preAuthToken` that can be passed to `/oidc/auth?preAuthToken={token}` to skip the login page.

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
