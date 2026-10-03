<#
.SYNOPSIS
  Plugin <-> DeepSeek Harness compatibility pre-check (run before ANY plugin update).

.DESCRIPTION
  Verifies that candidate plugin versions' peerDependencies (especially
  @deepseek-ai/*) and engines.node fit the installed DeepSeek Harness.

  Rule (established after the 2026-08-31 incident):
  - The numeric window of every peer range declared by the plugin must contain
    the harness-provided version. The harness version is evaluated with its
    prerelease stripped (0.1.1-rc.2 -> 0.1.1); the strict node-semver result
    (prerelease tuple rule) is also shown for reference.
  - Known bad case: @nanmicoder/dsh-agent-teams@0.1.15 peers on
    @deepseek-ai/dsh-*@^0.1.2-alpha.2 while the harness only provides
    0.1.1-rc.2 (0.1.1 < 0.1.2) -> INCOMPATIBLE; it broke the profile and had
    to be reverted to 0.1.14.

  Implementation notes (sandbox-safe):
  - External process spawns (npm view via cmd) happen ONLY in the script's
    main scope, with cmd-side file redirection and never through PowerShell
    pipes or stderr redirects.
  - Semver evaluation is implemented in pure PowerShell (no node spawn).
  - Node version comes from the node.exe file version (no spawn).

.EXAMPLE
  # Check specific candidates (comma separated name[@version])
  .\check-plugin-compat.ps1 -Specs 'dshmarket@1.38.1,@nanmicoder/dsh-agent-teams@0.1.15'

  # Check every dependency currently installed in the web profile
  .\check-plugin-compat.ps1

  # Check another profile
  .\check-plugin-compat.ps1 -Profile "$env:USERPROFILE\.dsh\profiles\dsh-tui"

.PARAMETER Specs
  Comma-separated name[@version] candidates; defaults to the profile's
  package.json dependencies at their installed versions.

.PARAMETER Profile
  Profile directory; defaults to $env:DSH_HOME\profiles\web.

.PARAMETER CacheDir
  npm metadata cache directory; defaults to $PSScriptRoot\.npm-cache-compat
  (inside the workspace).

.PARAMETER Help
  Print this usage summary and exit without running any check.
#>
param(
    [string]$Specs = '',
    [string]$Profile = (Join-Path $env:DSH_HOME 'profiles\web'),
    [string]$CacheDir = (Join-Path $PSScriptRoot '.npm-cache-compat'),
    [Alias('h', '?')]
    [switch]$Help
)

if ($Help) {
    Get-Help $PSCommandPath -Detailed
    @'

Exit codes: 0 = pass | 1 = incompatible (do NOT update) | 3 = could not verify
Examples:
  .\check-plugin-compat.ps1 -Specs 'dshmarket@1.38.1'
  .\check-plugin-compat.ps1 -Profile "$env:USERPROFILE\.dsh\profiles\desktop"
'@ | Write-Host
    exit 0
}

$ErrorActionPreference = 'Continue'

# ---------- pure helpers (no external spawns) ----------

function ConvertTo-VersionObject {
    # "1.2.3-pre.1+build" -> [PSCustomObject]@{ major; minor; patch; pre = string[] }
    param([string]$Text)
    $m = [regex]::Match(($Text.Trim().TrimStart('v')), '^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$')
    if (-not $m.Success) { return $null }
    $pre = @()
    if ($m.Groups[4].Success -and $m.Groups[4].Value) { $pre = $m.Groups[4].Value -split '\.' }
    return [PSCustomObject]@{ major = [int]$m.Groups[1].Value; minor = [int]$m.Groups[2].Value; patch = [int]$m.Groups[3].Value; pre = $pre }
}

function Compare-VersionObject {
    # returns -1/0/1: $a < $b -> -1, per semver precedence (prerelease-aware)
    param($a, $b)
    if ($null -eq $a -or $null -eq $b) { return 0 }
    foreach ($k in 'major', 'minor', 'patch') {
        if ($a.$k -ne $b.$k) { return [math]::Sign($a.$k - $b.$k) }
    }
    $ap = @($a.pre); $bp = @($b.pre)
    if ($ap.Count -eq 0 -and $bp.Count -eq 0) { return 0 }
    if ($ap.Count -eq 0) { return 1 }
    if ($bp.Count -eq 0) { return -1 }
    $n = [math]::Min($ap.Count, $bp.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $x = $ap[$i]; $y = $bp[$i]
        if ($x -eq $y) { continue }
        $xn = 0; $yn = 0
        $xIsNum = [int]::TryParse($x, [ref]$xn)
        $yIsNum = [int]::TryParse($y, [ref]$yn)
        if ($xIsNum -and $yIsNum) { return [math]::Sign($xn - $yn) }
        if ($xIsNum) { return -1 }
        if ($yIsNum) { return 1 }
        if ([string]::CompareOrdinal($x, $y) -lt 0) { return -1 }
        return 1
    }
    if ($ap.Count -eq $bp.Count) { return 0 }
    if ($ap.Count -lt $bp.Count) { return -1 }
    return 1
}

function Pad-VersionText {
    # pad short comparator versions for operators: >=24 -> >=24.0.0, ~1.2 -> ~1.2.0
    param([string]$Text)
    $base = ($Text -split '[+-]')[0]
    $parts = $base -split '\.'
    if ($parts.Count -lt 3) {
        while ($parts.Count -lt 3) { $parts += '0' }
        $suffix = $Text.Substring($base.Length)
        return (($parts -join '.') + $suffix)
    }
    return $Text
}

function New-Bound {
    # version string (possibly with operator) -> [PSCustomObject]@{ op; ver; ok }
    param([string]$Token)
    $tok = $Token.Trim()
    if (-not $tok) { return $null }
    if ($tok -match '^(\^|~|>=|<=|>|<)(.+)$') {
        return [PSCustomObject]@{ op = $matches[1]; ver = (Pad-VersionText -Text $matches[2].Trim()) }
    }
    return [PSCustomObject]@{ op = '='; ver = $tok }
}

function Get-RangeWindow {
    # one comparator token -> [lo(ver obj, incl), hi(ver obj, incl)] or $null if exact-only
    param([string]$Token)
    $b = New-Bound -Token $Token
    if ($null -eq $b) { return $null }
    $v = ConvertTo-VersionObject -Text $b.ver
    # bare "1"/"1.2" versions fail x.y.z parsing; the '=' branch handles them from parts
    if ($null -eq $v -and $b.op -ne '=') { return $null }
    switch ($b.op) {
        '=' {
            $parts = $b.ver.TrimStart('v') -split '\.'
            if ($parts.Count -eq 1) {
                # bare "1" behaves like ~1: >=1.0.0 <2.0.0
                $lo = [PSCustomObject]@{ major = [int]$parts[0]; minor = 0; patch = 0; pre = @() }
                $hi = [PSCustomObject]@{ major = [int]$parts[0] + 1; minor = 0; patch = 0; pre = @() }
                return @(@($lo, $true), @($hi, $false))
            }
            if ($parts.Count -eq 2) {
                # bare "1.2" behaves like ~1.2: >=1.2.0 <1.3.0
                $lo = [PSCustomObject]@{ major = [int]$parts[0]; minor = [int]$parts[1]; patch = 0; pre = @() }
                $hi = [PSCustomObject]@{ major = [int]$parts[0]; minor = [int]$parts[1] + 1; patch = 0; pre = @() }
                return @(@($lo, $true), @($hi, $false))
            }
            return @(@($v, $true), @($v, $true))
        }
        '>=' { return @(@($v, $true), @($null, $false)) }
        '>'  { return @(@($v, $false), @($null, $false)) }
        '<=' { return @(@($null, $false), @($v, $true)) }
        '<'  { return @(@($null, $false), @($v, $false)) }
        '^' {
            $lo = $v
            if ($v.major -gt 0) { $hi = [PSCustomObject]@{ major = $v.major + 1; minor = 0; patch = 0; pre = @() } }
            elseif ($v.minor -gt 0) { $hi = [PSCustomObject]@{ major = 0; minor = $v.minor + 1; patch = 0; pre = @() } }
            elseif ($v.patch -gt 0) { $hi = [PSCustomObject]@{ major = 0; minor = 0; patch = $v.patch + 1; pre = @() } }
            else { return @(@($v, $true), @($v, $true)) }  # ^0.0.0 -> exact 0.0.0
            return @(@($lo, $true), @($hi, $false))
        }
        '~' {
            $hi = [PSCustomObject]@{ major = $v.major; minor = $v.minor + 1; patch = 0; pre = @() }
            return @(@($v, $true), @($hi, $false))
        }
    }
    return $null
}

function Test-SingleRange {
    # one alternative of a range (space-separated comparators, ANDed)
    param([string]$Alternative, $Version, [bool]$Strict)
    $tokens = $Alternative -split '\s+' | Where-Object { $_ }
    if ($tokens.Count -eq 0) { return $true }
    # strict prerelease tuple rule: a prerelease candidate only matches when some
    # comparator in the set carries the same major.minor.patch tuple (with prerelease)
    if ($Strict -and @($Version.pre).Count -gt 0) {
        $allowed = $false
        foreach ($t in $tokens) {
            $b = New-Bound -Token $t
            if ($null -eq $b) { continue }
            $tv = ConvertTo-VersionObject -Text $b.ver
            if ($null -eq $tv) { continue }
            if ($tv.major -eq $Version.major -and $tv.minor -eq $Version.minor -and $tv.patch -eq $Version.patch -and @($tv.pre).Count -gt 0) {
                $allowed = $true
                break
            }
        }
        if (-not $allowed) { return $false }
    }
    foreach ($t in $tokens) {
        $win = Get-RangeWindow -Token $t
        if ($null -eq $win) { return $false }
        $lo = $win[0][0]; $loIncl = $win[0][1]
        $hi = $win[1][0]; $hiIncl = $win[1][1]
        if ($null -ne $lo) {
            $c = Compare-VersionObject -a $Version -b $lo
            if ($c -lt 0 -or ($c -eq 0 -and -not $loIncl)) { return $false }
        }
        if ($null -ne $hi) {
            $c = Compare-VersionObject -a $Version -b $hi
            if ($c -gt 0 -or ($c -eq 0 -and -not $hiIncl)) { return $false }
        }
    }
    return $true
}

function Test-VersionRange {
    # range like "^0.1.0-rc.6" or "^1.2.0 || >=2.0.0 <3.0.0"
    # Strict=$false: candidate prerelease stripped (numeric window, the verdict rule)
    # Strict=$true:  candidate kept as-is with the node-semver prerelease tuple rule
    param([string]$Range, [string]$Version, [bool]$Strict = $false)
    $ver = ConvertTo-VersionObject -Text $Version
    if ($null -eq $ver) { return $null }
    $probe = $ver
    if (-not $Strict -and @($ver.pre).Count -gt 0) {
        $probe = [PSCustomObject]@{ major = $ver.major; minor = $ver.minor; patch = $ver.patch; pre = @() }
    }
    foreach ($alt in ($Range -split '\|\|')) {
        if (Test-SingleRange -Alternative $alt -Version $probe -Strict $Strict) { return $true }
    }
    return $false
}

# ---------- main ----------

Write-Host '========== Plugin x DeepSeek Harness compatibility pre-check ==========' -ForegroundColor Cyan

# --- harness inventory (pure file reads; npm root resolved once via bare spawn) ---
$npmRootFile = Join-Path $CacheDir 'npm-root.txt'
if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null }
& cmd /c "npm.cmd root -g > `"$npmRootFile`" 2>nul"
$npmRoot = $null
if (Test-Path $npmRootFile) {
    $npmRoot = (Get-Content $npmRootFile -Raw).Trim()
    Remove-Item $npmRootFile -Force -ErrorAction SilentlyContinue
}

$harnessCandidates = @()
if ($npmRoot) { $harnessCandidates += (Join-Path $npmRoot '@deepseek-ai\dsh\node_modules') }
$harnessCandidates += (Join-Path $env:APPDATA 'npm\node_modules\@deepseek-ai\dsh\node_modules')
# 兜底：从当前用户 roaming 目录推导（不绑定具体用户名）
if ($env:APPDATA) {
    $harnessCandidates += (Join-Path (Split-Path $env:APPDATA -Parent) 'Roaming\npm\node_modules\@deepseek-ai\dsh\node_modules')
}

$harnessMap = @{}
$harnessVersion = 'unknown'
$harnessDir = $null
foreach ($hc in $harnessCandidates) {
    $aiDir = Join-Path $hc '@deepseek-ai'
    if (-not (Test-Path $aiDir)) { continue }
    foreach ($sub in (Get-ChildItem $aiDir -Directory -ErrorAction SilentlyContinue)) {
        $pj = Join-Path $sub.FullName 'package.json'
        if (Test-Path $pj) {
            $j = Get-Content $pj -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($j -and $j.version) { $harnessMap["@deepseek-ai/$($sub.Name)"] = $j.version }
        }
    }
    foreach ($sub in (Get-ChildItem $hc -Directory -ErrorAction SilentlyContinue)) {
        if (-not $harnessMap.ContainsKey($sub.Name)) {
            $pj = Join-Path $sub.FullName 'package.json'
            if (Test-Path $pj) {
                $j = Get-Content $pj -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($j -and $j.version) { $harnessMap[$sub.Name] = $j.version }
            }
        }
    }
    if ($harnessMap.Count -gt 0) {
        $harnessDir = $hc
        $dshPj = Join-Path (Split-Path $hc -Parent) 'package.json'
        if (Test-Path $dshPj) {
            $j = Get-Content $dshPj -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($j -and $j.version) { $harnessVersion = $j.version }
        }
        break
    }
}
if ($harnessMap.Count -eq 0) {
    Write-Host 'Cannot locate the global DeepSeek Harness install (@deepseek-ai/dsh).' -ForegroundColor Red
    exit 2
}

$nodeVer = 'unknown'
try {
    $nv = (Get-Command node.exe).Version
    $nodeVer = "$($nv.Major).$($nv.Minor).$($nv.Build)"
} catch { }

Write-Host ("DeepSeek Harness : {0}" -f $harnessVersion) -ForegroundColor Cyan
Write-Host ("Harness location : {0}" -f (Split-Path $harnessDir -Parent)) -ForegroundColor Cyan
Write-Host ("Node             : {0}" -f $nodeVer) -ForegroundColor Cyan
Write-Host ''

# --- targets ---
$profilePkg = $null
if (Test-Path (Join-Path $Profile 'package.json')) {
    $profilePkg = Get-Content (Join-Path $Profile 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
}
$profileNodeModules = Join-Path $Profile 'node_modules'

# also index harness-provided @deepseek-ai/* packages hoisted in the profile
foreach ($sub in (Get-ChildItem (Join-Path $profileNodeModules '@deepseek-ai') -Directory -ErrorAction SilentlyContinue)) {
    if (-not $harnessMap.ContainsKey("@deepseek-ai/$($sub.Name)")) {
        $pj = Join-Path $sub.FullName 'package.json'
        if (Test-Path $pj) {
            $j = Get-Content $pj -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($j -and $j.version) { $harnessMap["@deepseek-ai/$($sub.Name)"] = $j.version }
        }
    }
}

$targets = @()
if ($Specs) {
    foreach ($item in ($Specs -split ',')) {
        $item = $item.Trim()
        if (-not $item) { continue }
        $targets += , $item
    }
}
elseif ($profilePkg -and $profilePkg.dependencies) {
    foreach ($prop in $profilePkg.dependencies.PSObject.Properties) {
        $targets += , @{ Name = $prop.Name; Version = $null }
    }
}
if ($targets.Count -eq 0) {
    Write-Host 'Nothing to check: pass -Specs, or point -Profile at a profile with dependencies.' -ForegroundColor Yellow
    exit 2
}

$allBlockers = 0
$allReviews = 0
$allUnknown = 0

foreach ($t in $targets) {
    if ($t -is [string]) {
        $idx = $t.LastIndexOf('@')
        if ($idx -le 0) { $name = $t; $ver = $null }
        else {
            $name = $t.Substring(0, $idx)
            $ver = $t.Substring($idx + 1)
            if (-not $ver) { $ver = $null }
        }
    }
    else { $name = $t.Name; $ver = $t.Version }
    if (-not $name) { continue }

    # installed version from the profile node_modules
    $installedVersion = $null
    $installedPj = Join-Path $profileNodeModules ($name -replace '/', '\')
    if (Test-Path (Join-Path $installedPj 'package.json')) {
        $ij = Get-Content (Join-Path $installedPj 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($ij) { $installedVersion = $ij.version }
    }
    $displayVersion = if ($ver) { $ver } else { $installedVersion }
    if (-not $displayVersion) { $displayVersion = 'unknown' }

    # fetch manifest: on-disk (installed, wins) -> cache -> live npm spawns
    $manifest = $null
    $spec = if ($ver) { "$name@$ver" } else { $name }
    $onDiskPj = Join-Path $installedPj 'package.json'
    if (Test-Path $onDiskPj) {
        $diskManifest = Get-Content $onDiskPj -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($diskManifest) {
            $raw = [PSCustomObject]@{ peerDependencies = $diskManifest.peerDependencies; engines = $diskManifest.engines }
            # the real installed manifest wins whenever it matches the requested version
            if ($null -eq $ver -or $ver -eq $diskManifest.version) { $manifest = $raw }
        }
    }
    $cacheKey = ($spec -replace '[^A-Za-z0-9@._-]', '_') + '.json'
    $manifestFile = Join-Path (Join-Path $CacheDir 'manifest') $cacheKey
    if ($null -eq $manifest -and (Test-Path $manifestFile)) {
        $cached = Get-Content $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction SilentlyContinue
        $cacheVersionOk = if ($ver) { $cached.version -eq $ver } else { $null -eq $cached.version -or $cached.version -eq $installedVersion }
        if ($cached -and $cached.name -eq $name -and $cacheVersionOk) {
            $manifest = $cached.raw
        }
    }
    for ($attempt = 1; $attempt -le 3 -and $null -eq $manifest; $attempt++) {
        $tmp = Join-Path $CacheDir ("manifest-$([guid]::NewGuid().ToString('N')).json")
        & cmd /c "npm.cmd view $spec peerDependencies engines --json --cache $CacheDir > `"$tmp`" 2>nul"
        if ($LASTEXITCODE -eq 0 -and (Test-Path $tmp)) {
            $manifest = Get-Content $tmp -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction SilentlyContinue
        }
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
    if ($null -eq $manifest) {
        # fallback vector: invoke npm's CLI directly through node (no batch shim)
        $nodeDir2 = Split-Path (Get-Command node.exe).Source -Parent
        $npmCli = Join-Path $nodeDir2 'node_modules\npm\bin\npm-cli.js'
        if (Test-Path $npmCli) {
            for ($attempt = 1; $attempt -le 2 -and $null -eq $manifest; $attempt++) {
                $tmp = Join-Path $CacheDir ("manifest-$([guid]::NewGuid().ToString('N')).json")
                & cmd /c "node `"$npmCli`" view $spec peerDependencies engines --json --cache $CacheDir > `"$tmp`" 2>&1"
                if ($LASTEXITCODE -eq 0 -and (Test-Path $tmp)) {
                    $manifest = Get-Content $tmp -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction SilentlyContinue
                }
                if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
            }
        }
    }
    if ($null -ne $manifest) {
        # persist a normalized cache entry so later runs are spawn-free;
        # store the RESOLVED version so a later default-mode run can reject stale entries
        $cacheDir2 = Join-Path $CacheDir 'manifest'
        if (-not (Test-Path $cacheDir2)) { New-Item -ItemType Directory -Force -Path $cacheDir2 | Out-Null }
        $resolvedVer = if ($ver) { $ver } else { $installedVersion }
        $entry = [PSCustomObject]@{ name = $name; version = $resolvedVer; raw = $manifest }
        $entry | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestFile -Encoding UTF8
    }

    $checks = @()
    if (-not $manifest) {
        $checks += [PSCustomObject]@{ Peer = '(manifest)'; Harness = ''; Range = ''; Result = 'cannot fetch npm metadata (network/cache?)' }
    }
    else {
        # normalize npm view output shape (peers may be unwrapped when engines is absent)
        $peers = $null
        $hasPeersKey = $false
        $hasEnginesKey = $false
        foreach ($p in $manifest.PSObject.Properties) {
            if ($p.Name -eq 'peerDependencies') { $hasPeersKey = $true }
            if ($p.Name -eq 'engines') { $hasEnginesKey = $true }
        }
        if ($hasPeersKey) { $peers = $manifest.peerDependencies }
        elseif (-not $hasEnginesKey) { $peers = $manifest }
        $engines = $manifest.engines

        if ($peers) {
            foreach ($peer in ($peers.PSObject.Properties | Sort-Object Name)) {
                $pName = $peer.Name
                $pRange = $peer.Value
                if ($harnessMap.ContainsKey($pName)) {
                    $hv = $harnessMap[$pName]
                    $w = Test-VersionRange -Range $pRange -Version $hv -Strict $false
                    $s = Test-VersionRange -Range $pRange -Version $hv -Strict $true
                    if ($null -eq $w) {
                        $checks += [PSCustomObject]@{ Peer = $pName; Harness = $hv; Range = $pRange; Result = 'UNKNOWN (range parse failed)' }
                    }
                    elseif ($w) {
                        $note = if ($s) { 'OK' } else { 'OK (numeric window ok; strict semver says no - usually works at runtime, verify if unsure)' }
                        $checks += [PSCustomObject]@{ Peer = $pName; Harness = $hv; Range = $pRange; Result = $note }
                    }
                    else {
                        $checks += [PSCustomObject]@{ Peer = $pName; Harness = $hv; Range = $pRange; Result = "FAIL (harness provides $hv, outside range $pRange)" }
                    }
                }
                else {
                    if ($pName -like '@deepseek-ai/*') {
                        # harness-scoped peer the installed harness does not ship as a module;
                        # the host often injects such client packages at runtime, so this is a
                        # soft signal (newer-harness marker), not a hard failure
                        $checks += [PSCustomObject]@{ Peer = $pName; Harness = '(absent)'; Range = $pRange; Result = "WARN (harness $harnessVersion does not ship $pName - the host may inject it at runtime; verify manually)" }
                    }
                    else {
                        $local = $profilePkg.dependencies
                        $inProfile = $false
                        if ($local -and $local.PSObject.Properties[$pName]) { $inProfile = $true }
                        $result = if ($inProfile) { 'OK (declared in profile)' } else { 'WARN (not a harness package, not in profile deps - confirm the runtime provides it)' }
                        $checks += [PSCustomObject]@{ Peer = $pName; Harness = '(external)'; Range = $pRange; Result = $result }
                    }
                }
            }
        }
        if ($engines -and $engines.node) {
            $t2 = Test-VersionRange -Range $engines.node -Version $nodeVer -Strict $false
            $r = if ($null -eq $t2) { 'UNKNOWN (range parse failed)' } elseif ($t2) { 'OK' } else { "FAIL (needs node $($engines.node), current $nodeVer)" }
            $checks += [PSCustomObject]@{ Peer = 'engines.node'; Harness = $nodeVer; Range = $engines.node; Result = $r }
        }
    }

    $failed = @($checks | Where-Object { $_.Result -like 'FAIL*' })
    $unknown = @($checks | Where-Object { $_.Result -like 'UNKNOWN*' -or $_.Result -like 'WARN*' })
    $unverified = @($checks | Where-Object { $_.Peer -eq '(manifest)' })
    if ($failed.Count -gt 0) { $verdict = 'INCOMPATIBLE'; $allBlockers++ }
    elseif ($unverified.Count -gt 0) { $verdict = 'UNKNOWN'; $allUnknown++ }
    elseif ($unknown.Count -gt 0) { $verdict = 'REVIEW'; $allReviews++ }
    else { $verdict = 'OK' }

    $color = switch ($verdict) { 'OK' { 'Green' } 'INCOMPATIBLE' { 'Red' } 'REVIEW' { 'Yellow' } default { 'Gray' } }
    Write-Host ("[{0}] {1}@{2}" -f $verdict, $name, $displayVersion) -ForegroundColor $color
    if ($installedVersion -and $installedVersion -ne $displayVersion) {
        Write-Host ("      installed: {0}" -f $installedVersion) -ForegroundColor DarkGray
    }
    foreach ($c in $checks) {
        $cc = switch -Wildcard ($c.Result) { 'OK*' { 'DarkGreen' } 'FAIL*' { 'Red' } 'WARN*' { 'Yellow' } 'UNKNOWN*' { 'Magenta' } default { 'Gray' } }
        Write-Host ("      {0,-44} {1,-16} {2,-30} {3}" -f $c.Peer, $c.Harness, $c.Range, $c.Result) -ForegroundColor $cc
    }
    Write-Host ''
}

if ($allBlockers -gt 0) {
    Write-Host ("Pre-check FAILED: {0} candidate(s) incompatible with the current Harness - do NOT update." -f $allBlockers) -ForegroundColor Red
    exit 1
}
if ($allUnknown -gt 0) {
    Write-Host ("COULD NOT VERIFY: {0} candidate(s) - npm metadata unavailable (network/cache?). Re-run later or fix the network; do NOT update unverified plugins." -f $allUnknown) -ForegroundColor Magenta
    exit 3
}
if ($allReviews -gt 0) {
    Write-Host ("Pre-check passed but {0} candidate(s) need manual review (WARN/UNKNOWN items)." -f $allReviews) -ForegroundColor Yellow
    exit 0
}
Write-Host 'Pre-check passed - safe to update.' -ForegroundColor Green
exit 0
