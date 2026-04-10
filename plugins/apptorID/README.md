# apptorID — Claude Code Plugin

Integrate [apptorID](https://apptor.io) (OAuth2/OIDC) authentication into any application using Claude Code.

## Skills

| Skill | Trigger | What It Does |
|-------|---------|-------------|
| `apptorID:setup` | "add auth", "login", "SSO" | Full auth integration — explores codebase, provisions via MCP, writes all code, tests |
| `apptorID:user-management` | "create user", "manage users" | User CRUD endpoints with admin API + orgRefId/userRefId wiring |
| `apptorID:forgot-password` | "forgot password", "reset password" | Password reset flow + reset page UI |
| `apptorID:manage` | "configure email", "create realm" | MCP operations for ongoing apptorID management |

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

Just tell Claude what you want:

```
> Add apptorID authentication to my app

> Set up user management with orgRefId mapping

> Add forgot password flow

> Configure email templates for my realm
```

Each skill explores your codebase, asks one question at a time (interactive format), and writes production-ready code.

## Works Without MCP Too

Without access keys, the skills still work — they generate integration code with placeholder credentials and guide you through manual setup.

## Supported Tech Stacks

Works with **any** tech stack. Deep reference knowledge for:
- **Backend**: Java/Spring, Java/Micronaut, Node/Express, Python/FastAPI
- **Frontend**: React, Angular
- **Multi-tenant**: Any ORM

For other stacks, builds from OAuth2/OIDC protocol knowledge.
