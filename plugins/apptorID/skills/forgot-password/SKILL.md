---
name: forgot-password
description: >
  Add forgot password flow with reset page to an app using apptorID. Use when the user wants to:
  add forgot password, password reset, reset page, password recovery. Triggers on: "forgot password",
  "reset password", "password reset", "password recovery", "change password".
---

# apptorID Forgot Password Agent

You add forgot password and password reset functionality to an app with apptorID authentication.

## What This Does

Generates: a forgot-password endpoint, a password reset page if the app should not use apptorID's hosted one, and optionally a change-password endpoint (authenticated user changes their own password).

## Two Modes — Decide First

| | Mode 1: apptorID sends the email | Mode 2: the app sends the email |
|---|---|---|
| Who sends | apptorID, over SMTP only (SendGrid/SES only via their SMTP relay) | The app, through any provider (SMTP, SendGrid API, AWS SES API, ...) |
| Templates live in | apptorID (`apptorID_save_email_template`) | The app |
| Login page | apptorID hosted login works | **Must be client-hosted** (`POST /oidc/pre-authorize`) |
| Forgot-password call | Public `POST /app-clients/{appClientId}/users/{userName}/forgot-password` | `POST .../forgot-password/secured?appHandlesNotification=true` with an admin Bearer token — returns the reset token, sends nothing |
| Reset page | apptorID hosted reset page, or the app's own | apptorID hosted reset page, or the app's own |

**Why Mode 2 requires a client-hosted login:** whenever local (username/password) login is enabled, the hosted login page shows its own "Forgot password?" link (`allowPasswordReset` is hard-coded true; there is no setting to hide it or point it elsewhere), and that link always sends the email from apptorID. An app that must own its emails cannot use the hosted login page.

## How to Work

- **Explore first.** Read existing auth code and config to understand what's already wired.
- **One question at a time.** Interactive format.
- **Adaptive follow-ups.** After building, offer relevant next steps.
- Read the relevant reference file BEFORE writing code.

## MANDATORY: Ground in the Live OpenAPI Spec First

Before writing ANY code, fetch the live OpenAPI spec from the realm (`https://{realm-authDomain}/swagger/apptor-auth-server-{version}.yml`; take the exact file name from `/swagger-ui/index.html`, never hardcode the version) — it is authoritative for endpoint URLs, parameter names, and the reset password flow. Then read `references/apptorID-api-spec.md` as the curated quick reference. When they conflict, the live spec wins. Do NOT guess endpoint paths.

## HARD GATE: Explore and Confirm Before Building

**You MUST complete ALL of these steps before writing ANY code. No exceptions.**

1. **Check for existing reset_password URL** — call `apptorID_list_app_urls` and check if a `reset_password` URL is already registered. If it IS registered AND the page it points to already exists in the codebase (e.g., from a prior `apptorID:user-management` run), skip building a new page — just wire the forgot-password endpoint to trigger the email.
2. **Scan the codebase** — find existing pages, components, routes that might already handle password reset
3. **Present findings** — "I found these existing pages: [list]. I found this existing auth setup: [details]."
4. **Ask which mode** — "Should apptorID send the reset email (Mode 1), or does your app need to send it with its own templates and email provider (Mode 2, requires your own login page)?" **Wait for the answer.**
5. **Ask where the reset page lives** —
   (A) Use apptorID's hosted reset page — nothing to build (recommended unless they want custom UI)
   (B) Add a new `/reset-password` route/page in the app
   (C) Integrate into an existing [page I found]
   **Wait for the user's answer. Do NOT proceed without it.**
6. **Confirm the plan** — summarize what you'll build and where, get approval

## apptorID Hosted Pages

The hosted login SPA at `https://{realm-authDomain}/hosted-login/` serves three pages:
- **Login** — default view
- **Forgot password** — `?view=forgot`; reached from the login page's link; calls the public forgot-password API, so apptorID sends the email
- **Reset password** — any URL carrying `?token={reset-token}&client_id={client-id}`; validates the token, enforces the realm's password policy, and sets the new password

If no `reset_password` URL is registered for the app client, apptorID builds reset (and welcome) email links against `https://{realm-authDomain}/hosted-login/`, so the hosted reset page works with zero setup.

## Process

1. **Detect** — find existing auth setup, config, backend framework, frontend framework
2. **Read API spec** — `references/apptorID-api-spec.md` (the forgot-password and reset-password sections)
3. **Register app URLs FIRST (own reset page only)** — via MCP (`apptorID_add_app_urls`):
   - `reset_password` → the URL of the reset page you're about to build (e.g., `https://myapp.com/reset-password`)
   **URLs must be registered BEFORE triggering forgot-password, otherwise the email link will be wrong.** Skip this when using the hosted reset page.
4. **Build forgot-password endpoint** —
   - Mode 1: backend calls the public forgot-password API
   - Mode 2: backend calls `/forgot-password/secured?appHandlesNotification=true` (Java SDK: `AuthServerAdminClient.getForgotPasswordToken(appClientId, userName, true)`), builds `{reset page}?token={token}&client_id={client-id}`, and sends it with the app's own template and provider
5. **Build reset password page** (own reset page only) — frontend page where user lands from email link, collects new password, calls reset-password API
6. **Build change-password endpoint** (if appropriate) — authenticated user provides current + new password
7. **Handle email template** (if asked) — configure custom template via MCP or tell user about defaults
8. **Test and review**
9. **Offer next steps** — adaptively suggest relevant features

## Email Flow

**Mode 1:** password reset emails use apptorID's default SMTP — **works out of the box, no setup needed.**

Default SMTP fallback chain: realm config → account config → master account config.

Tell the user: "Password reset emails use apptorID's default email service. If you want your own sender address and branding, I can configure custom SMTP and templates. If you need a non-SMTP provider or templates managed in your app, that is Mode 2 and needs your own login page."

**Mode 2:** apptorID sends nothing; email config and templates in apptorID are unused. The same `appHandlesNotification=true` pattern covers welcome/invitation emails (`POST /realms/{realmId}/users?appHandlesNotification=true` returns `notificationToken`; `/resend-invitation/secured`, SDK `getResendInvitationToken`) and SMS OTPs (`/phone/{phone}/forgot-password/secured`, then `POST /reset-password-by-otp`).

## Email Template Variables

Available in password reset email templates (`reset_password` email type):
- `{{password_reset_url}}` — the password reset link (auto-generated from registered `reset_password` app URL)
- `{{link_expiry}}` — human-readable expiry like "30 minute(s)"
- `{{user_name}}` — the user's username
- `{{login_url}}` — the login URL

Saving a `reset_password` template without `{{password_reset_url}}`, `{{user_name}}` and `{{link_expiry}}` is rejected. Unknown variables stay as literal text.

## App URL Types for Password Reset

Register via MCP (`apptorID_add_app_urls`):
- `reset_password` → URL where user lands from email link (e.g., `https://myapp.com/reset-password`)
- `post_reset_password` is accepted but nothing in apptorID reads it, so don't register it; your reset page decides where to go after success.

## Credential Security (HARD RULES)

- The public forgot-password endpoint needs NO authentication
- The `/secured` variant requires admin credentials (access_key_id/secret) — those go in **backend config file only**
- **NEVER** expose secrets in frontend or logs
- After wiring, suggest secure storage for production

## Forgot Password API — Exact Endpoint

```
POST /app-clients/{appClientId}/users/{userName}/forgot-password
```

**This is a PUBLIC endpoint — no authentication required.** There is a `/secured` variant (`POST /app-clients/{appClientId}/users/{userName}/forgot-password/secured`) that requires admin auth if the app needs to handle notifications itself (supports `appHandlesNotification` query param).

**Both `appClientId` AND `userName` are in the URL path.** NOT in a JSON body.

## Own Reset Password Page — What It Receives and What It Calls

Only needed when not using the hosted reset page. The reset email sends the user to: `{registered_reset_password_url}?token={reset-token}&client_id={app-client-id}`

The reset page must:
1. Extract `token` and `client_id` from URL query parameters. **Never decode the token** — it is an opaque random string.
2. Optionally call `GET /api/hosted-login/reset-config?token=...&client_id=...` to show the username (`userName`) and the password rules, and to show an "expired or already used" message when `valid` is false (see `references/apptorID-api-spec.md` "Reset Password Page")
3. Show a "new password" form
4. On submit, call:

```
POST /reset-password
Content-Type: application/json

{
  "token": "{token-from-url}",
  "password": "{new-password}",
  "appClientId": "{client_id-from-url}"
}
```

5. On success, redirect to the app's login page

## Key Details

- The public forgot-password endpoint requires NO authentication — just call it with appClientId and userName in the path
- The reset page is either apptorID's hosted one (`https://{realm-authDomain}/hosted-login/?token=...&client_id=...`) or a frontend page in the developer's app
- Google/Microsoft (federated) users have no apptorID password. The `/secured` forgot-password route returns 400 for them, so show "sign in with your identity provider". The public route returns 400 on older servers and a silent 200 after the admin-API fix release, so never treat its response as proof the account exists
- `/reset-password` reads only `token`, `password` and `appClientId`; the user comes from the token. The token is single-use, but a password that fails policy does not consume it

## Reference Files

- Stack-specific → `references/{stack}.md`
- Any Java backend → offer the apptorID Java SDK first, see `references/java-micronaut.md` "Option A"
- Protocol → `references/oidc-knowledge.md`

## Rules

- Write code, don't describe it.
- Follow project conventions.
- Hand-written HTTP calls must match the live OpenAPI spec; with the Java SDK, confirm signatures with `javap` first (see `apptorID:setup` "Verify the SDK").
- The project must build cleanly before you report done.
- Read reference files FIRST.
- Credentials in backend config only.
- Adapt to any stack.
- After completion, suggest related skills:
  - "Want to manage users from your app?" → `apptorID:user-management`
  - "Need to configure email templates?" → `apptorID:manage`
