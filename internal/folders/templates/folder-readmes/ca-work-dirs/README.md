# ca-work-dirs

Working directories for **Claude Code worktrees**, **Claude Cowork sessions**,
and general scratch clones. This is your scratch space — anything that's
ephemeral, parallel to a primary clone, or owned by an AI workflow lives
here.

## When to use it

### Claude Code worktrees

Create a git worktree off any repo to run a parallel Claude Code session on
a separate branch without disturbing your primary clone:

```bash
# From <workspace> root:
git -C ca-platform/ca-claude-plugin worktree add \
    ca-work-dirs/ca-claude-plugin-experiment feature/experiment
cd ca-work-dirs/ca-claude-plugin-experiment
claude
```

Convention: worktree path = `<workspace>/ca-work-dirs/<repo>-<topic>/`.

### Claude Cowork

Cowork manages its own sub-folders here. Each Cowork session typically
creates one directory keyed to the run id. **Do not delete sub-folders
under `ca-work-dirs/` without first checking the owning Cowork session —
the contents may be live state.**

### General scratch

Throwaway clones, branch experiments, dependency-bump trials, anything
that doesn't belong under the canonical `ca-*` / `cm-*` folders.

## Tree

```
ca-work-dirs/
├── <repo>-<topic>/        # convention: git worktrees off your primary clones
├── cowork-<run-id>/       # convention: Claude Cowork session work-dirs
└── scratch-*/             # convention: ad-hoc scratch clones
```

(All subdirectories are user/tool-created — none are seeded by ca-bootstrap.)

## Safety

**Do not delete `ca-work-dirs/` or any of its sub-folders without
checking what's inside.** Sub-folders may belong to:

- An active Claude Cowork session.
- A git worktree (deleting it leaves the parent repo's `.git/worktrees/`
  entry stale — use `git worktree remove` instead).
- An IDE-managed scratch checkout.

`ca-bootstrap` honors this and **will not auto-delete this folder or its
contents**. Any repair / undo flow that would remove a non-empty folder
or a folder containing sub-folders requires an explicit confirmation
prompt. See the safety contract in
[`commands.md`](https://github.com/ChannelAssist/ca-bootstrap/blob/dev/docs/commands.md) for the full rules.

## Refresh

Refresh this README via `ca-bootstrap.ps1 repair --target folder-readmes`.
