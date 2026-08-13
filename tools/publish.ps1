# pages/tools/publish.ps1
param(
    [Parameter(Mandatory = $true)][string]$Project,
    [Parameter(Mandatory = $true)][string]$Abbrev,
    [Parameter(Mandatory = $true)][string]$CopyPairs,
    [string]$PagesDir = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

$LogFile = Join-Path $PagesDir 'tools\publish.log'
New-Item -ItemType Directory -Force -Path (Split-Path $LogFile) | Out-Null

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

function Invoke-GitLogged {
    param([string[]]$GitArgs, [string]$LogPrefix)
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git @GitArgs 2>&1 | ForEach-Object { Write-Log "$LogPrefix`: $_" }
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    return $LASTEXITCODE
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
        $rc = Invoke-GitLogged -GitArgs @('pull', '--rebase', 'origin', 'main') -LogPrefix 'pull'
        if ($rc -ne 0) {
            Write-Log "ERROR: git pull --rebase failed (exit $rc)"
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
        $rc = Invoke-GitLogged -GitArgs @('commit', '-m', $msg) -LogPrefix 'commit'
        if ($rc -ne 0) {
            Write-Log "ERROR: git commit failed (exit $rc)"
            exit 1
        }

        $pushed = $false
        for ($i = 1; $i -le 3; $i++) {
            $rc = Invoke-GitLogged -GitArgs @('push', 'origin', 'main') -LogPrefix "push attempt $i"
            if ($rc -eq 0) { $pushed = $true; break }
            Write-Log "push attempt $i failed - pull --rebase and retry"
            Invoke-GitLogged -GitArgs @('pull', '--rebase', 'origin', 'main') -LogPrefix 'pull retry' | Out-Null
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
