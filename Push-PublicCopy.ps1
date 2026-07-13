<#
.SYNOPSIS
    Push a history-free snapshot of this repo's current committed state to a
    separate public GitHub copy.

.DESCRIPTION
    Drop this script (and optionally a sibling .public-exclude file) into the
    root of any repo you want a public copy of, then run it from there.

    Creates the public repo (same owner, name + "-public" suffix) via gh if it
    doesn't exist yet, then pushes ONLY the current HEAD's tracked file
    contents as a single fresh commit - no history at all. Nothing ever
    committed and later removed (credentials, internal notes, etc.) can reach
    the public copy this way, since git history never crosses over. Safe to
    re-run: each run force-replaces the public repo's main branch with a new
    snapshot commit.

    Uncommitted/untracked changes in the private repo are NOT included - only
    what's actually committed at HEAD. This script, .public-exclude, the
    generated <PublicName>.url shortcut, and .gitignore/.gitattributes
    (git-internal housekeeping a typical downloader has no reason to see) are
    always excluded from the snapshot itself.

    Also drops a <PublicName>.url shortcut next to this script (in the
    private repo) pointing at the direct zip download (triggers immediately,
    no repo-page click-through needed), so it's there next time without
    re-running or scrolling back through output.

    Every snapshot gets an Unblock-All.bat injected automatically (not part
    of the private repo - generated fresh each run): downloaded zips carry
    Mark-of-the-Web into every extracted file, which hard-blocks unsigned
    .ps1 scripts under PowerShell's common RemoteSigned policy. The .bat
    unblocks everything and allows local scripts to run, for the current
    user only, no admin rights needed.

.PARAMETER PublicName
    Name for the public repo. Defaults to "<this repo's name>-public".

.PARAMETER Owner
    GitHub owner for the public repo. Defaults to the private repo's own owner.

.PARAMETER NoPause
    Skip the "press enter" pause at the end (agents/automation).

.EXAMPLE
    .\Push-PublicCopy.ps1
    .\Push-PublicCopy.ps1 -PublicName MyToolOpenSource
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$PublicName,
    [string]$Owner,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

function Write-Step  ($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok    ($m) { Write-Host "    $m" -ForegroundColor Green }
function Write-Warn2 ($m) { Write-Host "    $m" -ForegroundColor Yellow }

try {

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "git not found on PATH." }
if (-not (Get-Command gh  -ErrorAction SilentlyContinue)) { throw "GitHub CLI (gh) not found on PATH." }
gh auth status *> $null
if ($LASTEXITCODE -ne 0) { throw "gh is not authenticated. Run: gh auth login" }

# ---- locate the repo this script sits in (portable to any subfolder) -------
$repoRoot = (git -C $PSScriptRoot rev-parse --show-toplevel 2>$null)
if (-not $repoRoot) { throw "Not inside a git repository: $PSScriptRoot" }
$repoRoot = $repoRoot -replace '/', '\'

$originUrl = (git -C $repoRoot remote get-url origin 2>$null)
if (-not $originUrl) { throw "No 'origin' remote on this repo - can't determine owner/name." }
if ($originUrl -notmatch '[:/]([^/:]+)/([^/]+?)(\.git)?$') { throw "Could not parse owner/name from: $originUrl" }
$privateOwner = $Matches[1]
$privateName  = $Matches[2]

if (-not $Owner)      { $Owner = $privateOwner }
if (-not $PublicName) { $PublicName = "$privateName-public" }
$publicRepoSlug = "$Owner/$PublicName"

Write-Step "Private repo: $privateOwner/$privateName  ->  Public copy: $publicRepoSlug"

# ---- ensure the public repo exists (create if missing) ---------------------
gh repo view $publicRepoSlug *> $null
$publicExists = ($LASTEXITCODE -eq 0)
if (-not $publicExists) {
    if ($PSCmdlet.ShouldProcess($publicRepoSlug, 'create public GitHub repo')) {
        Write-Step "Public repo doesn't exist yet - creating..."
        gh repo create $publicRepoSlug --public --description "Public snapshot of $privateName (history-free, pushed manually)" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "gh repo create failed for $publicRepoSlug." }
        Write-Ok "Created $publicRepoSlug"
    }
} else {
    Write-Ok "Public repo already exists - will refresh its snapshot."
}
$publicUrl = "https://github.com/$publicRepoSlug"
# Direct zip download - triggers immediately, no repo-page click-through, no
# account needed. "main" is safe to hardcode: this script always pushes there.
$zipUrl = "https://github.com/$publicRepoSlug/archive/refs/heads/main.zip"

# ---- export HEAD's tracked content only (no history, no working-tree cruft) ---
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$tempDir = Join-Path $env:TEMP "push-public-$stamp"
$tempZip = Join-Path $env:TEMP "push-public-$stamp.zip"
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

Write-Step "Exporting HEAD (tracked, committed content only)..."
git -C $repoRoot archive --format=zip --output=$tempZip HEAD
if ($LASTEXITCODE -ne 0) { throw "git archive failed." }
Expand-Archive -LiteralPath $tempZip -DestinationPath $tempDir -Force
Remove-Item -LiteralPath $tempZip -Force

# Always strip this tool, its exclude-list, and the local .url shortcut -
# they're local tooling, not repo content. (.gitignore/.gitattributes are
# handled separately, below, at commit time rather than here.)
$urlShortcutName = "$PublicName.url"
$alwaysStripped = @('Push-PublicCopy.ps1', '.public-exclude', $urlShortcutName)
foreach ($self in $alwaysStripped) {
    $p = Join-Path $tempDir $self
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
}
Write-Ok "Always stripped: $($alwaysStripped -join ', '), .gitignore, .gitattributes"

# ---- apply the optional exclude list (gitignore-style glob patterns) -------
$excludeFile = Join-Path $PSScriptRoot '.public-exclude'
if (Test-Path -LiteralPath $excludeFile) {
    Write-Step "Applying .public-exclude..."
    $patterns = Get-Content -LiteralPath $excludeFile | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' }
    foreach ($pat in $patterns) {
        $pat = $pat.Trim()
        Get-ChildItem -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object {
                $rel = $_.FullName.Substring($tempDir.Length + 1) -replace '\\', '/'
                $rel -like $pat -or $_.Name -like $pat
            } |
            ForEach-Object {
                Write-Warn2 "Excluded: $($_.FullName.Substring($tempDir.Length + 1))"
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
    }
} else {
    Write-Ok "No .public-exclude found next to this script - no additional paths stripped beyond the defaults above."
}

# ---- inject a generic unblock helper into every snapshot -------------------
# Windows marks a downloaded zip's extracted files with Mark-of-the-Web, which
# makes PowerShell hard-block unsigned .ps1 scripts under RemoteSigned (the
# common default) - not just a SmartScreen warning. A .bat (not .ps1) sidesteps
# that same block on itself: batch files only hit a one-time SmartScreen
# "Run anyway" click, never PowerShell's execution-policy wall.
$unblockBatContent = @"
@echo off
setlocal

echo ============================================================
echo   Unblock scripts + allow PowerShell scripts (current user)
echo ============================================================
echo.
echo This folder was downloaded from the internet, so Windows marks every
echo file in it as "blocked" and PowerShell refuses to run unsigned .ps1
echo scripts by default. This fixes both, for YOUR Windows user account
echo only - no admin rights needed, nothing else on the machine is changed.
echo.

echo Unblocking all files in this folder...
powershell -NoProfile -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse | Unblock-File"

echo Allowing local PowerShell scripts to run (current user only)...
powershell -NoProfile -Command "Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force"

echo.
echo Done. You can now double-click the .ps1 scripts in this folder.
echo.
pause
"@ -replace "`n", "`r`n"
Set-Content -LiteralPath (Join-Path $tempDir 'Unblock-All.bat') -Value $unblockBatContent -Encoding ascii -NoNewline
# Force this one file to bypass line-ending conversion entirely, regardless
# of the source repo's own .gitattributes (carried into the snapshot via git
# archive) - cmd.exe's :label scanner can misparse LF-only batch files, and a
# repo without an explicit *.bat CRLF override (most of them) would otherwise
# have git silently renormalize the CRLF this script just wrote back to LF on
# commit. Appended, not overwritten, so any exported .gitattributes rules
# still apply to everything else.
Add-Content -LiteralPath (Join-Path $tempDir '.gitattributes') -Value "`nUnblock-All.bat -text`n"

# ---- commit the snapshot and force-push it as the public repo's history ----
if ($PSCmdlet.ShouldProcess($publicRepoSlug, 'force-push a fresh snapshot commit')) {
    Write-Step "Building the snapshot commit..."
    Push-Location $tempDir
    try {
        git init -q -b main
        # .gitignore/.gitattributes are git-internal housekeeping a typical
        # downloader has no reason to see or understand - excluded from the
        # PUBLIC commit, but left on disk for this 'add' so .gitattributes'
        # -text rule (above) still protects Unblock-All.bat's CRLF while
        # staging. Pathspec exclusion, not deletion: git reads attributes
        # from the working tree regardless of staged status.
        git add -A -- . ':!.gitattributes' ':!.gitignore'
        git -c user.name="$(git -C $repoRoot config user.name)" -c user.email="$(git -C $repoRoot config user.email)" `
            commit -q -m "Public snapshot of $privateName - $stamp (history-free)"
        git remote add origin "https://github.com/$publicRepoSlug.git"
        git push --force origin main
        if ($LASTEXITCODE -ne 0) { throw "Push to $publicRepoSlug failed." }
    } finally {
        Pop-Location
    }
    Write-Ok "Pushed snapshot to $publicUrl"
}

Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue

# Drop a clickable .url shortcut next to this script in the private repo, so
# the link is there next time without re-running or digging through scrollback.
# Points at the direct zip download (triggers immediately, no click-through),
# not the repo homepage. Self-excluded from the snapshot above, so it never
# reaches the public copy.
$urlShortcutPath = Join-Path $PSScriptRoot $urlShortcutName
Set-Content -LiteralPath $urlShortcutPath -Value "[InternetShortcut]`r`nURL=$zipUrl`r`n" -Encoding ascii
Write-Ok "Shortcut written: $urlShortcutPath"

try { Set-Clipboard -Value $zipUrl; Write-Ok "Zip download URL copied to clipboard." } catch {}
Write-Host ""
Write-Step "Direct zip download (no account/credentials needed):"
Write-Host "    $zipUrl" -ForegroundColor White
Write-Step "Repo page:"
Write-Host "    $publicUrl" -ForegroundColor DarkGray

}
catch {
    Write-Host ""
    Write-Host "[!!] $($_.Exception.Message)" -ForegroundColor Red
    $global:LASTEXITCODE = 1
}
finally {
    if (-not $NoPause -and $env:CI -ne 'true') {
        Write-Host ""
        Read-Host 'Press Enter to close'
    }
}
