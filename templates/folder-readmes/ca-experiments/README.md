# ca-experiments

Internal experiments and prototypes — opt-in, not part of the default
workspace. If you need a place to spike something that's bigger than a
scratch worktree but isn't ready to live under `ca-platform/` or
`cm-product/` yet, this is the home.

This folder is **optional** and is only created when you opt in during
`ca-bootstrap.ps1 setup`.

## What lives here

- `command-center` — opt-in clone of `ChannelAssist/command-center`.

## Tree

```
ca-experiments/
└── command-center/
```

## Safety

If you've added sub-projects under `ca-experiments/` outside the manifest,
they belong to **you** — ca-bootstrap will not delete this folder or its
contents without an explicit confirmation prompt. See the [safety contract](https://github.com/ChannelAssist/ca-bootstrap/blob/dev/docs/commands.md) for the full rules.

## Refresh

Refresh this README via `ca-bootstrap.ps1 repair --target folder-readmes`.
