<!--
ChannelAssist canonical PR template — SDLC Policy v26.5 §5.7.6.

Work through each section before requesting review. CI gates several
of these automatically (Conventional Commits, AB# reference, signed
commits, label taxonomy); the rest are reviewer judgement.

Source of truth: cm-platform-infra/templates/pull_request_template.md
(propagated via `make pr-template-sync-all`).
-->

## Summary

<!-- 1–3 sentences describing **why** this change exists, not what changed.
     The diff shows what; the body answers why. -->

## Refs

- Refs: AB#<azure-devops-id>  <!-- Required by SDLC §5.7.6 step 4 and enforced by the `ADO ↔ GitHub Bridge / Require AB#` check. Use AB#38056 (AI Platform umbrella) only if no specific child work item exists. -->
- Related issue(s): #<github-issue-number>
- ADR (if architecture-affecting): docs/adr/ADR-XXXX-...

## Change type

<!-- Pick one — drives label assignment + reviewer routing (SDLC §5.7.1, §5.7.2). -->

- [ ] `feat` — new feature
- [ ] `fix` — bug fix
- [ ] `chore` — non-functional (deps, infra, tooling)
- [ ] `refactor` — internal improvement, no behaviour change
- [ ] `docs` — documentation only
- [ ] `test` — test additions / fixes only
- [ ] `perf` — performance improvement
- [ ] `ci` — CI/workflow changes
- [ ] `style` — formatting only
- [ ] `revert` — reverts a previous commit
- [ ] **Breaking change** — append `!` after the type in commit; add `breaking-change` label

## Test plan

<!-- Bullet list of how a reviewer (human or Copilot) verifies this works.
     Be specific — `npm test` is not a test plan. -->

- [ ]

## SDLC §5.7.6 compliance

### Creating the PR
- [ ] Branch named `feature/<desc>-AB#<id>` or `bugfix/<desc>-AB#<id>` (SDLC §5.7)
- [ ] Title matches Conventional Commits format, under 72 chars (SDLC §5.7.1)
- [ ] Commits **signed** (`git commit -S`) and **bisected** (one logical change per commit, SDLC §5.7.5)
- [ ] Canonical-taxonomy labels applied (run `make labels-sync` first if missing); `ai-assisted` if any AI tooling was used (SDLC §8.7)
- [ ] Draft status only if work-in-progress — convert to **Ready for review** only when all commits are final

### CI gate (SDLC §5.7.6 step 7)
- [ ] All required status checks **green** before requesting review (build, test, lint, commitlint, secret scan, AB# reference, security scan, dependency review). CI failure blocks merge regardless of approval.

### Reviewers (SDLC §5.7.6 "Reviewer Assignment" + "Automated Code Review")
- [ ] At least one reviewer assigned (CODEOWNERS auto-assigns when applicable)
- [ ] Copilot will auto-review on default-branch PRs. **Address substantive Copilot findings (code change + thread reply + thread resolve) before approval.** Trivial findings still get a reply (no silent resolves).
- [ ] If Copilot review fails to materialise after a push: cancel + re-request via `gh api -X DELETE repos/{owner}/{repo}/pulls/{n}/requested_reviewers -f 'reviewers[]=Copilot'` then `POST`.

### Review-fix iteration (SDLC §5.7.6 "Review-Fix Iteration")
- [ ] After each push: reply to each affected review thread with the addressing SHA, resolve, and re-request the reviewer.
- [ ] **`APPROVED` on the *latest* commit** is the merge gate. `COMMENTED` reviews and reviews against superseded commits do not count, even if they appear approved in the GitHub UI.
- [ ] Polling silence is **not** approval — drive each cycle to `APPROVED` against the latest commit.

### Post-merge (SDLC §5.7.6 "Post-Merge Cleanup")
<!-- Most steps are automated; this is here as a reminder for the merger. -->
- Feature branch will be auto-deleted on merge (configured per repo)
- ADO bridge will transition the linked work item (verify in the bridge's "Sync ADO work item state" job)
- GitHub Projects v2 board card will auto-move to terminal state (SS8.11 / ADR-0021)

## AI assistance (SDLC §8.7)

<!-- Required if any AI tool (Claude, Copilot, Codex, Cursor, etc.) generated
     or modified code in this PR. Apply the `ai-assisted` label and add the
     co-authorship footer below to each commit it touched. -->

- [ ] No AI assistance used (skip the rest)
- [ ] AI-generated code has been **reviewed for correctness** (do not blindly trust AI output)
- [ ] AI-generated code has been **tested** (existing or new tests)
- [ ] Sensitive data / proprietary logic was **NOT** exposed to AI tools (SDLC §8.5 Data Classification)
- [ ] Only approved AI tools used (SDLC §8.4)
- [ ] No hallucinated APIs, libraries, or fabricated dependencies present
- [ ] License compliance verified — no incompatible OSS introduced via AI suggestions
- [ ] For agentic AI workflows (multi-step autonomous agents): session log reviewed; agent access was appropriately scoped (SDLC §8.6)
- [ ] Commit footer present for each AI-touched commit:

```
Co-Authored-By: <Tool + model> <noreply@anthropic.com>
```

## Security checklist (when applicable — auth, crypto, external APIs, secrets)

- [ ] Input validation — all user inputs sanitised
- [ ] SQL injection — parameterised queries only
- [ ] Secrets — no API keys, tokens, or passwords in code or commit history
- [ ] Authorization — server-side checks (do not rely on UI-only gates)
- [ ] Error handling — no stack traces or sensitive info leaked to clients
- [ ] Container config (if Dockerfile changed) — distroless base, non-root user
- [ ] OpenAPI/schema versioning — MAJOR bump requires an ADR (SDLC §5.10)

## Reviewer notes

<!-- Anything reviewers should pay special attention to — architecture
     decisions, performance trade-offs, security implications, deployment
     ordering, etc. -->
