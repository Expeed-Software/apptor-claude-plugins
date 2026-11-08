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
claude plugin install apptorID

# Or directly:
claude plugin install https://github.com/expeedsoftware/apptor-claude-plugins/plugins/apptorID
```

## Configure

When the plugin is enabled, Claude Code asks for three values:

| Option | Notes |
|---|---|
| apptorID MCP URL | Defaults to sandbox, `https://master.sandbox.auth.apptor.io/mcp`. Production: `https://master.auth.apptor.io/mcp` |
| Access key ID | Needed for the MCP tools |
| Access key secret | Needed for the MCP tools. Masked, kept in Claude Code's credential store, not in `settings.json` |

No environment variables are needed.

### Change a value later (e.g. switch sandbox → production, rotate the key)

- **In Claude Code:** `/plugin` → **Installed** → `apptorID` → **Configure options**, edit, then `/reload-plugins`. The URL and key ID can also be edited in `/config`; the secret only through **Configure options**.
- **From a shell:**
  ```bash
  claude plugin configure apptorID@apptor-claude-plugins            # show current options
  echo '{"mcp_url":"https://master.auth.apptor.io/mcp"}' | claude plugin configure apptorID@apptor-claude-plugins --values-stdin
  ```
  Options left out of the JSON keep their values. Restart Claude Code afterwards.

### Upgrading from 1.x

1.1.x read `APPTOR_ACCESS_KEY_ID`, `APPTOR_ACCESS_KEY_SECRET` and `APPTOR_MCP_URL` from the environment. 2.0.0 no longer reads them: enter the values once in **Configure options**, then the environment variables can be removed.

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
