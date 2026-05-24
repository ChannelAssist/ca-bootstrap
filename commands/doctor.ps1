#requires -Version 7.0
# commands/doctor.ps1 — diagnostic-only run.
#
# Phase 8 implementation. Walks every step's Test function and the journal
# to produce a green/yellow/red report. Never modifies anything.
#
# Output formats:
#   default     human-readable
#   --json      structured JSON for CI / scripting
#   --summary   one-line per check
#
# Exit codes (per docs/commands.md):
#   0   everything ✓
#   2   any ⚠ or ✗ found
#  99   unexpected error

# Auto-source lib dependencies when dot-sourced standalone (e.g. Pester).
# The main orchestrator loads all libs before dot-sourcing this file, so
# these guards are no-ops in that path.
foreach ($__libDep in @(
    @{ cmd = 'Get-CABOSFamily';          file = 'platform.ps1' }
    @{ cmd = 'Get-CABToolReport';        file = 'tools.ps1'    }
    @{ cmd = 'Test-CABRepoCloned';       file = 'git-ops.ps1'  }
    @{ cmd = 'Get-CABFolderRenamedFrom'; file = 'folders.ps1'  }
)) {
    if (-not (Get-Command $__libDep.cmd -ErrorAction SilentlyContinue)) {
        $__p = Join-Path $PSScriptRoot "../lib/$($__libDep.file)"
        if (Test-Path $__p) { . $__p }
    }
}
Remove-Variable __libDep, __p -ErrorAction SilentlyContinue

# Invoke-CABDoctorCheck — produce the full check list. Returns an array of
# [ordered]@{ id; status; details; ...extra }.
function Invoke-CABDoctorCheck {
    [CmdletBinding()]
    param([hashtable]$Context)

    $checks = New-Object System.Collections.Generic.List[hashtable]

    # ----- Workspace -----
    $workspace = $null
    # Prefer an explicit WorkspacePath in $Context (set by test harnesses and
    # repair) so the journal-state lookup is bypassed entirely. This avoids
    # stale in-memory journal entries from earlier Pester test cases pointing
    # at temp dirs that no longer exist, which would cause Test-Path $workspace
    # to return $false and silently skip every workspace-gated check.
    if ($Context.WorkspacePath) {
        $workspace = $Context.WorkspacePath
    } else {
    # Most-recent non-undone entry wins. Get-CABJournalEntry walks
    # sessions oldest-first and returns them in that order, so [0] is the
    # OLDEST surviving record — which after a default-path change reads
    # back the previous default and reports a stale "missing" workspace
    # even when setup just finished writing to the new one. Take [-1] so
    # doctor reflects the workspace the most recent setup chose.
    #
    # Prefer select_workspace over create_folder. select_workspace is
    # emitted on every setup run (created or existing); create_folder is
    # only emitted when 40-workspace actually mkdirs — so a setup against
    # an existing path used to leave no record at all and doctor would
    # surface a stale earlier choice. The create_folder fallback is kept
    # for journals written before the select_workspace action existed.
    $workspaceEntries = @(Get-CABJournalEntry -Action 'select_workspace' -Step '40-workspace')
    if ($workspaceEntries.Count -eq 0) {
        $workspaceEntries = @(Get-CABJournalEntry -Action 'create_folder' -Step '40-workspace' |
            Where-Object { try { [bool]$_.is_workspace_root } catch { $false } })
    }
    if ($workspaceEntries.Count -gt 0) {
        $workspace = [string]$workspaceEntries[-1].path
    } elseif ($env:CA_BOOTSTRAP_WORKSPACE) {
        $workspace = $env:CA_BOOTSTRAP_WORKSPACE
    } else {
        # Best-effort default mirroring Get-CABDefaultWorkspacePath in
        # steps/40-workspace.ps1: prefer Documents/ when it exists,
        # otherwise root at <profile>/Projects/ for headless boxes.
        $profileDir = if ($IsWindows) { $env:USERPROFILE } else { $HOME }
        $docsDir = Join-Path $profileDir 'Documents'
        $sub = if (Test-Path $docsDir -PathType Container) {
            if ($IsWindows) { 'Documents\Projects\ChannelAssistDev' } else { 'Documents/Projects/ChannelAssistDev' }
        } else {
            if ($IsWindows) { 'Projects\ChannelAssistDev' } else { 'Projects/ChannelAssistDev' }
        }
        $workspace = Join-Path $profileDir $sub
    }
    } # end else ($Context.WorkspacePath was not pre-set)
    $Context.WorkspacePath = $workspace

    if (Test-Path $workspace) {
        $checks.Add([ordered]@{ id = 'workspace'; status = 'ok'; details = "exists at $workspace"; path = $workspace })
    } else {
        $checks.Add([ordered]@{ id = 'workspace'; status = 'fail'; details = "missing: $workspace"; path = $workspace; fix = 'setup' })
    }

    # ----- Folders -----
    if (Test-Path $workspace) {
        # Union of both branches:
        # - dev's Read-CABManifest -Quiet (suppress chatty load output)
        # - dev's try/catch on the .optional filter (defensive against
        #   missing key in a contributor-authored folders.yaml)
        # - dev's -PathType Container check (folder, not file)
        # - this branch's renamed_from chain walk so doctor can
        #   distinguish a skipped migration from genuine missing folders
        $manifest = Read-CABManifest -Path (Join-Path $Context.RepoRoot 'manifest/folders.yaml') -Quiet
        $expected = @($manifest.folders | Where-Object {
            try { -not $_.optional } catch { $true }
        })
        # Classify each required folder into one of three buckets,
        # mirroring Invoke-CABStep50's execution branches in priority
        # order: (a) present as directory, (b) collision — exists but
        # NOT a directory, (c) genuinely missing. Without distinguishing
        # collisions from missing, a regular file at the required path
        # would land in $missing → the predecessor walk would render
        # `folder(s) need rename` + `repair --target folders` as a safe
        # fix, but Invoke-CABStep50 would fail before renaming with
        # "exists but is not a directory". Doctor and step would
        # diverge on a blocking collision. PR #82 cycle-3 review.
        $present     = New-Object System.Collections.Generic.List[hashtable]
        $collisions  = New-Object System.Collections.Generic.List[string]
        $candidates  = New-Object System.Collections.Generic.List[hashtable]
        foreach ($f in $expected) {
            $target = Join-Path $workspace $f.path
            if (Test-Path $target -PathType Container) {
                $present.Add(@{ path = [string]$f.path }) | Out-Null
            } elseif (Test-Path $target) {
                $collisions.Add([string]$f.path) | Out-Null
            } else {
                $candidates.Add($f) | Out-Null
            }
        }

        # Of the genuinely-missing candidates, see which have a
        # predecessor on disk via renamed_from (scalar or list, walked
        # most-recent → oldest). Those become "needs rename"; the rest
        # stay missing. Repair walks the same chain.
        $renames      = New-Object System.Collections.Generic.List[hashtable]
        $stillMissing = New-Object System.Collections.Generic.List[string]
        foreach ($f in $candidates) {
            $predecessors = @(Get-CABFolderRenamedFrom -Folder $f)
            $found = $null
            foreach ($prev in $predecessors) {
                if (Test-Path (Join-Path $workspace $prev) -PathType Container) { $found = $prev; break }
            }
            if ($found) {
                $renames.Add(@{ path = [string]$f.path; from = $found })
            } else {
                $stillMissing.Add([string]$f.path)
            }
        }

        if ($collisions.Count -eq 0 -and $stillMissing.Count -eq 0 -and $renames.Count -eq 0) {
            $checks.Add([ordered]@{ id = 'folders'; status = 'ok'; details = "$($present.Count)/$($expected.Count) present" })
        } elseif ($collisions.Count -gt 0) {
            # Collisions are always 'fail' — Invoke-CABStep50 cannot
            # repair them, so flagging this as anything softer would
            # mis-advertise the recovery path.
            $detail = "$($collisions.Count) collision(s) (exists but not a directory): $($collisions -join ', ')"
            if ($stillMissing.Count -gt 0) {
                $detail += "; $($stillMissing.Count) missing: $($stillMissing -join ', ')"
            }
            if ($renames.Count -gt 0) {
                $renameSummary = ($renames | ForEach-Object { "$($_.from) → $($_.path)" }) -join ', '
                $detail += "; $($renames.Count) need rename: $renameSummary"
            }
            $checks.Add([ordered]@{
                id = 'folders'; status = 'fail'
                details = $detail
                # Deliberately no `fix` field — collisions require
                # manual resolution before any repair target applies.
                collisions = $collisions.ToArray()
                renames    = $renames.ToArray()
            })
        } elseif ($stillMissing.Count -eq 0) {
            $renameSummary = ($renames | ForEach-Object { "$($_.from) → $($_.path)" }) -join ', '
            $checks.Add([ordered]@{
                id = 'folders'; status = 'warn'
                details = "$($renames.Count) folder(s) need rename: $renameSummary"
                fix = 'repair --target folders'
                renames = $renames.ToArray()
            })
        } else {
            $detail = "$($stillMissing.Count)/$($expected.Count) missing: $($stillMissing -join ', ')"
            if ($renames.Count -gt 0) {
                $renameSummary = ($renames | ForEach-Object { "$($_.from) → $($_.path)" }) -join ', '
                $detail += "; $($renames.Count) need rename: $renameSummary"
            }
            $checks.Add([ordered]@{
                id = 'folders'; status = 'fail'
                details = $detail
                fix = 'repair --target folders'
                renames = $renames.ToArray()
            })
        }
    }

    # ----- Folder renames -----
    # Data-driven from `renamed_from:` in manifest/folders.yaml. Doctor
    # detects drift (legacy folder still present) and points at
    # `repair --target folder-renames` for the safe fix. Repair honors the
    # safety contract: empty legacy → silent rename; non-empty → prompt;
    # both with content → bail to manual.
    #
    # PR #82 generalized `renamed_from` to scalar-or-list (a chain of
    # historical names, most-recent → oldest). The cleanup check below
    # iterates the full chain via Get-CABFolderRenamedFrom, emitting one
    # check per predecessor still on disk. A direct `[string]$f.renamed_from`
    # cast would have produced "a b" for a list and silently failed to
    # detect any leftover, including the case where the new path already
    # exists but an older predecessor lingers.
    if (Test-Path $workspace) {
        $foldersManifest = if ($manifest) { $manifest } else { Read-CABManifest -Path (Join-Path $Context.RepoRoot 'manifest/folders.yaml') -Quiet }
        $renamed = @($foldersManifest.folders | Where-Object {
            try { [bool]$_.renamed_from } catch { $false }
        })
        foreach ($f in $renamed) {
          foreach ($legacyName in @(Get-CABFolderRenamedFrom -Folder $f)) {
            $legacyPath = Join-Path $workspace $legacyName
            $newPath    = Join-Path $workspace ([string]$f.path)
            $legacyPathExists = Test-Path $legacyPath
            $newPathExists    = Test-Path $newPath
            $legacyExists     = Test-Path $legacyPath -PathType Container
            $newExists        = Test-Path $newPath    -PathType Container

            $id = "folder-rename:$legacyName"

            if ($legacyPathExists -and -not $legacyExists) {
                $checks.Add([ordered]@{
                    id      = $id
                    status  = 'fail'
                    details = "'$legacyName/' exists but is not a directory — manual resolution required."
                })
                continue
            }
            if ($newPathExists -and -not $newExists) {
                $checks.Add([ordered]@{
                    id      = $id
                    status  = 'fail'
                    details = "'$($f.path)/' exists but is not a directory — manual resolution required."
                })
                continue
            }
            if (-not $legacyExists) { continue }

            # Enumerate both paths; if either enumeration fails, emit a fail
            # check entry and skip the rest of the state machine for this
            # rename pair — we can't safely classify what we can't read.
            $legacyHasContent = $false
            try {
                $legacyHasContent = $null -ne (Get-ChildItem -Path $legacyPath -Force -ErrorAction Stop | Select-Object -First 1)
            } catch {
                $checks.Add([ordered]@{
                    id      = $id
                    status  = 'fail'
                    details = "Cannot enumerate '$legacyName/' contents ($($_.Exception.Message)) — manual resolution required."
                })
                continue
            }
            $newHasContent = $false
            if ($newExists) {
                try {
                    $newHasContent = $null -ne (Get-ChildItem -Path $newPath -Force -ErrorAction Stop | Select-Object -First 1)
                } catch {
                    $checks.Add([ordered]@{
                        id      = $id
                        status  = 'fail'
                        details = "Cannot enumerate '$($f.path)/' contents ($($_.Exception.Message)) — manual resolution required."
                    })
                    continue
                }
            }

            if (-not $newExists) {
                $checks.Add([ordered]@{
                    id      = $id
                    status  = 'warn'
                    details = "Legacy folder '$legacyName/' present, expected '$($f.path)/'."
                    fix     = 'repair --target folder-renames'
                })
            } elseif (-not $legacyHasContent -or -not $newHasContent) {
                $checks.Add([ordered]@{
                    id      = $id
                    status  = 'warn'
                    details = "Legacy folder '$legacyName/' present alongside '$($f.path)/' — repair will merge."
                    fix     = 'repair --target folder-renames'
                })
            } else {
                $checks.Add([ordered]@{
                    id      = $id
                    status  = 'fail'
                    details = "Both '$legacyName/' and '$($f.path)/' contain files — manual merge required."
                })
            }
          }
        }
    }

    # ----- Prerequisites -----
    $prereqReport = Get-CABToolReport -ManifestPath (Join-Path $Context.RepoRoot 'manifest/tools.yaml')
    foreach ($r in $prereqReport) {
        $entry = [ordered]@{
            id        = "tool.$($r.id)"
            status    = $r.status
            details   = $r.details
            tool_id   = $r.id
            required  = $r.is_required
        }
        if ($r.status -in 'fail','warn') {
            $entry.fix = "repair --target $($r.id)"
        }
        $checks.Add($entry)
    }

    # ----- gh auth -----
    if (Get-Command 'gh' -ErrorAction SilentlyContinue) {
        & gh auth status 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $user = (& gh api user --jq .login 2>$null) -join ''
            $checks.Add([ordered]@{ id = 'gh-auth'; status = 'ok'; details = "logged in as $user" })
        } else {
            $checks.Add([ordered]@{ id = 'gh-auth'; status = 'fail'; details = 'not authenticated'; fix = 'repair --target gh-auth' })
        }
    } else {
        $checks.Add([ordered]@{ id = 'gh-auth'; status = 'fail'; details = 'gh CLI not installed'; fix = 'repair --target gh' })
    }

    # ----- Repositories (compare journal expectations vs disk) -----
    if (Test-Path $workspace) {
        $manifest = Read-CABManifest -Path (Join-Path $Context.RepoRoot 'manifest/repos.yaml') -Quiet
        $expectedRepos = @($manifest.groups | ForEach-Object { $_.repos } | Where-Object {
            try { -not $_.opt_in } catch { $true }
        })
        $expectedRepoSlugs = @($expectedRepos | ForEach-Object { $_.repo })
        $missingRepos = New-Object System.Collections.Generic.List[string]
        $okRepos = 0
        foreach ($r in $expectedRepos) {
            $into = Join-Path $workspace $r.into
            $state = Test-CABRepoCloned -Path $into -ExpectedRepo $r.repo
            if ($state -eq 'matches') { $okRepos++ }
            else { $missingRepos.Add("$($r.repo) ($state)") }
        }
        # Drift detection: surface repos the journal recorded as cloned
        # but that are no longer in the current manifest (ghost clones —
        # e.g. cm-claim-checker after it was removed). Repos still in
        # the manifest are validated by the loop above; including them
        # here double-reports stale journal paths from previous workspace
        # defaults — which is exactly what made `repair --all` flag 15
        # false-positive "deleted from disk" entries pointing at the
        # pre-1.4 Documents/Projects/Work/ChannelAssist/... root.
        foreach ($je in (Get-CABJournalEntry -Action 'clone_repo')) {
            if ($expectedRepoSlugs -contains [string]$je.repo) { continue }
            $jePath = [string]$je.path
            if ($jePath -and -not (Test-Path $jePath)) {
                $missingRepos.Add("$($je.repo) (deleted from disk)")
            }
        }
        if ($missingRepos.Count -eq 0) {
            $checks.Add([ordered]@{ id = 'repos'; status = 'ok'; details = "$okRepos/$($expectedRepos.Count) cloned" })
        } else {
            $checks.Add([ordered]@{
                id = 'repos'; status = 'warn'
                details = "$($missingRepos.Count) issue(s): $($missingRepos -join '; ')"
                fix = 'repair --target repos'
            })
        }
    }

    # ----- Git identity -----
    if (Test-Path $workspace) {
        $globalGitconfig = if ($IsWindows) { Join-Path $env:USERPROFILE '.gitconfig' } else { Join-Path $HOME '.gitconfig' }
        if (Test-Path $globalGitconfig) {
            $content = Get-Content -Raw $globalGitconfig
            $needle = "gitdir:$($workspace.Replace('\','/').TrimEnd('/'))/"
            if ($content -like "*$needle*") {
                $wsConfig = Join-Path $workspace '.gitconfig'
                if (Test-Path $wsConfig) {
                    $checks.Add([ordered]@{ id = 'git-identity'; status = 'ok'; details = "scoped to $workspace" })
                } else {
                    $checks.Add([ordered]@{
                        id = 'git-identity'; status = 'warn'
                        details = "includeIf points at $wsConfig but file is missing"
                        fix = 'repair --target identity'
                    })
                }
            } else {
                $checks.Add([ordered]@{
                    id = 'git-identity'; status = 'warn'
                    details = 'no includeIf for this workspace'
                    fix = 'repair --target identity'
                })
            }
        } else {
            $checks.Add([ordered]@{ id = 'git-identity'; status = 'warn'; details = 'no global .gitconfig'; fix = 'repair --target identity' })
        }
    }

    # ----- Action journal -----
    if (Test-Path (Get-CABJournalPath)) {
        try {
            Read-CABJournal | Out-Null
            $sessionCount = @($Script:CABJournalState.sessions).Count
            $actionCount = ($Script:CABJournalState.sessions | ForEach-Object { @($_.actions).Count } | Measure-Object -Sum).Sum
            $checks.Add([ordered]@{ id = 'journal'; status = 'ok'; details = "$sessionCount session(s), $actionCount recorded action(s)" })
        } catch {
            $checks.Add([ordered]@{ id = 'journal'; status = 'fail'; details = "parse failed: $($_.Exception.Message)"; fix = 'repair --target journal' })
        }
    } else {
        $checks.Add([ordered]@{ id = 'journal'; status = 'warn'; details = 'no journal yet'; fix = 'setup' })
    }

    return $checks.ToArray()
}

function Format-CABDoctorReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][array]$Checks, [switch]$Summary)
    foreach ($c in $Checks) {
        $icon, $color = switch ($c.status) {
            'ok'    { '✓', 'Green'    }
            'warn'  { '⚠', 'Yellow'   }
            'fail'  { '✗', 'Red'      }
            'na'    { '–', 'DarkGray' }
            'error' { '!', 'Magenta'  }
            default { '?', 'White'    }
        }
        $label = "$($c.id)".PadRight(28)
        if ($Summary) {
            Write-CABColor ([ConsoleColor]$color) "$icon $($c.id) — $($c.details)"
        } else {
            Write-CABColor ([ConsoleColor]$color) "  $icon  $label  $($c.details)"
        }
    }
}

function Invoke-CABCommandDoctor {
    [CmdletBinding()]
    param([hashtable]$Context = @{})

    if (-not $Context.Json -and -not $Context.Quiet) {
        Write-CABHeader 'ca-bootstrap doctor'
        Write-Host ''
    }

    $checks = Invoke-CABDoctorCheck -Context $Context

    if ($Context.Json) {
        # Emit JSON on the success stream so `$output = & ./ca-bootstrap.ps1
        # doctor -Json` captures it. The orchestrator reads the exit code
        # from a script-scope variable so the function's return doesn't
        # add a trailing integer to the captured output.
        $payload = [ordered]@{
            schema_version = 1
            generated_at   = (Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ')
            host           = [ordered]@{
                os = if ($IsWindows){'windows'} elseif ($IsMacOS){'macos'} else {'linux'}
            }
            checks         = $checks
            exit_code      = if ($checks | Where-Object { $_.status -in 'warn','fail' }) { 2 } else { 0 }
        }
        $payload | ConvertTo-Json -Depth 6 | Write-Output
        $Script:CABDoctorExitCode = [int]$payload.exit_code
        return
    }

    Format-CABDoctorReport -Checks $checks -Summary:$Context.Summary
    Write-Host ''

    $issues = @($checks | Where-Object { $_.status -in 'warn','fail' })
    if ($issues.Count -eq 0) {
        Write-CABStatus -Status ok -Message 'All checks ✓'
        Write-Host ''
        return 0
    }

    # Distinguish "fresh machine, never set up" from "drift from a known
    # good state". Both exit 2, but the message differs to set the right
    # expectation for the user.
    $journalCheck = $checks | Where-Object { $_.id -eq 'journal' } | Select-Object -First 1
    $workspaceCheck = $checks | Where-Object { $_.id -eq 'workspace' } | Select-Object -First 1
    $isFreshMachine = $journalCheck -and $journalCheck.status -in 'warn','fail' -and `
                      ($workspaceCheck -and $workspaceCheck.status -eq 'fail')

    if ($isFreshMachine) {
        Write-CABColor Cyan "  Looks like setup hasn't been run on this machine yet."
        Write-Host  '  Run `ca-bootstrap.ps1 setup` to get started.'
    } else {
        Write-CABColor White "  $($issues.Count) issue(s) found:"
        foreach ($i in $issues) {
            if ($i.fix) {
                Write-Host "    • $($i.id) — fix: ca-bootstrap.ps1 $($i.fix)"
            }
        }
        Write-Host ''
        Write-Host '  Run `ca-bootstrap.ps1 repair --all` to fix them all.'
    }
    Write-Host ''
    return 2
}
