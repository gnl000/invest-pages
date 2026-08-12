# invest-pages Auto-Publish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a single shared PowerShell script that copies a project's newest output file(s) into `invest\pages\<project>\`, then pulls/commits/pushes the `pages` repo, guarded by a lock so `event-news` and `value-tracking-agent` can each hook into it from their own automation entry points without racing on git state.

**Architecture:** One generic script, `pages/tools/publish.ps1`, takes a project name, a commit-message abbreviation, and a list of `source-pattern=>dest-relative-path` pairs. It resolves each source pattern to the most-recently-modified matching file, copies it into `pages/<project>/`, and performs `git pull --rebase` → `git add` (scoped to that project's subfolder only) → `git commit` (skipped if nothing changed) → `git push` (retried up to 3 times with re-pull on rejection) — all inside an `mkdir`-based cross-process lock on `pages/.publish.lock` so two callers never run git commands in the shared `pages` working tree at the same time. `event-news/run_agent.bat`, `event-news/run_weekly_now.bat`, `event-news/run_weekly_reuse.bat`, and `value-tracking-agent/scripts/build_dashboard.py` each call this script with one line after they finish producing their own output.

**Tech Stack:** Windows PowerShell (5.1, the Windows-builtin `powershell.exe` — no PowerShell 7 dependency), Windows batch (`.bat`), Python 3 (`subprocess`), git over SSH.

## Global Constraints

- Commit message format (fixed by user decision): `auto update <ABBREV> <yyyy-MM-dd HH:mm>` — e.g. `auto update EN 2026-08-13 09:00`. Abbreviations: `EN` = event-news, `VT` = value-tracking-agent.
- `git add` inside `publish.ps1` must only ever stage the calling project's own subfolder (`git add -- "<Project>"`), never `-A` or `.`, so a concurrently-copied-but-not-yet-committed file from another project can never be swept into the wrong commit.
- Lock directory: `pages/.publish.lock` (mkdir-based, atomic create). Stale-lock threshold: 5 minutes. Max wait to acquire: 3 minutes, then abort with a logged error (must not hang forever).
- All publish activity is appended to `pages/tools/publish.log` (own log, separate from each project's `output/logs/scheduler.log`).
- A failed publish must never fail the calling project's own run (the agent's actual output was already produced successfully) — callers log the failure and continue, they do not propagate the publish exit code as their own.
- `pages` repo remote is SSH (`git@github.com:gnl000/invest-pages.git`), branch `main`, already configured with a passphrase-less account SSH key that is confirmed working.

---

## Task 1: Core publish script

**Files:**
- Create: `pages/tools/publish.ps1`
- Create: `pages/.gitignore`

**Interfaces:**
- Produces: a script invocable as
  `powershell -NoProfile -ExecutionPolicy Bypass -File <path>\pages\tools\publish.ps1 -Project <string> -Abbrev <string> -CopyPairs "<src=>dest;src=>dest;...>" [-PagesDir <path>]`
  - `-Project`: subfolder name under `pages/` (e.g. `event-news`).
  - `-Abbrev`: short code used in the commit message (e.g. `EN`).
  - `-CopyPairs`: semicolon-separated list of `sourcePattern=>destRelativePath` pairs. `sourcePattern` may be an exact file path or a glob (e.g. `...\output\daily\*.html`); the script always resolves it to the single most-recently-modified matching file. `destRelativePath` is relative to `pages/<Project>/`.
  - `-PagesDir` (optional): defaults to the parent of the script's own location (i.e. `pages/`). Exists so tests can point the script at a scratch repo instead of the real one.
  - Exit code: `0` on success (including the "nothing changed, skipped commit" case), non-zero on any failure (lock timeout, pull failure, unresolvable source pattern, push failure after retries).
- Consumes: nothing from other tasks (this is the foundation).

- [ ] **Step 1: Create the script file**

```powershell
# pages/tools/publish.ps1
param(
    [Parameter(Mandatory = $true)][string]$Project,
    [Parameter(Mandatory = $true)][string]$Abbrev,
    [Parameter(Mandatory = $true)][string]$CopyPairs,
    [string]$PagesDir = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

$LogFile = Join-Path $PagesDir 'tools\publish.log'

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $LogFile -Value "[$ts] [$Abbrev] $Message"
}

function Resolve-CopyPairs {
    param([string]$Spec)
    $pairs = @()
    foreach ($entry in $Spec -split ';') {
        $entry = $entry.Trim()
        if (-not $entry) { continue }
        $parts = $entry -split '=>'
        if ($parts.Count -ne 2) {
            throw "Invalid -CopyPairs entry (expected 'src=>dest'): $entry"
        }
        $srcPattern = $parts[0].Trim()
        $destRel = $parts[1].Trim()
        $resolved = Get-ChildItem -Path $srcPattern -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $resolved) {
            throw "No file matched source pattern: $srcPattern"
        }
        $pairs += [pscustomobject]@{ Src = $resolved.FullName; Dest = $destRel }
    }
    return $pairs
}

function Acquire-Lock {
    param([string]$LockDir, [int]$StaleMinutes = 5, [int]$MaxWaitMinutes = 3)
    $stampFile = Join-Path $LockDir 'stamp.txt'
    $deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
    while ($true) {
        try {
            New-Item -ItemType Directory -Path $LockDir -ErrorAction Stop | Out-Null
            Set-Content -Path $stampFile -Value (Get-Date -Format 'o')
            return
        } catch {
            if (Test-Path $stampFile) {
                try {
                    $age = (Get-Date) - (Get-Date (Get-Content $stampFile -ErrorAction Stop))
                    if ($age.TotalMinutes -gt $StaleMinutes) {
                        Write-Log "Stale lock (age $([int]$age.TotalMinutes)m) - reclaiming"
                        Remove-Item -Recurse -Force $LockDir -ErrorAction SilentlyContinue
                        continue
                    }
                } catch {
                    # stamp unreadable - fall through to wait/retry
                }
            }
            if ((Get-Date) -gt $deadline) {
                throw "Could not acquire lock at $LockDir within $MaxWaitMinutes minutes"
            }
            Start-Sleep -Seconds 5
        }
    }
}

Write-Log "start: Project=$Project CopyPairs=$CopyPairs"

try {
    $pairs = Resolve-CopyPairs -Spec $CopyPairs
} catch {
    Write-Log "ERROR resolving copy pairs: $_"
    exit 1
}

$lockDir = Join-Path $PagesDir '.publish.lock'
try {
    Acquire-Lock -LockDir $lockDir
} catch {
    Write-Log "ERROR: $_"
    exit 1
}

try {
    Push-Location $PagesDir
    try {
        git pull --rebase origin main 2>&1 | ForEach-Object { Write-Log "pull: $_" }
        if ($LASTEXITCODE -ne 0) {
            Write-Log "ERROR: git pull --rebase failed (exit $LASTEXITCODE)"
            exit 1
        }

        foreach ($pair in $pairs) {
            $destPath = Join-Path $PagesDir (Join-Path $Project $pair.Dest)
            New-Item -ItemType Directory -Force -Path (Split-Path $destPath) | Out-Null
            Copy-Item -Path $pair.Src -Destination $destPath -Force
            Write-Log "copied $($pair.Src) -> $destPath"
        }

        git add -- "$Project"
        git diff --cached --quiet
        if ($LASTEXITCODE -eq 0) {
            Write-Log "no changes to commit"
            exit 0
        }

        $msg = "auto update $Abbrev $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        git commit -m $msg 2>&1 | ForEach-Object { Write-Log "commit: $_" }

        $pushed = $false
        for ($i = 1; $i -le 3; $i++) {
            git push origin main 2>&1 | ForEach-Object { Write-Log "push attempt ${i}: $_" }
            if ($LASTEXITCODE -eq 0) { $pushed = $true; break }
            Write-Log "push attempt $i failed - pull --rebase and retry"
            git pull --rebase origin main 2>&1 | ForEach-Object { Write-Log "pull retry: $_" }
            Start-Sleep -Seconds (5 * $i)
        }
        if (-not $pushed) {
            Write-Log "ERROR: push failed after 3 attempts"
            exit 1
        }
        Write-Log "SUCCESS: pushed - $msg"
    } finally {
        Pop-Location
    }
} finally {
    Remove-Item -Recurse -Force $lockDir -ErrorAction SilentlyContinue
}

exit 0
```

- [ ] **Step 2: Add `.gitignore` so the log and lock never get committed**

```
tools/publish.log
.publish.lock/
```

- [ ] **Step 3: Commit**

```bash
cd pages
git add tools/publish.ps1 .gitignore
git commit -m "feat: add shared pages publish script"
git push origin main
```

---

## Task 2: Verify core copy/commit/skip behavior against a scratch repo

Do **not** point this at the real `pages` repo — use a throwaway local bare repo so verification never touches GitHub.

**Files:**
- None (verification only, uses temp files under `$env:TEMP`)

**Interfaces:**
- Consumes: `pages/tools/publish.ps1` from Task 1, called with `-PagesDir` overridden to a scratch clone.

- [ ] **Step 1: Build a scratch origin + clone shaped like `pages`**

```powershell
$scratch = Join-Path $env:TEMP "pages-test-$(Get-Random)"
git init --bare "$scratch-origin.git" | Out-Null
git clone "$scratch-origin.git" $scratch | Out-Null
Push-Location $scratch
New-Item -ItemType Directory event-news, value-tracking-agent | Out-Null
"seed" | Set-Content event-news\.gitkeep
git add -A
git commit -m "seed" | Out-Null
git branch -M main
git push -u origin main | Out-Null
Pop-Location
```

- [ ] **Step 2: Run publish.ps1 with a real source file, pointed at the scratch repo**

```powershell
$src = Join-Path $env:TEMP "src-$(Get-Random)"
New-Item -ItemType Directory $src | Out-Null
"<html>v1</html>" | Set-Content (Join-Path $src "daily.html")

powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\eugin\siri\A_project\invest\pages\tools\publish.ps1" `
    -Project "event-news" -Abbrev "EN" `
    -CopyPairs "$src\*.html=>daily.html" `
    -PagesDir $scratch
```

Expected: exit code `0`.

- [ ] **Step 3: Confirm the commit and file content**

```powershell
git -C $scratch log --oneline -1
git -C $scratch show HEAD:event-news/daily.html
```

Expected: log line matches `auto update EN yyyy-MM-dd HH:mm`; file content is `<html>v1</html>`.

- [ ] **Step 4: Re-run with unchanged source — verify commit is skipped**

```powershell
$before = git -C $scratch rev-parse HEAD
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\eugin\siri\A_project\invest\pages\tools\publish.ps1" `
    -Project "event-news" -Abbrev "EN" -CopyPairs "$src\*.html=>daily.html" -PagesDir $scratch
$after = git -C $scratch rev-parse HEAD
if ($before -ne $after) { throw "expected no new commit" }
```

Expected: no error thrown; `$before -eq $after`.

- [ ] **Step 5: Change the source and re-run — verify a new commit appears**

```powershell
"<html>v2</html>" | Set-Content (Join-Path $src "daily.html")
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\eugin\siri\A_project\invest\pages\tools\publish.ps1" `
    -Project "event-news" -Abbrev "EN" -CopyPairs "$src\*.html=>daily.html" -PagesDir $scratch
git -C $scratch show HEAD:event-news/daily.html
```

Expected: content is now `<html>v2</html>`, and `git -C $scratch log --oneline` shows 3 commits total (seed, v1, v2).

- [ ] **Step 6: Confirm cleanup**

```powershell
Test-Path (Join-Path $scratch ".publish.lock")
```

Expected: `False` (lock always removed, even on the skip-commit path).

No need to delete the scratch dirs afterward — Task 3 reuses this same scratch repo.

---

## Task 3: Verify lock contention and stale-lock recovery

**Files:** none (verification only, continues using the Task 2 scratch repo/`$scratch`, `$src` variables — re-run in the same PowerShell session, or recreate them per Task 2 Step 1 first)

**Interfaces:**
- Consumes: same `publish.ps1` CLI as Task 2.

- [ ] **Step 1: Verify a live lock makes a second call wait, not fail**

```powershell
# Hold the lock in a background job for 10 seconds
$job = Start-Job -ScriptBlock {
    param($dir)
    New-Item -ItemType Directory (Join-Path $dir ".publish.lock") | Out-Null
    Set-Content (Join-Path $dir ".publish.lock\stamp.txt") (Get-Date -Format 'o')
    Start-Sleep -Seconds 10
    Remove-Item -Recurse -Force (Join-Path $dir ".publish.lock")
} -ArgumentList $scratch

Start-Sleep -Seconds 2   # let the job grab the lock first
$sw = [Diagnostics.Stopwatch]::StartNew()
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\eugin\siri\A_project\invest\pages\tools\publish.ps1" `
    -Project "event-news" -Abbrev "EN" -CopyPairs "$src\*.html=>daily.html" -PagesDir $scratch
$sw.Stop()
Receive-Job $job -Wait | Out-Null
Remove-Job $job
$sw.Elapsed.TotalSeconds
```

Expected: exit code `0`, and elapsed time is roughly 6-9 seconds (it waited out the held lock in ~5s polling increments, not failed immediately).

- [ ] **Step 2: Verify a stale lock (old timestamp) is reclaimed instead of waited out for the full 3 minutes**

```powershell
New-Item -ItemType Directory (Join-Path $scratch ".publish.lock") | Out-Null
(Get-Date).AddMinutes(-10).ToString('o') | Set-Content (Join-Path $scratch ".publish.lock\stamp.txt")

$sw = [Diagnostics.Stopwatch]::StartNew()
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\eugin\siri\A_project\invest\pages\tools\publish.ps1" `
    -Project "event-news" -Abbrev "EN" -CopyPairs "$src\*.html=>daily.html" -PagesDir $scratch
$sw.Stop()
$sw.Elapsed.TotalSeconds
```

Expected: exit code `0`, elapsed time well under 30 seconds (reclaimed immediately rather than waiting the 3-minute deadline).

- [ ] **Step 3: Clean up scratch repos**

```powershell
Remove-Item -Recurse -Force $scratch, "$scratch-origin.git", $src -ErrorAction SilentlyContinue
```

---

## Task 4: Hook into event-news daily run (`run_agent.bat`)

**Files:**
- Modify: `event-news/run_agent.bat`

**Interfaces:**
- Consumes: `pages/tools/publish.ps1` from Task 1, called with `-Project event-news -Abbrev EN -CopyPairs "<event-news>\output\daily\*.html=>daily.html"`.

- [ ] **Step 1: Add a `:publish_daily` subroutine and call it from the SUCCESS branch**

In `event-news/run_agent.bat`, change:

```bat
if "%RC%"=="0" (
    echo ===== [%date% %time%] SUCCESS on attempt %TRY%/%MAXTRY% ===== >> "%LOG%"
    goto :done
)
```

to:

```bat
if "%RC%"=="0" (
    echo ===== [%date% %time%] SUCCESS on attempt %TRY%/%MAXTRY% ===== >> "%LOG%"
    call :publish_daily
    goto :done
)
```

and add this subroutine right before the `:done` label:

```bat
:publish_daily
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\pages\tools\publish.ps1" -Project "event-news" -Abbrev "EN" -CopyPairs "%~dp0output\daily\*.html=>daily.html" >> "%LOG%" 2>&1
if errorlevel 1 (
    echo ===== [%date% %time%] PUBLISH to pages FAILED - see pages\tools\publish.log ===== >> "%LOG%"
) else (
    echo ===== [%date% %time%] PUBLISH to pages OK ===== >> "%LOG%"
)
exit /b 0
```

Note: the `exit /b 0` inside `:publish_daily` only ends the subroutine (returns to the `call` site) since it's a `call`ed label, not the script. A publish failure is logged but never changes the outer `%RC%` — the agent run's own success/failure is unaffected by the pages publish step.

- [ ] **Step 2: Verify the exact command in isolation, against the Task 2/3 scratch pattern (not the real pages repo)**

Recreate a scratch repo as in Task 2 Step 1 (call it `$scratch`), then run the literal command that now lives in the `.bat`, substituting the real event-news output dir as the source and the scratch repo as the destination:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\eugin\siri\A_project\invest\pages\tools\publish.ps1" `
    -Project "event-news" -Abbrev "EN" `
    -CopyPairs "C:\Users\eugin\siri\A_project\invest\event-news\output\daily\*.html=>daily.html" `
    -PagesDir $scratch
git -C $scratch show HEAD:event-news/daily.html | Select-Object -First 5
```

Expected: exit `0`; the first lines are real HTML from event-news's newest daily report.

- [ ] **Step 3: Commit**

```bash
cd event-news
git add run_agent.bat
git commit -m "feat: publish daily report to pages after successful run"
```

(This is event-news's own repo, separate from `pages` — do not push unless the user asks.)

---

## Task 5: Hook into event-news weekly runs

**Files:**
- Modify: `event-news/run_weekly_now.bat`
- Modify: `event-news/run_weekly_reuse.bat`

**Interfaces:**
- Consumes: same `publish.ps1` as Task 4, with `-CopyPairs "<event-news>\output\weekly\*.html=>weekly.html"` (the `*.html` glob only matches the top-level dated files like `2026-W33.html`, not the per-week subfolders of intermediate JSON — `Get-ChildItem -File` does not recurse into them).

- [ ] **Step 1: Apply the same edit pattern to both files**

Both files share the identical `if "%RC%"=="0" ( ... goto :done )` / `:done` structure already read from the repo. In **both** `run_weekly_now.bat` and `run_weekly_reuse.bat`, change:

```bat
if "%RC%"=="0" (
    echo ===== [%date% %time%] SUCCESS on attempt %TRY%/%MAXTRY% ===== >> "%LOG%"
    goto :done
)
```

to:

```bat
if "%RC%"=="0" (
    echo ===== [%date% %time%] SUCCESS on attempt %TRY%/%MAXTRY% ===== >> "%LOG%"
    call :publish_weekly
    goto :done
)
```

and add this subroutine before `:done` in both files:

```bat
:publish_weekly
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\pages\tools\publish.ps1" -Project "event-news" -Abbrev "EN" -CopyPairs "%~dp0output\weekly\*.html=>weekly.html" >> "%LOG%" 2>&1
if errorlevel 1 (
    echo ===== [%date% %time%] PUBLISH to pages FAILED - see pages\tools\publish.log ===== >> "%LOG%"
) else (
    echo ===== [%date% %time%] PUBLISH to pages OK ===== >> "%LOG%"
)
exit /b 0
```

- [ ] **Step 2: Verify in isolation against a scratch repo**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\eugin\siri\A_project\invest\pages\tools\publish.ps1" `
    -Project "event-news" -Abbrev "EN" `
    -CopyPairs "C:\Users\eugin\siri\A_project\invest\event-news\output\weekly\*.html=>weekly.html" `
    -PagesDir $scratch
git -C $scratch show HEAD:event-news/weekly.html | Select-Object -First 5
```

Expected: exit `0`; output is real weekly HTML content (the newest `output\weekly\2026-W*.html`, not one of the per-week subfolder files).

- [ ] **Step 3: Commit**

```bash
cd event-news
git add run_weekly_now.bat run_weekly_reuse.bat
git commit -m "feat: publish weekly report to pages after successful run"
```

---

## Task 6: Hook into value-tracking-agent's quarterly dashboard build

**Files:**
- Modify: `value-tracking-agent/scripts/build_dashboard.py`

**Interfaces:**
- Consumes: `pages/tools/publish.ps1`, called with `-Project value-tracking-agent -Abbrev VT` and two copy pairs from the same `OUT_PATH` (preserve original filename + refresh `latest.html`).

- [ ] **Step 1: Add `import subprocess`**

At the top of `value-tracking-agent/scripts/build_dashboard.py`, next to the existing imports (currently `argparse, json, sys, yaml, Counter, defaultdict, datetime, Path`):

```python
import subprocess
```

- [ ] **Step 2: Add a `_publish_to_pages` helper**

Add this function above `def main():`:

```python
def _publish_to_pages(html_path: Path) -> None:
    pages_dir = Path(__file__).resolve().parents[2] / "pages"
    publish_script = pages_dir / "tools" / "publish.ps1"
    if not publish_script.exists():
        print(f"[WARN] publish.ps1 not found at {publish_script} - skipping pages publish")
        return
    resolved = str(html_path.resolve())
    copy_pairs = f"{resolved}=>{html_path.name};{resolved}=>latest.html"
    result = subprocess.run(
        ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(publish_script),
         "-Project", "value-tracking-agent", "-Abbrev", "VT", "-CopyPairs", copy_pairs],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"[WARN] pages publish failed (see pages/tools/publish.log):\n{result.stdout}\n{result.stderr}")
    else:
        print("[OK] published dashboard to pages")
```

`Path(__file__).resolve().parents[2]` from `value-tracking-agent/scripts/build_dashboard.py` is: `parents[0]`=`scripts`, `parents[1]`=`value-tracking-agent`, `parents[2]`=`invest` — so `pages_dir` resolves to `invest/pages`, matching the sibling-folder layout.

- [ ] **Step 3: Call it at the end of `main()`, after the HTML is actually written**

Change (currently at the end of `main()`):

```python
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(html, encoding="utf-8")
    print(f"[OK] HTML 대시보드 저장: {OUT_PATH} ({len(html)//1024}KB)")
    print(f"[OK] Excel 전체종목 저장: {XLSX_PATH} ({xlsx_rows}행)")
    return total, grades
```

to:

```python
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(html, encoding="utf-8")
    print(f"[OK] HTML 대시보드 저장: {OUT_PATH} ({len(html)//1024}KB)")
    print(f"[OK] Excel 전체종목 저장: {XLSX_PATH} ({xlsx_rows}행)")
    _publish_to_pages(OUT_PATH)
    return total, grades
```

- [ ] **Step 4: Verify in isolation against a scratch repo, using an already-existing real dashboard file**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\eugin\siri\A_project\invest\pages\tools\publish.ps1" `
    -Project "value-tracking-agent" -Abbrev "VT" `
    -CopyPairs "C:\Users\eugin\siri\A_project\invest\value-tracking-agent\output\quarterly\dashboard_2026Q3_260730.html=>dashboard_2026Q3_260730.html;C:\Users\eugin\siri\A_project\invest\value-tracking-agent\output\quarterly\dashboard_2026Q3_260730.html=>latest.html" `
    -PagesDir $scratch
git -C $scratch ls-tree -r HEAD --name-only | Select-String "value-tracking-agent"
```

Expected: exit `0`; listing shows both `value-tracking-agent/dashboard_2026Q3_260730.html` and `value-tracking-agent/latest.html`.

The `-CopyPairs` string above is exactly what `_publish_to_pages` builds from `OUT_PATH`, so this confirms the plumbing end-to-end without needing a full quarterly data run. Separately, confirm the edited Python file still parses:

```powershell
cd C:\Users\eugin\siri\A_project\invest\value-tracking-agent
.venv\Scripts\python -c "import ast; ast.parse(open('scripts/build_dashboard.py', encoding='utf-8').read())"
```

Expected: no output, exit code 0 (confirms the file still parses after the edit).

- [ ] **Step 5: Commit**

```bash
cd value-tracking-agent
git add scripts/build_dashboard.py
git commit -m "feat: publish quarterly dashboard to pages after each build"
```

---

## Task 7: Real end-to-end verification against the live `pages` repo

This is the only task that touches the real GitHub repo. Everything up to here was verified against scratch repos, so this should just work — but confirm it for real before considering the feature done.

**Files:** none (verification only)

**Interfaces:** none new — exercises Tasks 4-6's exact `publish.ps1` invocations against the real `-PagesDir` default (no override).

- [ ] **Step 1: Publish the current newest event-news daily report for real**

```powershell
cd C:\Users\eugin\siri\A_project\invest
powershell -NoProfile -ExecutionPolicy Bypass -File "pages\tools\publish.ps1" -Project "event-news" -Abbrev "EN" -CopyPairs "event-news\output\daily\*.html=>daily.html"
```

Expected: exit `0`. If the file is unchanged since the earlier manual bootstrap copy, this should log "no changes to commit" and exit 0 without pushing — that is also a correct, expected outcome, not a failure.

- [ ] **Step 2: Publish the current newest event-news weekly report for real**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "pages\tools\publish.ps1" -Project "event-news" -Abbrev "EN" -CopyPairs "event-news\output\weekly\*.html=>weekly.html"
```

Expected: exit `0`.

- [ ] **Step 3: Publish the current newest value-tracking-agent dashboard for real**

```powershell
$latest = Get-ChildItem "value-tracking-agent\output\quarterly\dashboard_*.html" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
powershell -NoProfile -ExecutionPolicy Bypass -File "pages\tools\publish.ps1" -Project "value-tracking-agent" -Abbrev "VT" -CopyPairs "$($latest.FullName)=>$($latest.Name);$($latest.FullName)=>latest.html"
```

Expected: exit `0`.

- [ ] **Step 4: Confirm the remote reflects it**

```powershell
git -C pages log --oneline -5
git -C pages log origin/main..HEAD
```

Expected: `git -C pages log origin/main..HEAD` is empty (local `main` and `origin/main` match — everything that got committed also got pushed).

- [ ] **Step 5: Confirm the live site**

Open `https://gnl000.github.io/invest-pages/` and check that `event-news/daily.html`, `event-news/weekly.html`, and `value-tracking-agent/latest.html` load and show real content (GitHub Pages can take a minute or two to rebuild after a push).
