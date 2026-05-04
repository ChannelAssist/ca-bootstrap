# Plan: Textual TUI for the setup wizard

> **Status: design proposal, not yet approved.** Follow-up to discussion on 2026-05-04. The four-command CLI (`setup`/`doctor`/`repair`/`undo`) is at v1.2.x and stable; this plan covers replacing the **interactive `setup` wizard's** prompt-and-Read-Host flow with a [Textual](https://github.com/textualize/textual)-based TUI, keeping everything else (doctor JSON, unattended mode, the journal, the four commands) as-is.

## TL;DR

Add a Python sidecar (~5 KLOC) that drives the existing PowerShell wizard via a thin RPC. The user runs `make setup` (unchanged) and gets a Textual TUI; the PowerShell side keeps doing the actual work. Cost: a Python prereq, ~3 weeks of build, ongoing dual-runtime maintenance. Benefit: a much friendlier first-time-user experience — keyboard navigation, scrollable status, live progress bars, error recovery panels — that the line-by-line PowerShell prompt can't approach.

## 1. Why now?

The Read-Host-driven flow has hit a wall:

| Pain point | Current behaviour | Textual would give us |
|---|---|---|
| User can't see context while answering a prompt | Each prompt is a single line; user has to scroll up to remember what step 3 said | Persistent header + step list + transcript pane |
| Long-running steps look frozen | `winget install …` streams its own output then snaps back to a prompt; users assume it hung | Live progress bar + spinner + stream-as-pane |
| Errors mid-step lose context | Failure prints a stack trace, exits | Error panel with structured diagnostics + "retry / skip / quit" buttons |
| Hard to revisit | Quit means lose place; re-running has to walk every check from the top | Resumable: TUI knows journal state, opens at the next un-done step |
| Users on slow terminals see ANSI tearing | The Read-Host + Write-Host interleaving fights with their shell scrollback | Textual owns the screen; clean compositor |

Doctor and the other commands are CLI-shaped and don't need a TUI. Setup is the one that benefits.

## 2. Constraints

- **Cross-platform.** Has to work on Windows, macOS, Linux. Textual itself does; needs a recent Python (3.10+).
- **Hermetic CI** unchanged. Layer-3 wizard subprocess tests today drive setup via `-Unattended -ConfigFile`. The TUI must respect the same flag and skip rendering entirely.
- **Doctor / repair / undo / unattended** stay CLI. The TUI is *only* for interactive `setup`.
- **The journal stays the source of truth.** TUI is a presentation layer; it reads the same journal, calls the same step functions.
- **No new languages on the critical path.** PowerShell stays the implementation language for everything that touches disk, git, gh, package managers. Python is just rendering and event handling.

## 3. Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  pwsh ./ca-bootstrap.ps1 setup                  (existing entrypoint)│
│   │                                                                   │
│   └─ if interactive AND tui-available:                                │
│        spawn pwsh-rpc.py (Python+Textual) ←→ stdin/stdout JSON-RPC    │
│   else:                                                               │
│        existing Read-Host flow (Read-CABConfirm) — unchanged          │
└──────────────────────────────────────────────────────────────────────┘
                              ▲           │
                              │ JSON-RPC  │
                              │ events    │ commands
                              │           ▼
            ┌──────────────────────────────────────────┐
            │  cab-tui (Python 3.10+ / Textual)        │
            │   - prompt rendering                      │
            │   - progress bars / live transcript       │
            │   - keyboard navigation                   │
            │   - error panels with retry/skip          │
            │   - reads journal.yaml for resume state   │
            └──────────────────────────────────────────┘
```

**Key boundary**: PowerShell still does **all** the work. The Python side is a dumb renderer. JSON-RPC over stdio with three message types:

```jsonc
// pwsh → python (request)
{ "type": "prompt", "id": "step-40-use-default", "kind": "confirm",
  "question": "Use default workspace ~/Documents/.../ChannelAssistDev?",
  "default": "yes", "options": ["yes","no","quit"] }

// pwsh → python (event)
{ "type": "step", "phase": "start", "step": "60-repos", "title": "Clone repositories" }
{ "type": "log",  "stream": "stdout", "text": "Cloning ChannelAssist/Keystone..." }
{ "type": "progress", "current": 3, "total": 14, "label": "ChannelAssist/Keystone" }

// python → pwsh (reply)
{ "type": "answer", "id": "step-40-use-default", "value": "yes" }
{ "type": "quit" }    // user pressed Ctrl-Q
```

The protocol is small enough to spec in one page. PowerShell side is a thin `lib/tui-rpc.ps1` that wraps `Read-CABConfirm`/`Read-CABChoice` to dispatch over the protocol when `$Context.TuiMode` is set.

## 4. UI built from Textual's widget gallery

Use Textual's built-in widgets — not hand-rolled approximations. Reference: https://textual.textualize.io/widget_gallery/. Each pane and prompt below maps to a stock widget so we benefit from Textual's accessibility, theming, and keyboard handling rather than duplicating that work.

### Layout

```
╭─ ca-bootstrap setup ─────────────────────────────────────────────────╮  ← Header
│                                                                       │
│  ┌──── Steps ────────┐  ┌──── Active step ─────────────────────────┐ │
│  │                    │  │                                          │ │
│  │  Tree widget       │  │  Question (Static + Markdown)            │ │
│  │  ✓ 1. Welcome      │  │                                          │ │
│  │  ✓ 2. Workspace    │  │  ProgressBar (during clones/installs)    │ │
│  │  ▶ 3. Prereqs      │  │                                          │ │
│  │    ├─ git ✓        │  │  Input (for custom-path prompts)         │ │
│  │    ├─ gh ✓         │  │                                          │ │
│  │    └─ dotnet-10 ✗  │  │  RadioSet / Checkbox (for selections)    │ │
│  │  ○ 4. gh-auth      │  │                                          │ │
│  │  ○ 5. Folders      │  │  Button row: [ Yes ] [ No ] [ Quit ]     │ │
│  │  ○ 6. Repos        │  │                                          │ │
│  │  ○ 7. Identity     │  │                                          │ │
│  │  ○ 8. Extras       │  │                                          │ │
│  └────────────────────┘  └──────────────────────────────────────────┘ │
│                                                                       │
│  ┌──── Transcript (Log widget) ────────────────────────────────────┐ │
│  │ 14:23:08  → Workspace step starting                              │ │
│  │ 14:23:01  Step 1 — User consented to proceed.                    │ │
│  └──────────────────────────────────────────────────────────────────┘ │
│                                                                       │
╰─ q quit · l toggle log · r recover · ? help ─────────────────────────╯  ← Footer
```

### Widget mapping

For every UI element below, we use the named Textual widget from the gallery rather than building one from primitives. Linked anchors point at the widget's gallery entry.

| UI element | Widget | Why this widget |
|---|---|---|
| Step list (left pane) | [`Tree`](https://textual.textualize.io/widgets/tree/) | Native tree expansion / collapse / icons (✓ ▶ ○ ✗). Each step is a top-level node; sub-checks (per-tool, per-repo) are child nodes. Built-in keyboard navigation (↑↓ / left-right / enter). |
| Confirm prompts (`Yes / No / Quit`) | [`Button`](https://textual.textualize.io/widgets/button/) row | Stock button styling, focus ring, mouse-clickable, Enter activates. Variant `success` for Yes, `default` for No, `error` for Quit. |
| Multi-choice prompts (`[Y / n / select]`) | [`RadioSet`](https://textual.textualize.io/widgets/radioset/) of [`RadioButton`](https://textual.textualize.io/widgets/radiobutton/) | Single-select with arrow-key navigation; pressing space toggles. Replaces the text-line `[Y/n/select]` mess. |
| Per-repo opt-in checkboxes | [`Checkbox`](https://textual.textualize.io/widgets/checkbox/) | The user can scroll through 14 repo checkboxes and toggle each — much friendlier than 14 separate `[y/N]` line prompts. |
| Heavy-install opt-in toggle (Docker, WSL) | [`Switch`](https://textual.textualize.io/widgets/switch/) | The "are you sure" affordance for irreversible installs. |
| Custom workspace path entry | [`Input`](https://textual.textualize.io/widgets/input/) with [`SelectionList`](https://textual.textualize.io/widgets/selection_list/) recent-paths | `Input` for typing; `SelectionList` shows recent paths from the journal. |
| Prereq table (tool / version / required / status) | [`DataTable`](https://textual.textualize.io/widgets/data_table/) | Sortable, scrollable, color-codable rows. Replaces the eight-line dot-status output today. |
| Welcome screen body | [`MarkdownViewer`](https://textual.textualize.io/widgets/markdown_viewer/) | Renders the existing welcome copy with bold / lists / links — no string-concat templating. |
| Transcript pane | [`Log`](https://textual.textualize.io/widgets/log/) | Append-only, auto-scroll, color spans, line wrapping handled. Doesn't need to be reimplemented as a `Static` with manual scroll. |
| Long-running step progress | [`ProgressBar`](https://textual.textualize.io/widgets/progress_bar/) | Clone-of-N-of-M, install percentages. |
| Per-tool spinners during install | [`LoadingIndicator`](https://textual.textualize.io/widgets/loading_indicator/) | One per active install; sits in the active-step pane next to the tool name. |
| Switching between Steps / Transcript / Doctor | [`Tabs`](https://textual.textualize.io/widgets/tabs/) + [`TabbedContent`](https://textual.textualize.io/widgets/tabbed_content/) | `Steps` ↔ `Transcript` ↔ `Doctor report` views without rebuilding the layout. |
| Top chrome | [`Header`](https://textual.textualize.io/widgets/header/) | Title + clock + version. |
| Bottom chrome | [`Footer`](https://textual.textualize.io/widgets/footer/) | Auto-displays bound keys. |
| Error / warning toasts | [Toast notifications via `app.notify()`](https://textual.textualize.io/api/app/#textual.app.App.notify) | Built-in with severity levels. |

### Hard rule

**Don't reinvent any of the above.** If a UI need doesn't have a stock Textual widget, that's a signal to either (a) compose existing widgets, (b) check the gallery again with different terms, or (c) raise it as an open question rather than building a custom widget. Custom widgets are a last resort because they accumulate maintenance burden and miss accessibility / theme / keyboard work that Textual's stock widgets get for free.

The full gallery is curated and screenshot/animation-rich at https://textual.textualize.io/widget_gallery/ — review it before designing any new screen.

## 5. Resumability

Today: re-running setup walks every step's Test function from the top.

With TUI: same, but the resumed UI opens at the first non-`ok` step. Steps already complete are shown ✓ and collapsed. The user immediately sees "this is what's left." Backed by the existing journal — no new state to track.

## 6. Build sequence

| Phase | Deliverable | Effort |
|---|---|---|
| 1 | `cab-tui/` Python package skeleton; pyproject.toml; pinned Textual; app shell composed from `Header` + `Tree` + `TabbedContent` + `Log` + `Footer` (no custom widgets) | 1 day |
| 2 | JSON-RPC protocol spec doc; `lib/tui-rpc.ps1` (pwsh side) handling `prompt`/`step`/`log`/`progress`/`answer`/`quit`; `cab-tui/rpc.py` (py side) | 2 days |
| 3 | Wire `Read-CABConfirm` / `Read-CABChoice` to dispatch through tui-rpc when `$Context.TuiMode` is true; pwsh prompts render as `Button` / `RadioSet` / `Checkbox` / `Input` per the §4 widget map; existing Read-Host path stays as fallback | 1 day |
| 4 | Step-list pane: `Tree` widget driven by journal events (✓ / ▶ / ○ / ✗ icons via Tree node labels) | 1 day |
| 5 | Long-running-step support: `ProgressBar` for step 60 (cloning), `Log` widget for step 20 install output, `LoadingIndicator` per tool | 2 days |
| 6 | Error recovery: `app.notify()` for transient warnings; full-screen panel using `Container` + `Button` row (`Retry / Skip / Quit / View transcript`) for hard fails | 1 day |
| 7 | Auto-detect: orchestrator launches TUI when (a) interactive, (b) `python3 -m cab_tui --check` succeeds, (c) `--no-tui` not set; otherwise falls back to current Read-Host flow | 1 day |
| 8 | Make-target plumbing: `make setup` runs the TUI; `make setup-no-tui` keeps the old flow for debugging | 0.5 day |
| 9 | Tests: Textual has a snapshot-test framework; record golden TUIs for each step's prompt screen, error panel, completion screen; the existing wizard subprocess tests stay since they use `-Unattended` | 2 days |
| 10 | Docs: `docs/tui.md` covering keyboard shortcuts, accessibility, fall-back behaviour | 0.5 day |
| 11 | Distribution: `cab-tui` ships as a sidecar in the repo; `bootstrap.sh` / `bootstrap.ps1` install Python 3.10+ and `pip install -e cab-tui/` if missing | 1 day |
| 12 | Pester suite + integration tests + tagged release | 2 days |

**Total**: ~14 dev-days. Critical-path serial; only phases 4/5/9 can parallelize.

## 7. Open questions

1. **Python prereq.** ca-bootstrap currently installs Python 3.12 only as an *optional* prereq for cm-claims-validator. With TUI, Python becomes effectively required for interactive setup. Three options:
   - Bundle Python via [Briefcase](https://briefcase.readthedocs.io/) → `cab-tui` ships as a single binary, no Python prereq; bigger artefact (~30 MB)
   - Install Python 3.10+ unconditionally as a setup prereq → small artefact, one extra ~50 MB install
   - Keep Python optional, fall back to current Read-Host flow when missing → most flexible, but the old flow keeps living forever
   
   Recommendation: option 3 for v2.0.0, option 1 for v3.0.0 once the TUI is the default.

2. **Windows terminal compatibility.** Textual works in modern Windows Terminal but degrades gracefully in cmd.exe (no truecolor, limited unicode). We document Windows Terminal as the supported environment; legacy cmd.exe users see the Read-Host fallback.

3. **Accessibility.** Textual supports screen readers via TermSCP and has keyboard-only navigation. We commit to keyboard-only as the primary path; mouse is ergonomic but never required.

4. **What about doctor's `--json` output?** Stays untouched. The TUI is for interactive setup only.

5. **Internationalization.** ca-bootstrap is English-only today. The TUI keeps it English-only for v2.0.0; i18n is a v3.0.0 question.

6. **Is JSON-RPC over stdio reliable on Windows?** Yes — it's the same mechanism the Language Server Protocol uses. The risk is buffering; we use line-delimited JSON with explicit flushes on both ends.

## 8. What we don't change

- The four-command shape (`setup`/`doctor`/`repair`/`undo`).
- The journal format and lifecycle.
- The manifest YAML schemas.
- The test-mode seam (`CA_BOOTSTRAP_TEST_*` env vars).
- The unattended mode (still YAML-driven, no TUI involvement).
- Any existing Pester test (the TUI is additive; current tests still run against the Read-Host fallback).

## 9. Rejected alternatives

- **Rewrite the wizard in Python entirely.** Higher cost, throws away the steady-state PowerShell layer that's now well-tested. We'd be debugging across two languages instead of one.
- **PowerShell-native TUI library.** Spectre.Console.PowerShell, ConsoleZ, etc. exist but are immature on macOS/Linux and don't reach Textual's quality. Not a sustainable choice.
- **Web UI launched on localhost.** Strictly more capable than a TUI, but introduces a browser dependency, a port-binding dance, and a security surface. Not worth it for the use case.
- **Inquirer / fzf / fzf-style overlays.** Lightweight, but they don't handle the long-running-step / live-progress case Textual does.

## 10. Acceptance criteria

The TUI ships when:

1. `make setup` on a fresh machine produces the TUI and walks through to a clean exit.
2. `make setup` falls back to Read-Host when Python isn't installed, with a one-line "install Python for the better experience" hint.
3. `make setup -Unattended -ConfigFile <path>` doesn't invoke the TUI at all (CI path unchanged).
4. The Textual snapshot tests cover at least: welcome, workspace prompt, repos list, error panel, completion screen.
5. All existing Pester tests still pass.
6. The Read-Host fallback still passes the existing wizard subprocess tests.
7. A user can resume an interrupted setup (Ctrl-C, machine sleep, etc.) and the TUI opens at the right step.
8. Doctor / repair / undo unchanged.

## 11. Recommendation

**Defer to v2.0.0** — this is a quality-of-life win, not a correctness fix. The current four-command CLI works, has 54+ tests, ships on three OSes. We're at the point where v1.x is stable and reliable; bundling a TUI is a project of its own that deserves its own release line.

Concrete proposal:
- v1.x continues with bug fixes and small features (current pace)
- Open a `feature/textual-tui` long-lived branch for the TUI build
- Cut `v2.0.0-alpha.1` when phases 1-7 are done
- `v2.0.0` ships when phases 1-12 + 7+ days of internal dogfooding pass without regression

---

*End of plan. Sign off, then create the feature branch.*
