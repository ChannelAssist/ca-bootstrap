# ca-platform-repo

ChannelAssist platform-wide services. Cross-product capabilities that any
business unit can consume — they share the `ca-*` repo prefix.

## What lives here

- `ca-ai-agents` — shared AI agent definitions and prompts.
- `ca-claude-plugin` — the Claude Code plugin (commands, hooks, agents).
- `ca-copilot-plugin` — the GitHub Copilot custom agents + prompts.
- `ca-data-dictionnary-generator` — data-dictionary build tool.
- `ca-privacy-gate` — privacy gateway service.

## Tree

```
ca-platform-repo/
├── ca-ai-agents/
├── ca-claude-plugin/
├── ca-copilot-plugin/
├── ca-data-dictionnary-generator/
└── ca-privacy-gate/
```

## Refresh

Refresh this README via `ca-bootstrap.ps1 repair --target folder-readmes`.
