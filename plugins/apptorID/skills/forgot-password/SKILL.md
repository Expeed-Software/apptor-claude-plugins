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

Generates: a forgot-password endpoint (triggers apptorID's reset email), a password reset page (where user lands from the email link to set a new password), and optionally a change-password endpoint (authenticated user changes their own password).

## How to Work

- **Explore first.** Read existing auth code and config to understand what's already wired.
- **One question at a time.** Interactive format.
- **Adaptive follow-ups.** After building, offer relevant next steps.
- Read the relevant reference file BEFORE writing code.

## MANDATORY: Read API Spec First

Before writing ANY code, read `references/apptorID-api-spec.md`. This is the single source of truth for all endpoint URLs, parameter names, and the reset password flow. Do NOT guess endpoint paths.

## HARD GATE: Explore and Confirm Before Building

**You MUST complete ALL of these steps before writing ANY code. No exceptions.**

1. **Check for existing reset_password URL** — call `apptorID_list_app_urls` and check if a `reset_password` URL is already registered. If it IS registered AND the page it points to already exists in the codebase (e.g., from a prior `apptorID:user-management` run), skip building a new page — just wire the forgot-password endpoint to trigger the email.
2. **Scan the codebase** — find existing pages, components, routes that might already handle password reset
3. **Present findings** — "I found these existing pages: [list]. I found this existing auth setup: [details]."
4. **Ask where to build the reset page** — "The reset password page needs to be in YOUR app (not on the auth server). Where should I put it?
   (A) Add a new `/reset-password` route/page
   (B) Integrate into your existing [page I found]
   (C) Other location you prefer"
   **Wait for the user's answer. Do NOT proceed without it.**
5. **Confirm the plan** — summarize what you'll build and where, get approval

## CRITICAL: The Auth Server Does NOT Have a Reset Password Page

apptorID's hosted login is a login-only page. It does **NOT** provide a reset password page. The developer's app MUST build its own reset password page. If you skip this, the email link will lead to a 404.

## Process

1. **Detect** — find existing auth setup, config, backend framework, frontend framework
2. **Read API spec** — `references/apptorID-api-spec.md` (the forgot-password and reset-password sections)
3. **Register app URLs FIRST** — via MCP (`apptorID_add_app_urls`):
   - `reset_password` → the URL of the reset page you're about to build (e.g., `https://myapp.com/reset-password`)
   - `post_reset_password` → where to redirect after successful reset (e.g., `https://myapp.com/login`)
   **URLs must be registered BEFORE triggering forgot-password, otherwise the email link will be wrong.**
4. **Build forgot-password endpoint** — backend endpoint that calls apptorID's forgot-password API
5. **Build reset password page** — frontend page where user lands from email link, collects new password, calls reset-password API
6. **Build change-password endpoint** (if appropriate) — authenticated user provides current + new password
7. **Handle email template** (if asked) — configure custom template via MCP or tell user about defaults
8. **Test and review**
9. **Offer next steps** — adaptively suggest relevant features

## Email Flow

Password reset emails use apptorID's default SMTP — **works out of the box, no setup needed.**

Default SMTP fallback chain: realm config → account config → master account config.

Tell the user: "Password reset emails use apptorID's default email service. If you want your own sender address and branding, I can configure custom SMTP."

## Email Template Variables

Available in password reset email templates (`reset_password` email type):
- `{{password_reset_url}}` — the password reset link (auto-generated from registered `reset_password` app URL)
- `{{link_expiry}}` — human-readable expiry like "30 minute(s)"
- `{{user_name}}` — the user's username
- `{{login_url}}` — the login URL

**There is NO server-side validation** of template variables. Missing variables just stay as literal text in the email.

## App URL Types for Password Reset

Register via MCP (`apptorID_add_app_urls`):
- `reset_password` → URL where user lands from email link (e.g., `https://myapp.com/reset-password`)
- `post_reset_password` → URL to redirect after successful reset (e.g., `https://myapp.com/login`)

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

## Reset Password Page — What It Receives and What It Calls

The reset email sends the user to: `{registered_reset_password_url}?token={reset-token}&client_id={app-client-id}`

The reset page must:
1. Extract `token` and `client_id` from URL query parameters
2. Show a "new password" form
3. On submit, call:

```
POST /reset-password
Content-Type: application/json

{
  "token": "{token-from-url}",
  "password": "{new-password}",
  "userName": "{username}",
  "appClientId": "{client_id-from-url}"
}
```

4. On success, redirect to the registered `post_reset_password` URL

## Key Details

- The public forgot-password endpoint requires NO authentication — just call it with appClientId and userName in the path
- The reset page is a FRONTEND page in the developer's app — not on the auth server
- `userName` for the reset-password POST can be extracted from the token JWT payload (`sub` claim) if needed

## Reference Files

- Stack-specific → `references/{stack}.md`
- Protocol → `references/oidc-knowledge.md`

## Rules

- Write code, don't describe it.
- Follow project conventions.
- Read reference files FIRST.
- Credentials in backend config only.
- Adapt to any stack.
- After completion, suggest related skills:
  - "Want to manage users from your app?" → `apptorID:user-management`
  - "Need to configure email templates?" → `apptorID:manage`
