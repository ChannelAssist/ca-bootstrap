# Manual Actions Required

This document tracks actions that require manual intervention by a maintainer with elevated permissions.

## Repository Deletion: demo-repository

**Status:** Pending manual action

**Issue:** Delete `ChannelAssist/demo-repository` (GitHub starter template)

### Context

The `ca-bootstrap.ps1 manifest-drift` command surfaced `ChannelAssist/demo-repository` as a repository that exists in the ChannelAssist GitHub organization but is not listed in `manifest/repos.yaml`.

According to the repository metadata:
- **Description:** "A code repository designed to show the best GitHub has to offer."
- **Size:** 5 KB
- **Default branch:** `dev`
- **Created:** 2026-02-05

This is the GitHub starter template and is not part of the bootstrap-managed development workspace. It should not remain in the organization long-term.

### Required Action

A maintainer with appropriate GitHub permissions must delete the repository using one of the following methods:

#### Option 1: GitHub CLI

```bash
# Refresh authentication with delete_repo scope
gh auth refresh -h github.com -s delete_repo

# Delete the repository
gh repo delete ChannelAssist/demo-repository --yes
```

#### Option 2: GitHub Web UI

1. Navigate to https://github.com/ChannelAssist/demo-repository/settings
2. Scroll to the "Danger Zone" section at the bottom
3. Click "Delete this repository"
4. Follow the confirmation prompts

### Why This Cannot Be Automated

The CI `GITHUB_TOKEN` used in autonomous workflows intentionally lacks the `delete_repo` scope, following the principle of least privilege. Repository deletion is a destructive action that requires explicit maintainer authorization.

### Verification

After the repository is deleted, verify by running:

```bash
make manifest-drift
```

The output should no longer list `ChannelAssist/demo-repository` under "missing" (repos on GitHub but not in manifest).

### Acceptance Criteria

- [x] Documentation created for manual action
- [ ] `ChannelAssist/demo-repository` is deleted on GitHub (requires maintainer)
- [ ] `make manifest-drift` no longer reports the repository

---

**Last Updated:** 2026-05-07
**Tracking Issue:** Delete ChannelAssist/demo-repository
