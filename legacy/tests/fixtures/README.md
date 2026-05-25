# Test fixtures

## `smoke-answers.txt`

Sequential answers consumed by Read-Host during `make smoke`. Assumes a developer-class host where all prerequisite tools are already installed (so step 20 reports ✓ and never prompts for installs).

On a host with missing tools, step 20 will prompt and consume one of these lines, shifting all subsequent answers — the test will misbehave. For hermetic CI use `-Unattended -ConfigFile <answers.yaml>` (phase 11), where every prompt has a named answer key and order doesn't matter.

Current answer order (host with all tools installed AND already gh-authed):

| # | Step | Answer | Meaning |
|---|---|---|---|
| 1 | 10-welcome | `y` | continue |
| 2 | 40-workspace | `y` | use default workspace path |
| 3 | 50-folders | `y` | create the four standard folders |
| 4 | 60-repos / docs | `y` | clone all 3 docs repos |
| 5 | 60-repos / ca-platform | `n` | skip in smoke test |
| 6 | 60-repos / cm-product | `n` | skip in smoke test |
| 7 | 70-git-identity | `n` | skip — don't touch the real ~/.gitconfig |
| 8 | 80-extras / VS Code workspace file | `y` | write ChannelAssist.code-workspace |

Step 80 has three other prompts that are gated and **don't fire** in the smoke scenario, so no `smoke-answers.txt` line is consumed for them:

- `ca-claude-plugin` link — gated on `ca-platform/ca-claude-plugin` being cloned; smoke skips the ca-platform group (row 5) so the repo is absent.
- `ca-copilot-plugin` usage notes — gated on `ca-platform/ca-copilot-plugin`; same reason.
- WSL2 + Ubuntu install — Windows-only branch; CI runs on Linux/macOS.

Steps 20 (prereqs install) and 30 (gh auth) are silent on a fully-provisioned host.
