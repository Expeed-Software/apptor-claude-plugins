# apptor Claude Plugins

Claude Code plugins for the [apptor](https://apptor.io) ecosystem.

## Available Plugins

| Plugin | Description |
|--------|-------------|
| [apptorID](plugins/apptorID/) | Integrate apptorID (OAuth2/OIDC) authentication into any application |
| [expeed-review-protocol](plugins/expeed-review-protocol/) | Mandatory three-tier review gate — blocks "done" and `git push` until the tier-appropriate checklist (L1, smoke test, cross-layer contract check, adversarial review, Tier 3 runbook/rollback) is filled with real evidence |

## Install

Inside Claude Code (recommended — slash commands):

```
/plugin marketplace add https://github.com/expeedsoftware/apptor-claude-plugins
/plugin install apptorID
```

Or from the shell via the Claude Code CLI:

```bash
claude plugin marketplace add https://github.com/expeedsoftware/apptor-claude-plugins
claude plugin install apptorID
```

## Configuration

Each plugin may require environment variables. See the individual plugin READMEs for details.

## About

Built and maintained by [Expeed Software](https://expeed.com).
