# apptorID OIDC Protocol Knowledge

Stack-agnostic reference for implementing apptorID OAuth2/OIDC integration in any language.

## Endpoints

All endpoints are relative to the realm's auth domain URL (e.g., `https://acme-x1y2.sandbox.auth.apptor.io`).

> **The `Host` header is load-bearing.** The server resolves the realm for every OIDC endpoint (`/oidc/auth`, `/oidc/token`, `/oidc/login`, `/oidc/jwks`, `/.well-known/openid-configuration`, etc.) from the inbound `Host` header — except `/oidc/userinfo` and `/oidc/logout`, which work off the bearer token / session. Discovery rebuilds every URL from the inbound host, so each realm's discovery returns that realm's URLs. **Any reverse proxy in front of apptorID MUST preserve the original `Host` header**, or realm resolution breaks and you get realm-not-found errors.

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/.well-known/openid-configuration` | GET | OIDC discovery — returns all endpoint URLs |
| `/oidc/auth` | GET | Authorization — initiates login flow |
| `/oidc/token` | POST | Token exchange — code for tokens, refresh |
| `/oidc/userinfo` | GET | User profile — requires Bearer token |
| `/oidc/jwks` | GET | Public keys — for JWT signature validation |
| `/oidc/logout` | GET | RP-initiated logout |
| `/oidc/revoke` | POST | Token revocation |
| `/oidc/pre-authorize` | POST | Client-hosted login — validate credentials |
| `/oidc/login` | POST | Hosted login — form submission |
| `/api/hosted-login/config` | GET | Hosted login page configuration |

## Authorization Code Flow with PKCE

This is the standard flow for web apps, SPAs, and mobile apps.

```
1. Generate code_verifier
   - 64 random bytes → base64url encoded
   - Store in session (server-side) or sessionStorage (SPA)

2. Compute code_challenge
   - SHA-256 hash of code_verifier → base64url encoded

3. Generate state
   - 32 random bytes → base64url encoded
   - Store in session — used to prevent CSRF on callback

4. Generate nonce
   - 32 random bytes → base64url encoded
   - Store in session — used to prevent replay attacks

5. Redirect user to authorization endpoint:
   {realm}/oidc/auth?
     client_id={id}
     &redirect_uri={callback_url}
     &response_type=code
     &scope=openid email profile
     &state={state}
     &nonce={nonce}
     &code_challenge={challenge}
     &code_challenge_method=S256

6. apptorID authenticates the user (hosted or client-hosted login)

7. apptorID redirects back:
   {callback_url}?code={authorization_code}&state={state}

8. Validate state matches stored value (CSRF check)

9. Exchange code for tokens:
   POST {realm}/oidc/token
   Content-Type: application/x-www-form-urlencoded

   grant_type=authorization_code
   &code={authorization_code}
   &client_id={id}
   &client_secret={secret}
   &redirect_uri={callback_url}
   &code_verifier={verifier}

10. Receive tokens:
    {
      "access_token": "eyJhbGci...",
      "id_token": "eyJhbGci...",
      "refresh_token": "rt-abc123...",
      "expires_in": 3600,
      "token_type": "Bearer"
    }
```

## Pre-Authorize Flow (Client-Hosted Login)

When the app hosts its own login page instead of using apptorID's hosted login:

```
1. App initiates auth flow:
   GET {realm}/oidc/auth?
     client_id={id}
     &redirect_uri={callback}
     &response_type=code
     &scope=openid email profile
     &state={state}
     &code_challenge={challenge}
     &code_challenge_method=S256
     &login_uri={app_login_page_url}

2. apptorID redirects to the app's login page:
   {app_login_page_url}?request_id={request_id}

3. App's login page collects username + password

4. App calls pre-authorize:
   POST {realm}/oidc/pre-authorize
   Content-Type: application/x-www-form-urlencoded

   username={user}
   &password={pass}
   &request_id={request_id}

5. Response:
   { "preAuthToken": "<uuid>", "state": "{state}", "expiresIn": 60 }

6. App redirects to:
   {realm}/oidc/auth?request_id={request_id}&preAuthToken={pat-xyz}

7. apptorID validates the preAuthToken, issues auth code, redirects to callback

8. Continue with standard token exchange (steps 8-10 above)
```

## Social Login Flow (Google, Microsoft)

```
1. User clicks "Sign in with Google" on the login page

2. App redirects to:
   {realm}/oidc/auth?
     provider_id=google
     &request_id={request_id}
     &client_id={id}
     &redirect_uri={callback}
     &response_type=code
     &scope=openid email profile
     &state={state}
     &code_challenge={challenge}
     &code_challenge_method=S256

3. apptorID redirects to Google's OAuth2 consent screen

4. User authenticates with Google

5. Google redirects back to apptorID's internal callback

6. apptorID maps Google claims to internal user (auto-creates if needed)

7. apptorID redirects to app's callback with auth code

8. Continue with standard token exchange
```

## Token Exchange: Client Secret vs PKCE

apptorID supports two modes for exchanging an authorization code for tokens:

**Mode 1: Client Secret (backend apps)**
```
POST {realm}/oidc/token
  grant_type=authorization_code
  code={code}
  client_id={id}
  client_secret={secret}
  redirect_uri={callback}
```

Use when: the app has a backend server that can securely store client_secret.
The callback URL is a BACKEND route — the browser never sees the client_secret.

**Mode 2: PKCE (pure SPAs, no backend)**
```
POST {realm}/oidc/token
  grant_type=authorization_code
  code={code}
  client_id={id}
  code_verifier={verifier}
  redirect_uri={callback}
```

Use when: no backend server exists. The browser handles the token exchange directly.
client_secret is NOT sent — the code_verifier proves the caller is the same one who started the flow.

**Rule:** If the project has a backend → use client_secret. If pure SPA → use PKCE.
Never use both. Never send client_secret from the browser.

## Token Refresh

**The `refresh_token` grant requires `client_secret`** — a public client (pure SPA, no secret) cannot refresh; it re-runs the authorization flow instead (silent while the apptorID session is alive).

```
POST {realm}/oidc/token
Content-Type: application/x-www-form-urlencoded

grant_type=refresh_token
&refresh_token={refresh_token}
&client_id={id}
&client_secret={secret}

Response:
{
  "access_token": "new-eyJhbGci...",
  "id_token": "new-eyJhbGci...",
  "refresh_token": "new-rt-...",    ← always reissued; the presented (old) token is single-use and is revoked on rotation
  "expires_in": 3600
}
```

> **Refresh token behavior (single-use rotation + reuse detection):** every refresh mints a NEW refresh token AND atomically revokes the one you presented — a refresh token can be spent exactly once. Store only the newest refresh token and drop the old one immediately. Replaying an already-rotated (revoked) token is treated as compromise: the server revokes the entire **session family** (every token descended from that login) and rejects the request with `invalid_grant`.
>
> Each fresh login starts its own family, so the same user can hold multiple concurrent sessions with the same app client (different devices/browsers) — bounded by the app client's optional `maxConcurrentSessions` cap (the least-recently-used session is evicted when the cap is exceeded). A password change or account deactivation revokes ALL of the user's refresh tokens. You can still explicitly revoke via `POST /oidc/revoke` or `GET /oidc/logout` (logout ends every session for that user + app client).

## Provider Tokens (RFC 8693 Token Exchange)

Distinct from the code→token exchange above. When an IdP connection has `returnProviderTokens` / `storeProviderTokens` enabled, apptorID can hand your backend the **external provider's own** token (e.g. to call Google/Microsoft APIs as the user).

- **Inline at login** (`returnProviderTokens`): the `authorization_code` `/oidc/token` response also carries a `provider_tokens` object (`access_token`, `id_token`, `expires_in`, `scope`). Requires the app client to use **S256 PKCE or a client secret**. The provider refresh token is never returned inline.
- **On demand + auto-refreshed** (`storeProviderTokens`): retrieve the stored provider token via RFC 8693 token exchange — always returned fresh (refreshed server-side if expired):

```
POST {realm}/oidc/token
Content-Type: application/x-www-form-urlencoded

grant_type=urn:ietf:params:oauth:grant-type:token-exchange
&subject_token={apptorID access OR refresh token}
&subject_token_type=urn:ietf:params:oauth:token-type:access_token   # or ...:refresh_token
&idp_connection_id={idpConnectionId}
&client_id={id}
&client_secret={secret}   # confidential clients only

Response:
{
  "access_token": "<provider token — fresh>",
  "issued_token_type": "urn:apptorid:oauth:token-type:provider-token",
  "token_type": "Bearer",
  "expires_in": 3600
}
```

- **Confidential client:** send `client_id`+`client_secret`; `subject_token` = apptorID **access** token; type `...:access_token`.
- **Public client:** no secret; `subject_token` = apptorID **refresh** token; type `...:refresh_token`.
- The user is resolved from the validated `subject_token`, never a parameter — you cannot request another user's token. Refresh is automatic; enabling `storeProviderTokens` requests the provider refresh token for you (no manual `offline_access`).

## JWT Token Claims

Access tokens and ID tokens are RS256-signed JWTs with these claims:

```json
{
  "sub": "user@example.com",
  "iss": "https://{realm-domain}",
  "aud": "client-id",
  "exp": 1712700000,
  "iat": 1712696400,
  "nbf": 1712696400,
  "email": "user@example.com",
  "user_name": "user@example.com",
  "name": "John Doe",
  "given_name": "John",
  "family_name": "Doe",
  "user_id": "user-ref-id",
  "account_id": "account-uuid",
  "org_id": "org-ref-id",
  "app_client_id": "app-client-uuid",
  "roles": ["admin", "editor"],
  "resource_server_id": "rs-uuid",
  "product_owner_ref_id": "po-ref-id",
  "nonce": "{nonce}"
}
```

`sub` and `user_name` are the user's **userName**, not a UUID. `user_id` is the app-supplied `userRefId` and `org_id` the `orgRefId`; each is present only when set on the user. `nonce` is present only when the auth request sent one.

**Validation steps:**
1. Fetch JWKS from `{realm}/oidc/jwks` (cache the keys, refresh periodically)
2. Verify signature using the RSA public key matching the token's `kid` header
3. Verify `exp` > current time (token not expired)
4. Verify `iss` matches the realm URL
5. Extract claims for user identity and authorization

## Token Endpoint Auth Method

apptorID supports:
- `client_secret_post` — include client_id and client_secret in the POST body (recommended)
- `client_secret_basic` — Base64(client_id:client_secret) in Authorization header

Always use `client_secret_post` — simpler and more widely compatible.

## Scopes

Always request: `openid email profile`

## App URL Types

When registering URLs for an app client (via Admin UI or MCP tools):

| Type | Purpose |
|------|---------|
| `redirect` | OAuth2 callback URL — where auth code is sent after login |
| `login` | Tenant's login page URL (for client-hosted login) |
| `logout` | Post-logout redirect URL |
| `reset_password` | Password reset page URL |
| `post_reset_password` | Where to redirect after password reset |

## Hosted Login — URL Registration + Fallback

apptorID's hosted login page is at: `https://{realm-domain}/hosted-login/`

**The hosted fallback is narrower than it looks.** With NO `login` URL registered:
- `/oidc/auth` **without** `provider_id` fails with `no_login_url_registered` — no fallback on this path.
- `/oidc/auth?provider_id=local` falls back to the realm's hosted SPA `https://{realm-domain}/hosted-login/` (not for `idpClient` app clients, which must register a login URL).
- Reset and welcome email links fall back to the hosted SPA when no `reset_password` URL is registered.

`logout` and `post_reset_password` never fall back (they point to customer-owned destinations).

Practical consequence: **always register a `login` URL** — `https://{realm-domain}/hosted-login/` for hosted login, or the app's own page. Customer-registered URLs always win over the fallback. MCP `full_setup` registers only the redirect URLs, plus any login/logout URLs you pass it.

When a `login` URL is registered (or the fallback resolves), the `/oidc/auth` endpoint redirects to:
  `https://{login-url}?request_id={request_id}`

The hosted login page then fetches its config from `/api/hosted-login/config?requestId={request_id}` and renders the login form with configured IdPs. The same SPA also serves forgot password (`?view=forgot`) and reset password (`?token=...&client_id=...`).

## login_uri Parameter

The `/oidc/auth` endpoint accepts an optional `login_uri` query parameter:
- If provided: it must match one of the app client's registered login URLs (case-insensitive), otherwise the request fails with "Invalid login URI"; apptorID then redirects there with `?request_id=...`
- If not provided: the first registered login URL is used
- If not provided and none registered: fails with `no_login_url_registered` (see the fallback rules above)

## Discovery Response Structure

```json
{
  "issuer": "https://{realm-domain}",
  "authorization_endpoint": "https://{realm-domain}/oidc/auth",
  "token_endpoint": "https://{realm-domain}/oidc/token",
  "jwks_uri": "https://{realm-domain}/oidc/jwks",
  "userinfo_endpoint": "https://{realm-domain}/oidc/userinfo",
  "revocation_endpoint": "https://{realm-domain}/oidc/revoke",
  "end_session_endpoint": "https://{realm-domain}/oidc/logout",
  "login_endpoint": "https://{realm-domain}/oidc/login",
  "custom_token_endpoint": "https://{realm-domain}/oidc/custom-token",
  "master_realm_base_uri": "https://master.sandbox.auth.apptor.io",
  "scopes_supported": ["email", "profile", "openid"],
  "claims_supported": ["sub"],
  "token_endpoint_auth_methods_supported": ["client_secret_post", "client_secret_basic", "none"],
  "subject_types_supported": ["public"],
  "grant_types_supported": ["authorization_code", "client_credentials", "password", "refresh_token", "passwordless_otp", "token_exchange", "urn:ietf:params:oauth:grant-type:token-exchange"]
}
```

## Default Token Expiration

| Token | Default TTL | Configurable per app client |
|-------|-------------|---------------------------|
| Access token | 60 minutes | Yes — `accessTokenExpirationInMin` |
| ID token | 60 minutes | Yes — `idTokenExpirationInMin` |
| Refresh token | 30 days | Yes — `refreshTokenExpirationInDays` |
| Auth code | Short-lived (minutes) | No — cached in Redis |
| Pre-auth token | 60 seconds, single-use | No |

## Multi-Tenant Architecture

```
Account (organization)  ← Apptor-provisioned; the access key is bound here; the SECURITY boundary
├── Realm 1 (auth domain: tenant1.sandbox.auth.apptor.io)
│   ├── Users (email + userName unique per realm)
│   ├── App Clients (each with client_id + secret)
│   │   └── IdP Connections (local, Google, Microsoft per client)
│   ├── Password Policy (per realm)
│   └── Branding (per realm or per app client)
├── Realm 2 (auth domain: tenant2.sandbox.auth.apptor.io)
│   └── ...
├── Resource Servers (account-level — NOT per realm)
│   ├── Roles (admin, editor, viewer)
│   └── Permissions
└── JWT signing keys (account-level — shared by ALL realms in this account)
```

### Realm = data boundary, Account = security boundary

Each realm isolates **data**: different users, app clients, IdPs, password policy, branding, auth domain. But realms are NOT cryptographically isolated from each other:

- **JWT signing keys are per-account, not per-realm.** Every realm under one account signs tokens with the same key and publishes the same JWKS (same `kid`). (`JWKKeyPairService` keys by `accountId`; `/oidc/jwks` looks up by `realm.getAccountId()`.)
- A JWT minted while logging into realm A **validates** at admin endpoints hit on realm B's host, as long as both realms are in the same account. The server's own validator checks signature + expiry, not `iss`/`aud`/realm scope.
- Admin authorization is account-scoped: a `realm_manage` token can act on any realm in its account; only `master_realm_manage` (Apptor's own master key) crosses accounts. Neither role can be restricted to a single realm with current code.
- A token from account X does NOT validate against account Y (different signing keys).

**Implication for SaaS Model A (realm per customer):** putting your customers in separate realms under your one account gives data isolation and per-customer branding/IdPs, but NOT cryptographic isolation between them — your app's JWT verifier is the trust boundary and you authorize per-tenant via the `org_id` claim (or the realm the user belongs to). If a customer genuinely needs hard cryptographic isolation, that requires a separate Apptor account per tenant, which only Apptor can provision.

**Relying-party guidance is unchanged:** still verify `iss` matches the realm you expect and validate the signature against that realm's JWKS. The point above is about what the auth server enforces internally, not about relaxing your own client-side checks.
