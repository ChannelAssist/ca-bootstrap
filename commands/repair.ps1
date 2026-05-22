#requires -Version 7.0
# commands/repair.ps1 — fix what doctor found.
#
# Phase 9 implementation. Reuses each step's Invoke function: instead of
# orchestrating the full setup wizard, repair runs only the steps that
# correspond to detected issues.
#
# Targets:
#   --all                       fix every ⚠ and ✗ from doctor
#   --target <tool-id>          install/upgrade a specific tool
#   --target repos              re-clone or fetch missing/broken repos
#   --target repos:<slug>       one specific repo (e.g. repos:cm-shared-libs)
#   --target identity           re-write per-folder git identity
#   --target gh-auth            re-run gh auth login
#   --target folders            recreate any missing top-level folders
#   --target folder-renames     migrate legacy workspace folders to renamed paths (safety-contract compliant)
#   --target folder-readmes     re-sync templates/folder-readmes/ into the workspace (prompts before overwriting drift)
#   --target journal            rebuild the journal from on-disk state

function Invoke-CABCommandRepair {
    [CmdletBinding()]
    param(
        [hashtable]$Context = @{},
        [switch]$All,
        [string]$Target
    )
    # Repair piggybacks on doctor's check functions.
    . (Join-Path $Context.RepoRoot 'commands/doctor.ps1')

    Write-CABHeader 'ca-bootstrap repair'

    if (-not $All -and -not $Target) {
        Write-CABStatus -Status fail -Message 'You must specify either -All or -Target <id>.'
        Write-Host '    examples:'
        Write-Host '      ca-bootstrap.ps1 repair -All'
        Write-Host '      ca-bootstrap.ps1 repair -Target dotnet-10'
        Write-Host '      ca-bootstrap.ps1 repair -Target repos'
        Write-Host '      ca-bootstrap.ps1 repair -Target repos:cm-shared-libs'
        return 9
    }

    # Always run doctor first so we know what's wrong.
    Write-Host '  Running doctor first...'
    Write-Host ''
    # Invoke-CABDoctorCheck populates $Context.WorkspacePath as a
    # side effect; downstream targets read it from there directly.
    $checks = Invoke-CABDoctorCheck -Context $Context

    $issues = @($checks | Where-Object { $_.status -in 'warn','fail' })
    if ($issues.Count -eq 0 -and -not $Target) {
        Write-CABStatus -Status ok -Message 'Nothing to repair — all checks ✓.'
        return 0
    }

    # Build target list.
    $targets = if ($All) {
        @($issues.id)
    } else {
        @($Target)
    }

    $applied = 0
    $failed = New-Object System.Collections.Generic.List[string]

    foreach ($t in $targets) {
        Write-Host ''
        Write-CABColor White "  → repair $t"
        $result = Invoke-CABRepairTarget -Target $t -Context $Context
        if ($result.ok) {
            Write-CABStatus -Status ok -Message $result.details
            $applied++
        } else {
            Write-CABStatus -Status fail -Message $result.details
            $failed.Add($t)
        }
    }

    Save-CABJournal

    Write-Host ''
    Write-Host "  Re-running doctor to confirm..."
    Write-Host ''
    $afterChecks = Invoke-CABDoctorCheck -Context $Context
    Format-CABDoctorReport -Checks $afterChecks -Summary
    Write-Host ''

    if ($failed.Count -gt 0) {
        Write-CABStatus -Status fail -Message "$($failed.Count) target(s) could not be repaired: $($failed -join ', ')"
        return 9
    }

    # When called with -All, exit non-zero if doctor still reports anything.
    # When called with -Target, only the targeted issue's residual state
    # matters — unrelated warnings stay warnings on the next doctor run.
    $stillBroken = @($afterChecks | Where-Object { $_.status -in 'warn','fail' })
    if ($All -and $stillBroken.Count -gt 0) {
        Write-CABStatus -Status warn -Message "Repair partial — $($stillBroken.Count) issue(s) remain."
        return 9
    }
    Write-CABStatus -Status ok -Message "Repair complete. $applied target(s) fixed."
    return 0
}

# Invoke-CABRepairTarget — dispatch one target string to the corresponding
# step's Invoke function in repair mode.
function Invoke-CABRepairTarget {
    # DoctorChecks was passed to give the dispatcher per-target visibility
    # into the failed checks, but every branch below resolves the work
    # itself by re-invoking the relevant step's Invoke function — none
    # peek at the doctor result. Dropped the parameter; if a future
    # target needs the diagnostics, add it back then.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][hashtable]$Context
    )

    # Strip the "tool." prefix doctor uses (so users can type the manifest
    # id directly: --target dotnet-10).
    $bare = $Target -replace '^tool\.', ''

    # Repos sub-target: --target repos:slug
    if ($bare -like 'repos:*') {
        $slug = $bare -replace '^repos:', ''
        return Invoke-CABRepairRepoSlug -Slug $slug -Context $Context
    }

    switch ($bare) {
        'workspace' {
            . (Join-Path $Context.RepoRoot 'steps/40-workspace.ps1')
            $r = Invoke-CABStep40 -Context $Context
            return @{ ok = ($r.status -in 'ok','skip'); details = $r.details }
        }
        'folders' {
            . (Join-Path $Context.RepoRoot 'steps/40-workspace.ps1')
            . (Join-Path $Context.RepoRoot 'steps/50-folders.ps1')
            $r = Invoke-CABStep50 -Context $Context
            return @{ ok = ($r.status -in 'ok','skip'); details = $r.details }
        }
        'folder-renames' {
            $r = Invoke-CABRepairFolderRenames -Context $Context
            return @{ ok = ($r.status -in 'ok','noop'); details = $r.details }
        }
        'folder-readmes' {
            $r = Invoke-CABRepairFolderReadmes -Context $Context
            return @{ ok = ($r.status -in 'ok','noop'); details = $r.details }
        }
        'gh-auth' {
            . (Join-Path $Context.RepoRoot 'steps/30-gh-auth.ps1')
            $r = Invoke-CABStep30 -Context $Context
            return @{ ok = ($r.status -in 'ok','skip'); details = $r.details }
        }
        'identity' {
            . (Join-Path $Context.RepoRoot 'steps/70-git-identity.ps1')
            $r = Invoke-CABStep70 -Context $Context
            return @{ ok = ($r.status -in 'ok','skip'); details = $r.details }
        }
        'repos' {
            . (Join-Path $Context.RepoRoot 'steps/60-repos.ps1')
            $r = Invoke-CABStep60 -Context $Context
            return @{ ok = ($r.status -in 'ok','skip'); details = $r.details }
        }
        'journal' {
            if (-not $Context.WorkspacePath) {
                return @{ ok = $false; details = 'Workspace path not known; cannot reconstruct journal.' }
            }
            $session = Repair-CABJournal -WorkspacePath $Context.WorkspacePath -Version $Context.Version
            return @{ ok = $true; details = "Reconstructed $(@($session.actions).Count) action(s)" }
        }
        default {
            # Tool ID — install via step 20's machinery.
            $manifest = Read-CABManifest -Path (Join-Path $Context.RepoRoot 'manifest/tools.yaml')
            $tool = (@($manifest.required) + @($manifest.optional)) | Where-Object { $_.id -eq $bare } | Select-Object -First 1
            if (-not $tool) {
                return @{ ok = $false; details = "Unknown target: $bare" }
            }
            $result = Install-CABTool -Tool $tool -Context $Context
            if ($result.ok) {
                Add-CABJournalEntry -Step '20-prereqs' -Action 'install_tool' -Data @{
                    tool   = $tool.id
                    method = (Get-CABInstallEntry -Tool $tool).type
                } | Out-Null
            }
            return $result
        }
    }
}

function Invoke-CABRepairRepoSlug {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][hashtable]$Context
    )
    if (-not $Context.WorkspacePath) {
        return @{ ok = $false; details = 'Workspace path not known.' }
    }
    $manifest = Read-CABManifest -Path (Join-Path $Context.RepoRoot 'manifest/repos.yaml')
    $allRepos = $manifest.groups | ForEach-Object { $_.repos }
    $repo = $allRepos | Where-Object { $_.repo -ieq $Slug -or $_.repo -ieq "ChannelAssist/$Slug" } | Select-Object -First 1
    if (-not $repo) {
        return @{ ok = $false; details = "Unknown repo: $Slug" }
    }
    $into = Join-Path $Context.WorkspacePath $repo.into
    $state = Test-CABRepoCloned -Path $into -ExpectedRepo $repo.repo
    if ($state -eq 'matches') {
        return @{ ok = $true; details = "Already cloned: $($repo.repo)" }
    }
    $result = Invoke-CABRepoClone -Repo $repo.repo -Into $into -Branch $repo.branch
    if ($result.ok) {
        Add-CABJournalEntry -Step '60-repos' -Action 'clone_repo' -Data @{
            repo = $repo.repo; path = $into; branch = $repo.branch
        } | Out-Null
    }
    return $result
}

# Invoke-CABRepairFolderRenames — safety-contract-compliant folder rename.
# Dispatched by `repair --target folder-renames`. Reads `renamed_from:`
# from manifest/folders.yaml and migrates legacy folders to their new
# names per the decision table in docs/specs/2026-05-22-folder-taxonomy-design.md.
#
# Returns @{ status = ok|noop|manual|skip; details = '...' }.
function Invoke-CABRepairFolderRenames {
    [CmdletBinding()]
    param([hashtable]$Context)

    $ws = $Context.WorkspacePath
    if (-not $ws -or -not (Test-Path $ws)) {
        return @{ status = 'fail'; details = "Workspace not set or missing: $ws" }
    }

    # Configure prompt mode from context so Read-CABConfirm works correctly
    # in both interactive and test-harness scenarios.
    #   Yes = $true  → unattended with no pre-loaded answers (defaults apply).
    #   Yes = $false + Answers → unattended with explicit scripted answers.
    $answers = if ($Context.ContainsKey('Answers') -and $Context.Answers) { $Context.Answers } else { @{} }
    Set-CABPromptMode -Unattended $true -Answers $answers

    $manifest = Read-CABManifest -Path (Join-Path $Context.RepoRoot 'manifest/folders.yaml') -Quiet
    $renamed = @($manifest.folders | Where-Object { $_.renamed_from })
    if ($renamed.Count -eq 0) {
        return @{ status = 'noop'; details = 'No folders declare renamed_from:' }
    }

    $touched = 0
    $skipped = 0
    $manuals = New-Object System.Collections.Generic.List[string]

    foreach ($f in $renamed) {
        $legacyPath = Join-Path $ws ([string]$f.renamed_from)
        $newPath    = Join-Path $ws ([string]$f.path)
        $legacyExists = Test-Path $legacyPath -PathType Container
        $newExists    = Test-Path $newPath    -PathType Container

        if (-not $legacyExists) { continue }

        $legacyChildren = @(Get-ChildItem -Path $legacyPath -Force -ErrorAction SilentlyContinue)
        $newChildren    = if ($newExists) { @(Get-ChildItem -Path $newPath -Force -ErrorAction SilentlyContinue) } else { @() }

        $legacyEmpty = $legacyChildren.Count -eq 0
        $newEmpty    = (-not $newExists) -or ($newChildren.Count -eq 0)

        # State: only legacy, empty → rename silently.
        if (-not $newExists -and $legacyEmpty) {
            Move-Item -Path $legacyPath -Destination $newPath -Force
            Add-CABJournalEntry -Step 'repair' -Action 'rename_folder' -Data @{
                from = $legacyPath; to = $newPath; mode = 'silent-empty'
            } | Out-Null
            $touched++
            continue
        }

        # State: only legacy, non-empty → prompt before rename.
        if (-not $newExists -and -not $legacyEmpty) {
            $summary = "$($legacyChildren.Count) entries; first: $(($legacyChildren | Select-Object -First 3 -ExpandProperty Name) -join ', ')"
            $proceed = Read-CABConfirm -Question "Move '$($f.renamed_from)/' → '$($f.path)/' (preserves all contents: $summary)?" `
                                       -Default $true `
                                       -AnswerKey "folder-rename.$($f.renamed_from)"
            # Quit aborts the whole folder-renames repair — matches undo.ps1's
            # per-action quit behavior (line ~333): return immediately rather
            # than continuing to the next folder in the loop.
            if (Test-CABQuit $proceed) {
                return @{ status = 'skip'; details = 'User quit during folder-rename repair.' }
            }
            if (Test-CABNo $proceed) {
                $skipped++
                continue
            }
            Move-Item -Path $legacyPath -Destination $newPath -Force
            Add-CABJournalEntry -Step 'repair' -Action 'rename_folder' -Data @{
                from = $legacyPath; to = $newPath; mode = 'prompted-nonempty'
            } | Out-Null
            $touched++
            continue
        }

        # State: both exist, both empty → remove empty legacy.
        if ($newExists -and $legacyEmpty -and $newEmpty) {
            Remove-Item -Path $legacyPath -Force
            Add-CABJournalEntry -Step 'repair' -Action 'remove_empty_folder' -Data @{ path = $legacyPath } | Out-Null
            $touched++
            continue
        }

        # State: both exist, legacy empty + new has content → silent remove of empty legacy.
        if ($newExists -and $legacyEmpty -and -not $newEmpty) {
            Remove-Item -Path $legacyPath -Force
            Add-CABJournalEntry -Step 'repair' -Action 'remove_empty_folder' -Data @{ path = $legacyPath; reason = 'new-populated' } | Out-Null
            $touched++
            continue
        }

        # State: both exist, new empty + legacy has content → prompt to move children + remove empty legacy.
        if ($newExists -and $newEmpty -and -not $legacyEmpty) {
            $summary = "$($legacyChildren.Count) entries"
            $proceed = Read-CABConfirm -Question "Move children of '$($f.renamed_from)/' into '$($f.path)/' (then remove empty '$($f.renamed_from)/'): $summary?" `
                                       -Default $true `
                                       -AnswerKey "folder-rename.$($f.renamed_from).remove-empty-legacy"
            # Quit aborts the whole folder-renames repair — matches undo.ps1's
            # per-action quit behavior (line ~333): return immediately rather
            # than continuing to the next folder in the loop.
            if (Test-CABQuit $proceed) {
                return @{ status = 'skip'; details = 'User quit during folder-rename repair.' }
            }
            if (Test-CABNo $proceed) {
                $skipped++
                continue
            }
            foreach ($child in $legacyChildren) {
                Move-Item -Path $child.FullName -Destination $newPath -Force
            }
            Remove-Item -Path $legacyPath -Force
            Add-CABJournalEntry -Step 'repair' -Action 'rename_folder' -Data @{
                from = $legacyPath; to = $newPath; mode = 'merge-into-empty-new'
            } | Out-Null
            $touched++
            continue
        }

        # State: both exist, both have content → manual merge.
        $manuals.Add("$($f.renamed_from)/ and $($f.path)/ both contain files — inspect, decide which side to keep, then rerun.")
    }

    if ($manuals.Count -gt 0) {
        return @{ status = 'manual'; details = ($manuals -join '; ') }
    }
    if ($touched -eq 0) {
        return @{ status = 'noop'; details = "Nothing to rename (skipped: $skipped)" }
    }
    return @{ status = 'ok'; details = "Renamed/cleaned $touched folder(s); skipped $skipped" }
}

# Invoke-CABRepairFolderReadmes — re-sync README templates into workspace.
# Dispatched by `repair --target folder-readmes`. Seeds missing READMEs;
# prompts before overwriting drifted ones. `-Yes` is intentionally NOT
# honored for the overwrite path — operator must consciously confirm.
function Invoke-CABRepairFolderReadmes {
    [CmdletBinding()]
    param([hashtable]$Context)

    $ws = $Context.WorkspacePath
    if (-not $ws -or -not (Test-Path $ws)) {
        return @{ status = 'fail'; details = "Workspace not set or missing: $ws" }
    }

    $manifest = Read-CABManifest -Path (Join-Path $Context.RepoRoot 'manifest/folders.yaml') -Quiet
    $seeded = 0; $overwritten = 0; $skippedDrift = 0; $matched = 0

    foreach ($f in $manifest.folders) {
        $folder = Join-Path $ws ([string]$f.path)
        if (-not (Test-Path $folder -PathType Container)) { continue }

        $template = Join-Path $Context.RepoRoot 'templates/folder-readmes' ([string]$f.path) 'README.md'
        $target   = Join-Path $folder 'README.md'
        if (-not (Test-Path $template)) { continue }

        if (-not (Test-Path $target)) {
            Copy-Item -Path $template -Destination $target -Force
            Add-CABJournalEntry -Step 'repair' -Action 'seed_readme' -Data @{ path = $target; template = $template } | Out-Null
            $seeded++
            continue
        }

        $templateHash = (Get-FileHash -Path $template -Algorithm SHA256).Hash
        $targetHash   = (Get-FileHash -Path $target   -Algorithm SHA256).Hash
        if ($templateHash -eq $targetHash) {
            $matched++
            continue
        }

        $answers = if ($Context.ContainsKey('Answers') -and $Context.Answers) { $Context.Answers } else { @{} }
        Set-CABPromptMode -Unattended $true -Answers $answers

        $proceed = Read-CABConfirm -Question "Workspace README at '$($f.path)/README.md' differs from the template. Overwrite?" `
                                   -Default $false `
                                   -AnswerKey "folder-readme.$($f.path).overwrite"
        if (Test-CABQuit $proceed) {
            return @{ status = 'skip'; details = 'User quit during folder-readmes repair.' }
        }
        if (Test-CABNo $proceed) {
            $skippedDrift++
            continue
        }
        Copy-Item -Path $template -Destination $target -Force
        Add-CABJournalEntry -Step 'repair' -Action 'refresh_readme' -Data @{ path = $target; template = $template } | Out-Null
        $overwritten++
    }

    if ($seeded + $overwritten -eq 0) {
        return @{ status = 'ok'; details = "no-op (matched: $matched, drift skipped: $skippedDrift)" }
    }
    return @{ status = 'ok'; details = "seeded $seeded, overwrote $overwritten, matched $matched, drift skipped $skippedDrift" }
}
