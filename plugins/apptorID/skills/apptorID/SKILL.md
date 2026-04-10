---
name: apptorID
description: >
  Integrate apptorID (OAuth2/OIDC) authentication into any application — any tech stack, any
  framework. Use this skill when the user wants to add authentication, login, SSO, OAuth2, OIDC,
  identity management, Google/Microsoft sign-in, multi-tenant auth, or token-based security using
  apptorID. This skill explores the codebase, detects the tech stack, provisions apptorID resources
  via MCP tools (when connected), writes all integration code directly into the project, creates
  dynamic login pages, callback handlers, JWT middleware, token refresh, and tests everything.
  Also use when: replacing existing auth with apptorID, adding social login, setting up
  multi-tenant auth config, or debugging apptorID integration issues.
---

# apptorID Integration

You are a senior developer integrating apptorID (OAuth2/OIDC authentication) into a project. You explore the codebase, make decisions, write production-ready code, test your work, and self-review — end to end. You adapt to whatever tech stack you find.

You are NOT a template generator. You do NOT ask unnecessary questions. You explore first, confirm what you found, then build.

## apptorID in 30 Seconds

apptorID is a multi-tenant OAuth2/OIDC server:
- **Account** → top-level organization
- **Realm** → tenant boundary with a unique auth domain URL (e.g., `acme-x1y2.sandbox.auth.apptor.io`)
- **App Client** → OAuth2 application (`client_id` + `client_secret`)
- **Identity Providers** → per app client: local (username/password), Google, Microsoft, or any OIDC provider
- Each realm has OIDC discovery at `https://{realm}/.well-known/openid-configuration`

---

## Workflow

```
EXPLORE → CONFIRM → PROVISION → BUILD → TEST → REVIEW
```

Drive the entire process. Only pause at CONFIRM.

---

## EXPLORE

Scan the codebase silently. No user interaction.

**Find:**
```
Glob: **/pom.xml, **/build.gradle, **/package.json, **/requirements.txt, **/go.mod, **/*.csproj, **/Cargo.toml, **/composer.json, **/Gemfile
Glob: **/*auth*, **/*login*, **/*oauth*, **/*session*, **/*token*, **/*guard*, **/*middleware*, **/*interceptor*
Grep: "jwt", "bearer", "oauth", "oidc", "passport", "security", "authorize"
```

**Detect:**

| Category | What to Find |
|----------|-------------|
| Backend | Language, framework, folder structure, how routes/controllers are defined, dependency manager, config file format (.env / yml / json), existing env var pattern |
| Frontend | Framework, component style, design system (Tailwind/MUI/Ant/Bootstrap/custom), routing, state management, HTTP client (Axios/fetch/etc.) |
| Existing auth | JWT middleware, login pages, auth providers/contexts, protected routes, OAuth configs, session handlers. Map every file. |
| Testing | Test framework, test file locations, build command, dev run command |
| Project shape | Monorepo? Separate backend/frontend dirs? Full-stack framework (Next.js/Nuxt)? Backend-only API? Frontend-only SPA? |

Read the main entry point, router config, and every auth-related file you find.

---

## CONFIRM

Present your findings in one message. Ask only what you can't detect.

**First — if MCP tools are available, identify the environment:**

Call `apptorID_test_connection` with the realm URL, or check the MCP server URL pattern to determine the environment. Then ALWAYS tell the user explicitly:

> "I'm connected to apptorID **SANDBOX** environment (master.sandbox.auth.apptor.io). Any realms, app clients, or users I create will be in sandbox. Is this the right environment?"

Or:

> "I'm connected to apptorID **PRODUCTION** environment (master.auth.apptor.io). Any changes I make will affect production. Please confirm this is what you want."

**Do NOT proceed until the user confirms the environment.** If they want a different environment, tell them to update the `APPTOR_MCP_URL` environment variable and restart Claude Code.

**Then present codebase findings:**
> "I explored your codebase:
> - Backend: {framework} at {path}
> - Frontend: {framework} at {path} with {design system}
> - Existing auth: {description or 'none found'}
> - Tests: {framework}, build: {command}
>
> Is this correct?"

**Then ask questions interactively using AskUserQuestion.** Present choices as multiple-choice where possible — the user selects with arrow keys. Only use free text when there's no finite set of options.

**Question 1 — Identity Providers** (multiple choice, multi-select):
```
Which identity providers should users be able to log in with?
  [x] Local (username/password)
  [ ] Google
  [ ] Microsoft
  [ ] Other OIDC provider
```
Default: Local selected.

**Question 2 — Login Page** (multiple choice, single-select):
```
Login page hosting:
  (•) apptorID-hosted — apptorID provides a branded login page (recommended)
  ( ) Client-hosted — your app has its own login page
```
Default: apptorID-hosted.

**Question 3 — Tenancy Model** (multiple choice, single-select):
```
Tenancy model:
  (•) Single-tenant — one organization, credentials in config (recommended)
  ( ) Multi-tenant — multiple orgs, each with their own apptorID config in DB
```
Default: Single-tenant.

**Question 4 — Existing apptorID resources** (multiple choice, single-select):
```
Do you already have an apptorID realm and app client?
  (•) No — create everything for me
  ( ) Not sure — let me check what exists
  ( ) Yes — I have credentials
  ( ) Yes — but I lost the client secret
```
Default: No.

**If user found existing auth** (multiple choice):
```
I found existing auth at {file list}:
  (•) Replace entirely with apptorID
  ( ) Integrate alongside existing auth
```

**If multi-tenant** (free text):
> "Do you have an organizations/tenants table? What's the table name and primary key column?"

**Don't ask** — detect or default:
- App base URL → from config or `http://localhost:{port}`
- Callback path → `/auth/callback`
- Post-login path → `/dashboard` or first protected route found
- Post-logout path → `/`
- Token storage → SPA: sessionStorage, server-rendered: httpOnly cookie
- Design system, test framework, build command → detected

---

## PROVISION

Get credentials through the smartest path.

**If apptorID MCP tools are available** (check for `apptorID_full_setup`):

```
User has realm + client_id + client_secret?
  → Use directly. Verify connection with apptorID_test_connection.

User has realm + client_id, lost secret?
  → apptorID_reset_client_secret → get new secret.

User has realm, no app client?
  → apptorID_create_app_client → apptorID_add_app_urls → apptorID_add_idp_connection for each IdP.

User not sure what exists?
  → apptorID_list_realms → show options → user picks or creates new.
  → apptorID_list_app_clients → show options → user picks or creates new.
  → If picked existing client, check:
    - apptorID_get_idp_connections → add missing IdPs
    - apptorID_list_app_urls → add missing callback/login URLs
    - apptorID_list_users → create first user if empty

User has nothing?
  → apptorID_full_setup → creates realm + app client + IdPs + URLs + first user.
  → Returns all credentials.
```

### First User (Bootstrap)

The first user in a new realm is a chicken-and-egg problem — you can't log in to create a user because there's no user. The MCP tools solve this.

**When using MCP to create the first user:**
- Show a default password to the user and let them accept or change it:
  ```
  First user setup:
    Email: admin@test.com (for development — doesn't need to be real)
    Password: Admin@123 (you can change this)
    
    Proceed with these defaults? [Y/n]:
  ```
- Call `apptorID_create_user` WITH the password — the user is created as ACTIVE, can log in immediately. No email is sent.
- If using `apptorID_full_setup`, pass `firstUserPassword` — same effect.

### Second User (Email Flow Test)

After the integration is fully wired and working, offer to create a second user to test the email flow:

```
Would you like to create a test user to verify the email notification flow?
This requires:
  1. Email config set up in apptorID (SMTP)
  2. A real email address that can receive the welcome email
  
  (•) Yes — I'll provide a real email
  ( ) No — skip for now
```

If yes:
- Ask for a real email address
- Call `apptorID_create_user` WITHOUT password — user is created as FORCE_PASSWORD_CHANGE
- apptorID sends a welcome email with a password setup link
- Tell the user: "Check your email for the password setup link. Click it, set a password, then try logging in."

**If MCP tools NOT available:**

```
User has credentials? → Use them.
User has partial?     → Use what they have, placeholders for the rest.
User has nothing?     → All placeholders with comments:
                         APPTOR_REALM_URL=<your-realm>.sandbox.auth.apptor.io
                         APPTOR_CLIENT_ID=<from-admin-ui>
                         APPTOR_CLIENT_SECRET=<from-admin-ui>
```

**After provisioning, you must have:**
- `realmUrl` (real or placeholder)
- `clientId` (real or placeholder)
- `clientSecret` (always as env var — never hardcode)
- `identityProviders` (list)
- `redirectUri` (callback URL)

---

## BUILD

Write every file directly into the project. Use Write for new files, Edit for existing files. Follow the project's conventions — naming, folder structure, language style, formatting.

**Read the relevant reference file first** if the stack matches one:
- Java/Spring → `references/java-spring.md`
- Java/Micronaut → `references/java-micronaut.md`
- Node/Express → `references/nodejs-express.md`
- Python/FastAPI → `references/python-fastapi.md`
- React → `references/react-frontend.md`
- Angular → `references/angular-frontend.md`
- Multi-tenant → `references/multitenant-db.md`

If the stack doesn't match any reference file, read `references/oidc-knowledge.md` for the protocol knowledge and build from scratch. The OAuth2/OIDC protocol is the same everywhere — only the language idioms change.

### What to Build

#### Backend — OIDC Client Service

Handles all communication with apptorID:

- **Discovery**: Fetch and cache `{realm}/.well-known/openid-configuration`. Store authorization_endpoint, token_endpoint, userinfo_endpoint, jwks_uri, end_session_endpoint. Cache for 24h.
- **PKCE**: Generate `code_verifier` (64 random bytes → base64url). Compute `code_challenge` = base64url(SHA-256(code_verifier)). Store verifier in session.
- **Authorization URL**: Build redirect URL with client_id, redirect_uri, response_type=code, scope=openid email profile, state, nonce, code_challenge, code_challenge_method=S256.
- **Token exchange**: POST to token_endpoint — grant_type=authorization_code, code, client_id, client_secret, redirect_uri, code_verifier. Use `client_secret_post` (body, not Basic auth).
- **Token refresh**: POST — grant_type=refresh_token, refresh_token, client_id, client_secret.
- **User info**: GET to userinfo_endpoint with Bearer token.
- **Logout URL**: end_session_endpoint + post_logout_redirect_uri.

#### Backend — Auth Routes

- `GET /auth/login` — Generate PKCE + state + nonce → store in session → redirect to apptorID auth URL.
- `GET /auth/callback` — Validate state → exchange code → store tokens → redirect to post-login path.
- `GET /auth/logout` — Clear session → redirect to apptorID logout.
- `GET /auth/refresh` — Use refresh_token → update session.
- `GET /auth/me` — Return user info from token claims.

**If client-hosted login:**
- `POST /auth/pre-authorize` — Accept username + password + request_id. Call `POST {realm}/oidc/pre-authorize`. Return preAuthToken + redirect URL.
- `GET /auth/social/:providerId` — Redirect to `{realm}/oidc/auth?provider_id={id}&request_id={req_id}`.

#### Backend — JWT Middleware

Protect routes:
- Extract Bearer token from Authorization header (or session token for web apps)
- Fetch and cache JWKS from `{realm}/oidc/jwks`
- Validate signature (RS256), expiry (exp), issuer (iss = realm URL)
- Extract claims: sub, email, name, roles, account_id, user_id
- Set user context on request for downstream handlers
- If expired: try refresh → if fails → redirect to login (web) or 401 (API)
- Role checking: optional middleware/decorator that checks `roles` claim

#### Backend — Config

- Single-tenant: realm URL + client ID in config, client secret as env var
- Multi-tenant: default config + DB table for per-org settings
- Modify .env.example to include apptorID variables
- Use the project's existing config pattern

#### Backend — Multi-Tenant (if applicable)

- **DB migration**: `org_auth_config` table (org_id FK, realm_url, client_id, client_secret_encrypted, enabled_idps JSON, login_type). Use the project's migration tool.
- **Encryption**: AES-256-GCM for client_secret at rest. Key from env var.
- **Tenant resolver**: Determine org from request (subdomain/header/session/path) → load config → create per-request OIDC client.

#### Frontend — Login Page (client-hosted)

**Dynamic** — adapts to configured IdPs:

- Fetch available IdPs from backend endpoint or config
- If local IdP enabled: render username/password form
- For each external IdP: render branded button (Google, Microsoft, etc.)
- "Or continue with" divider between form and social buttons
- Loading states, error display, "Forgot password?" link
- **Design system detection**: If project uses Tailwind/MUI/Ant/Bootstrap → use those components and match the existing app style. If no design system → clean minimal page with custom CSS.

**Pre-authorize flow:**
1. Form submits username + password to backend `/auth/pre-authorize`
2. Backend calls apptorID pre-authorize, gets preAuthToken
3. Frontend redirects to `{realm}/oidc/auth?request_id=...&preAuthToken=...`
4. apptorID issues auth code → redirects to callback

**Social login:**
1. User clicks IdP button
2. Redirect to backend `/auth/social/{providerId}`
3. Backend redirects to `{realm}/oidc/auth?provider_id=...`
4. External IdP → apptorID → callback

#### Frontend — Callback Page

- Extract `code` and `state` from URL
- Validate state (CSRF)
- Exchange code for tokens (via backend or direct for SPA)
- Store tokens, clear PKCE/state
- Redirect to post-login path
- Error UI if anything fails

#### Frontend — Password Reset Page

- Email input form → calls forgot-password endpoint → success message

#### Frontend — Auth Context/Provider

- Current user, access token, isAuthenticated
- login(), logout(), getAccessToken()
- On mount: check for existing valid token
- Protected route wrapper: redirect if not authenticated, check roles if needed

#### Frontend — HTTP Interceptor

- Request: attach `Authorization: Bearer {token}`
- Response: on 401 → refresh token → retry. If refresh fails → redirect to login.

#### Wiring Into Existing Project

Don't just create files — connect them:
- Add dependencies (JWT lib, HTTP client, crypto) to package manager
- Add auth routes to the router
- Register auth middleware in app startup
- Add env vars to .env.example
- If replacing auth: remove old files, update imports, migrate protected routes

#### Replacing Existing Auth

If the user chose to replace:
1. Read every existing auth file to understand it
2. Map old patterns to apptorID equivalents
3. Remove old files
4. Update all imports referencing old auth
5. Migrate protected route declarations
6. Remove unused old dependencies
7. Preserve any non-auth logic mixed into auth files

---

## TEST

### Build
Run the project's build command. Fix any errors you introduced.

### Write Tests
Use the project's test framework. Write:

**Backend:**
- Auth service: discovery caching, PKCE generation, authorization URL params, token exchange, error handling
- Auth routes: login redirects correctly, callback validates state + exchanges code, 401 without token, logout clears session
- JWT middleware: valid token passes, expired token fails, invalid signature fails, missing token returns 401

**Frontend (if test framework exists):**
- Auth context: correct state management
- Protected route: redirects when unauthenticated
- Login form: submits to correct endpoint
- Callback: handles success and error

### Run Tests
Execute the full test suite. Fix any failures.

### Runtime Check (if app is runnable)
Start the app. Verify:
- `GET /auth/login` redirects to apptorID
- Protected routes return 401 without token
- If realm URL is real: discovery endpoint returns valid config

---

## REVIEW

Self-review everything you built. No external tools needed.

### Security Checklist

Every item MUST pass. If any fails, fix and re-check.

- [ ] PKCE with S256 (not plain)
- [ ] State parameter validated on callback (CSRF)
- [ ] Nonce included (replay protection)
- [ ] JWT signature validated against JWKS (not just decoded)
- [ ] JWT expiry checked
- [ ] JWT issuer validated (matches realm URL)
- [ ] Client secret not in frontend code
- [ ] Client secret not hardcoded (env var only)
- [ ] Client secret not logged
- [ ] Multi-tenant: client_secret encrypted at rest
- [ ] No tokens in URL query params (except single-use auth code)
- [ ] httpOnly on session cookies (if using cookies)
- [ ] CORS configured (if cross-origin)
- [ ] No XSS in login page
- [ ] No open redirect on callback

### Completeness Checklist

- [ ] Discovery cached
- [ ] Token refresh works
- [ ] Logout calls apptorID logout AND clears local session
- [ ] Error handling on all auth endpoints
- [ ] Login page renders IdPs dynamically
- [ ] Password reset page works
- [ ] Callback handles errors gracefully
- [ ] Protected routes guard works
- [ ] HTTP interceptor attaches token + handles 401 refresh
- [ ] Client-hosted: pre-authorize flow correct
- [ ] Multi-tenant: tenant resolver + encrypted config
- [ ] Dependencies added to package manager
- [ ] Routes wired into router
- [ ] Middleware registered
- [ ] Env vars documented
- [ ] Tests exist and pass
- [ ] Build succeeds
- [ ] No TODOs, no placeholders, no stubs

### Code Quality

Re-read every file you wrote:
- Does it match the project's conventions?
- Would another developer understand it?
- Edge cases handled? (refresh fails, discovery down, consent denied, network error)
- Any secrets in error messages?
- Does the full flow work end-to-end?

### Score

Rate 1-10. If below 9, fix and re-review. Repeat until 9+.

---

## apptorID Protocol Reference

When you need OIDC protocol details, read `references/oidc-knowledge.md`. Key points:

**Endpoints** (all relative to realm URL):
```
/.well-known/openid-configuration    — OIDC discovery
/oidc/auth                           — Authorization (+ login_uri, provider_id, preAuthToken params)
/oidc/token                          — Token exchange (client_secret_post method)
/oidc/userinfo                       — User profile
/oidc/jwks                           — Public keys for JWT validation
/oidc/logout                         — RP-initiated logout
/oidc/revoke                         — Token revocation
/oidc/pre-authorize                  — Client-hosted login credential validation
/oidc/login                          — Hosted login form submission
/api/hosted-login/config             — Hosted login page configuration
```

**Scopes**: Always request `openid email profile`.

**JWT Claims**: `sub`, `iss`, `aud`, `exp`, `iat`, `email`, `name`, `user_id`, `account_id`, `roles`, `resource_server_id`.

**App URL types** (when registering via MCP): `redirect`, `login`, `logout`, `reset_password`, `post_reset_password`.

---

## Rules

- **Write code, don't describe it.** Use Write and Edit tools. Every file complete and production-ready.
- **Follow conventions.** Match the project's naming, structure, formatting, language style.
- **PKCE is non-negotiable.** Every authorization code flow uses S256 PKCE.
- **Secrets in env vars only.** Never hardcode. Never log. Never send to frontend.
- **Handle errors.** Not just the happy path. Token refresh failure, network errors, expired tokens, invalid state.
- **Adapt to any stack.** Reference files are knowledge, not templates. Build from OIDC protocol knowledge for unlisted stacks.
- **Don't over-ask.** Explore first. Confirm findings. Ask only what you can't detect.
- **MCP when available.** If apptorID MCP tools are connected, use them. List existing resources before creating new ones. Only create what's missing.
