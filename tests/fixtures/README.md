# Test fixtures

## `smoke-answers.txt`

Sequential answers consumed by Read-Host during `make smoke`. Assumes a developer-class host where all prerequisite tools are already installed (so step 20 reports ✓ and never prompts for installs).

On a host with missing tools, step 20 will prompt and consume one of these lines, shifting all subsequent answers — the test will misbehave. For hermetic CI use `-Unattended -ConfigFile <answers.yaml>` (phase 11), where every prompt has a named answer key and order doesn't matter.

Current answer order (host with all tools installed):

| # | Step | Answer | Meaning |
|---|---|---|---|
| 1 | 10-welcome | `y` | continue |
| 2 | 40-workspace | `y` | use default workspace path |
| 3 | 50-folders | `y` | create the four standard folders |
| 4 | 60-repos / docs | `y` | clone all 3 docs repos |
| 5 | 60-repos / ca-platform | `n` | skip in smoke test |
| 6 | 60-repos / cm-product | `n` | skip in smoke test |
