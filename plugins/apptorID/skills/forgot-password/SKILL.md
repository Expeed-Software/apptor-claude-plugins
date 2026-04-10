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

## Process

1. **Detect** — find existing auth setup, config, backend framework, frontend framework
2. **Read reference** — stack-specific reference file
3. **Build forgot-password endpoint** — accepts email/username, calls apptorID's forgot-password API
4. **Build reset page** — user lands here from email link. Form collects new password, submits token + new password to apptorID
5. **Register reset URL** — if MCP available, register the reset page URL as `reset_password` type via `apptorID_add_app_urls`. Also register `post_reset_password` redirect URL.
6. **Build change-password endpoint** (if appropriate) — authenticated user provides current + new password
7. **Handle email template** (if asked) — configure custom template via MCP or tell user about defaults
8. **Test and review**
9. **Offer next steps** — adaptively suggest relevant features

## Email Flow

Password reset emails use apptorID's default SMTP — **works out of the box, no setup needed.**

Default SMTP fallback chain: realm config → account config → master account config.

Tell the user: "Password reset emails use apptorID's default email service. If you want your own sender address and branding, I can configure custom SMTP."

## Email Template Variables

Available in password reset email templates:
- `{{userName}}` — the user's username/email
- `{{firstName}}` — user's first name
- `{{lastName}}` — user's last name
- `{{resetLink}}` — the password reset URL (auto-generated)
- `{{appName}}` — the app client's name
- `{{realmName}}` — the realm name

## App URL Types for Password Reset

Register via MCP (`apptorID_add_app_urls`):
- `reset_password` → URL where user lands from email link (e.g., `https://myapp.com/reset-password`)
- `post_reset_password` → URL to redirect after successful reset (e.g., `https://myapp.com/login`)

## Credential Security (HARD RULES)

- Admin API credentials (access_key_id/secret) needed for forgot-password API call
- Go in **backend config file only**
- **NEVER** expose in frontend or logs
- After wiring, suggest secure storage for production

## Key Details

- Forgot-password API needs the `appClientId` from config + the username
- The reset page receives a token in the URL from the email link
- The set-password endpoint validates the token + sets new password via apptorID API
- If admin API credentials aren't in the config yet, ask user for them or provision via MCP

## Reference Files

- Stack-specific → `references/{stack}.md`
- Protocol → `references/oidc-knowledge.md`

## Rules

- Write code, don't describe it.
- Follow project conventions.
- Read reference files FIRST.
- Credentials in backend config only.
- Adapt to any stack.
- Offer next steps adaptively after completion.
