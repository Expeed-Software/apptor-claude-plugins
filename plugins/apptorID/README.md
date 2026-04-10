# apptorID — Claude Code Plugin

Integrate [apptorID](https://apptor.io) (OAuth2/OIDC) authentication into any application using Claude Code.

## What It Does

- **Explores** your codebase — detects backend, frontend, design system, existing auth
- **Provisions** apptorID resources — creates realms, app clients, IdPs, first user (via MCP)
- **Writes** all integration code — auth service, login page, callback, JWT middleware, token refresh, tests
- **Adapts** to your tech stack — Spring, Express, FastAPI, React, Angular, Vue, or anything else
- **Self-reviews** — checks security, completeness, and code quality before declaring done

## Install

```bash
# From the apptor marketplace:
claude plugin marketplace add https://github.com/expeedsoftware/apptor-claude-plugins
claude plugin add apptorID

# Or directly:
claude plugin add https://github.com/expeedsoftware/apptor-claude-plugins/plugins/apptorID
```

## Configure

Set your apptorID access key credentials as environment variables:

```bash
export APPTOR_ACCESS_KEY_ID=your-access-key-id
export APPTOR_ACCESS_KEY_SECRET=your-access-key-secret
```

Optionally, if using production instead of sandbox:
```bash
export APPTOR_MCP_URL=https://master.auth.apptor.io/mcp
```

Default MCP URL is `https://master.sandbox.auth.apptor.io/mcp`.

## Usage

In your project directory, just tell Claude what you want:

```
> Add apptorID authentication to my app

> Integrate login with Google and Microsoft via apptorID

> Replace our existing auth with apptorID

> Set up multi-tenant authentication using apptorID
```

The skill will:
1. Explore your codebase (no questions needed)
2. Confirm what it found (1-2 questions max)
3. Provision apptorID resources if MCP is connected
4. Write all integration code into your project
5. Run tests and self-review

## Works Without MCP Too

If you don't have access keys configured, the skill still works — it generates integration code with placeholder credentials and guides you through the apptorID Admin UI to set things up manually.

## Supported Tech Stacks

The skill works with **any** tech stack. It has deep knowledge of:
- **Backend**: Java/Spring, Java/Micronaut, Node/Express, Python/FastAPI
- **Frontend**: React, Angular, Vue
- **Multi-tenant**: Any ORM (Prisma, Sequelize, Hibernate, SQLAlchemy, etc.)

For other stacks (Go, Rust, PHP, .NET, Ruby, etc.), it builds the integration from OAuth2/OIDC protocol knowledge.

## What Gets Created

| Component | Description |
|-----------|-------------|
| OIDC Client Service | Discovery caching, PKCE, token exchange, refresh, user info |
| Auth Routes | Login, callback, logout, refresh, user info endpoints |
| JWT Middleware | JWKS-based signature validation, expiry check, role extraction |
| Login Page | Dynamic — fetches IdPs, renders form + social buttons, matches your design system |
| Callback Page | Handles auth code exchange, token storage, error display |
| Password Reset | Triggers apptorID forgot-password flow |
| Auth Context | Token state management, protected route guard, auto-refresh |
| HTTP Interceptor | Attaches Bearer token, handles 401 refresh |
| Config | Environment variables, .env.example |
| Tests | Unit + integration tests using your project's test framework |
| Multi-tenant (optional) | DB migration, encryption, tenant resolver |
