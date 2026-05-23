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

# Invoke-CABDoctorCheck — produce the full check list. Returns an array of
# [ordered]@{ id; status; details; ...extra }.
function Invoke-CABDoctorCheck {
    [CmdletBinding()]
    param([hashtable]$Context)

    $checks = New-Object System.Collections.Generic.List[hashtable]

    # ----- Workspace -----
    $workspace = $null
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
            Where-Object { $_.is_workspace_root })
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
    $Context.WorkspacePath = $workspace

    if (Test-Path $workspace) {
        $checks.Add([ordered]@{ id = 'workspace'; status = 'ok'; details = "exists at $workspace"; path = $workspace })
    } else {
        $checks.Add([ordered]@{ id = 'workspace'; status = 'fail'; details = "missing: $workspace"; path = $workspace; fix = 'setup' })
    }

    # ----- Folders -----
    if (Test-Path $workspace) {
        $manifest = Read-CABManifest -Path (Join-Path $Context.RepoRoot 'manifest/folders.yaml')
        $expected = @($manifest.folders | Where-Object { -not $_.optional })
        $present  = @($expected | Where-Object { Test-Path (Join-Path $workspace $_.path) })
        $missing  = @($expected | Where-Object { -not (Test-Path (Join-Path $workspace $_.path)) })

        # Of the missing folders, see which ones have a predecessor on
        # disk via renamed_from (scalar or list, walked most-recent →
        # oldest). Those are flagged as "needs rename" so doctor can
        # tell an operator who skipped a migration apart from one with
        # genuine missing folders. Repair walks the same chain.
        $renames   = New-Object System.Collections.Generic.List[hashtable]
        $stillMissing = New-Object System.Collections.Generic.List[string]
        foreach ($f in $missing) {
            $predecessors = @(Get-CABFolderRenamedFrom -Folder $f)
            $found = $null
            foreach ($prev in $predecessors) {
                if (Test-Path (Join-Path $workspace $prev)) { $found = $prev; break }
            }
            if ($found) {
                $renames.Add(@{ path = [string]$f.path; from = $found })
            } else {
                $stillMissing.Add([string]$f.path)
            }
        }

        if ($stillMissing.Count -eq 0 -and $renames.Count -eq 0) {
            $checks.Add([ordered]@{ id = 'folders'; status = 'ok'; details = "$($present.Count)/$($expected.Count) present" })
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
        $manifest = Read-CABManifest -Path (Join-Path $Context.RepoRoot 'manifest/repos.yaml')
        $expectedRepos = @($manifest.groups | ForEach-Object { $_.repos } | Where-Object { -not $_.opt_in })
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
