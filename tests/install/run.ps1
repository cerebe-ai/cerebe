# Offline tests of the real installer. Only transport, verifier decisions and
# system architecture inputs are fixtures; extraction and installed processes run.
param([ValidateSet('All', 'EC1', 'EC2', 'EC3', 'EC4', 'EC5', 'EC14', 'EC15')][string]$Criterion = 'All')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot/../..").Path
$shell = (Get-Process -Id $PID).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ('cerebe-test-' + [guid]::NewGuid())
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$source = Get-Content "$root/install.ps1" -Raw
$reachedRefusals = @{}
$posix = Get-Content "$root/install.sh" -Raw
$identity = @{}
foreach ($name in @('CERT_IDENTITY', 'CERT_ISSUER', 'PROVENANCE_SOURCE', 'PROVENANCE_BRANCH', 'PROVENANCE_BUILDER')) {
    $match = [regex]::Match($posix, "(?m)^$name='([^']+)'$")
    if (!$match.Success) { throw "missing POSIX identity $name" }
    $identity[$name] = $match.Groups[1].Value
}
New-Item -ItemType Directory -Path "$work/base", "$work/path-tools" -Force | Out-Null
$driver = @'
param($CaseFile)
$ErrorActionPreference = 'Stop'
# Load exported functions before wrapping them; auto-import would replace the wrapper.
Import-Module Microsoft.PowerShell.Archive
$case = Get-Content -LiteralPath $CaseFile -Raw | ConvertFrom-Json
foreach ($item in $case.Env.PSObject.Properties) { [Environment]::SetEnvironmentVariable($item.Name, $item.Value, 'Process') }
function Invoke-WebRequest($Uri, $OutFile, $Headers, [switch]$UseBasicParsing) {
    Add-Content -LiteralPath ($case.Directory + '/downloads') -Value $Uri
    if ($Uri -like 'https://api.github.com/*') { $file = $case.Directory + '/release.json' }
    else { $file = $case.Directory + '/assets/' + ([uri]$Uri).Segments[-1] }
    Copy-Item -LiteralPath $file -Destination $OutFile
}
function Expand-Archive($LiteralPath, $DestinationPath) {
    Add-Content -LiteralPath ($case.Directory + '/extracts') -Value $LiteralPath
    Microsoft.PowerShell.Archive\Expand-Archive -LiteralPath $LiteralPath -DestinationPath $DestinationPath
}
Set-Location -LiteralPath $case.Cwd
try { . $case.Installer } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
'@
Set-Content "$work/driver.ps1" $driver -Encoding ASCII
function Hash($Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Json($Path, $Value) { $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding ASCII }
function Assert($Condition, $Message) { if (!$Condition) { throw $Message } }
function Write-Proof($Assets) {
    $hashes = @{}
    $sums = foreach ($zip in Get-ChildItem -LiteralPath $Assets -Filter '*.zip') {
        $hashes[$zip.Name] = Hash $zip.FullName
        $hashes[$zip.Name] + '  ' + $zip.Name
    }
    Set-Content "$Assets/checksums.txt" $sums -Encoding ASCII
    Json "$Assets/checksums.txt.sigstore.json" @{
        Sum = (Hash "$Assets/checksums.txt"); Identity = $identity.CERT_IDENTITY; Issuer = $identity.CERT_ISSUER
    }
    Json "$Assets/cerebe-cyclone.intoto.jsonl" @{
        Source = $identity.PROVENANCE_SOURCE; Branch = $identity.PROVENANCE_BRANCH
        Builder = $identity.PROVENANCE_BUILDER; Hashes = $hashes
    }
}
function Execute($Case) {
    $ErrorActionPreference = 'Continue'
    & $shell -NoProfile -ExecutionPolicy Bypass -File "$work/driver.ps1" "$($Case.Directory)/case.json" *> "$($Case.Directory)/out"
    $Case.Code = $LASTEXITCODE
    $Case.Output = Get-Content -LiteralPath "$($Case.Directory)/out" -Raw
    return $Case
}
function Case($Name, $Environment = @{}, $Edit = {}, $Rewrite = {}) {
    $dir = Join-Path $work $Name
    New-Item -ItemType Directory -Path "$dir/assets", "$dir/cwd" -Force | Out-Null
    Copy-Item "$work/base/*" "$dir/assets"
    $release = Get-Content "$PSScriptRoot/release-v8.17.1.json" -Raw | ConvertFrom-Json
    foreach ($name in @('checksums.txt.sigstore.json', 'cerebe-cyclone.intoto.jsonl')) {
        $release.assets += [pscustomobject]@{ browser_download_url = "https://github.com/example-owner/renamed-repo/releases/download/v8.17.1/$name" }
    }
    Json "$dir/release.json" $release
    $envs = @{
        PATH = "$work/path-tools;$env:PATH"; CI = ''; CEREBE_SKIP_REPO = ''
        CEREBE_INSTALL_DIR = "$dir/install"; LOCALAPPDATA = "$dir/local"
        CEREBE_VERSION = '8.17.1'; CEREBE_RELEASE_JSON = "$dir/release.json"
        STUB_LOG = "$dir/tools"; STUB_REJECT_PATH = ''; STUB_REJECT_PINNED = ''; STUB_DOCTOR_FAIL = ''
        STUB_FAIL_COMMAND = ''; PROCESSOR_ARCHITECTURE = 'AMD64'; PROCESSOR_ARCHITEW6432 = 'AMD64'
    }
    foreach ($key in $Environment.Keys) { $envs[$key] = $Environment[$key] }
    $script = $source -replace "(?m)(\`$(?:COSIGN|SLSA_AMD64|SLSA_ARM64)_SHA256 = )'[a-f0-9]+'", ('$1' + "'$fixtureHash'")
    $script = & $Rewrite $script
    if (!$script) { $script = $source -replace "(?m)(\`$(?:COSIGN|SLSA_AMD64|SLSA_ARM64)_SHA256 = )'[a-f0-9]+'", ('$1' + "'$fixtureHash'") }
    Set-Content "$dir/installer.ps1" $script -Encoding ASCII
    $case = [pscustomobject]@{ Directory = $dir; Cwd = "$dir/cwd"; Installer = "$dir/installer.ps1"; Env = $envs; Code = 0; Output = '' }
    & $Edit $case
    Json "$dir/case.json" $case
    return (Execute $case)
}
function Installed($Case) {
    Assert ($Case.Code -eq 0) $Case.Output
    $dir = if ($Case.Env.CEREBE_INSTALL_DIR) { $Case.Env.CEREBE_INSTALL_DIR } else { "$($Case.Env.LOCALAPPDATA)/Programs/Cerebe" }
    foreach ($bin in @('cerebe', 'cyclone')) {
        $actual = & "$dir/$bin.exe" --version
        Assert ($LASTEXITCODE -eq 0 -and $actual -eq "$bin v8.17.1") "wrong installed $bin version"
    }
}
function Refusal-Message($Case, $Identifier) {
    Assert ($Case.Code -ne 0) 'expected a failed installer process'
    $message = [regex]::Match($Case.Output, '(?m)^cerebe-install: \[([a-z0-9-]+)\] (\S[^\r\n]*?)\. Next step: (\S[^\r\n]*)\r?$')
    Assert $message.Success ("refusal must name the failed check and a next step: " + $Case.Output)
    Assert ($message.Groups[1].Value -ceq $Identifier) ("expected refusal $Identifier : " + $Case.Output)
    $reachedRefusals[$Identifier] = $true
}
function Refused($Case, $Identifier) {
    Refusal-Message $Case $Identifier
    Assert (!(Test-Path "$($Case.Directory)/install")) 'refusal wrote the install directory'
    Assert (!(Test-Path "$($Case.Directory)/extracts")) 'refusal extracted an archive'
}
function Refusal-Coverage($Script) {
    # Tripwire against an accidentally untested deliberate refusal. Operational
    # exceptions share the tested fallback; this is not an adversarial detector.
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Script, [ref]$tokens, [ref]$errors)
    Assert ($errors.Count -eq 0) 'installer does not parse'
    $calls = @($ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Refuse'
    }, $true))
    Assert ($calls.Count -gt 0) 'installer declares no refusal identifiers'
    foreach ($call in $calls) {
        Assert ($call.CommandElements[1] -is [Management.Automation.Language.StringConstantExpressionAst]) 'refusal identifiers must be literal'
        $id = $call.CommandElements[1].Value
        Assert ($reachedRefusals.ContainsKey($id)) "refusal identifier has no reached case: $id"
    }
    foreach ($statement in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.ThrowStatementAst] }, $true)) {
        if (!$statement.Pipeline) { continue } # A bare throw rethrows a named refusal.
        $parent = $statement.Parent
        while ($parent -and $parent -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $parent = $parent.Parent }
        Assert ($parent -and $parent.Name -eq 'Refuse') 'a deliberate refusal bypasses its identifier'
    }
}
function Must-Fail($Check, $Reason) {
    $failed = $false
    try { & $Check } catch { $failed = $true; Assert ($_.Exception.Message.Contains($Reason)) $_.Exception.Message }
    Assert $failed "negative control did not fail: $Reason"
}
function EC1 {
    $good = Case 'verified'; Installed $good
    Assert ((Get-Content "$($good.Directory)/extracts").Count -eq 2) 'both archives must extract'
    foreach ($field in @('Identity', 'Issuer', 'Source', 'Branch', 'Builder', 'Sum', 'Hash')) {
        $case = Case "bad-$field" @{ CEREBE_SKIP_VERIFY = '1' } {
            param($c)
            $file = if ($field -in @('Identity', 'Issuer', 'Sum')) { 'checksums.txt.sigstore.json' } else { 'cerebe-cyclone.intoto.jsonl' }
            $proof = Get-Content "$($c.Directory)/assets/$file" -Raw | ConvertFrom-Json
            if ($field -eq 'Hash') { foreach ($entry in $proof.Hashes.PSObject.Properties) { $entry.Value = 'wrong' } } else { $proof.$field = 'wrong' }
            Json "$($c.Directory)/assets/$file" $proof
        }
        $reason = if ($field -in @('Identity', 'Issuer', 'Sum')) { 'checksum-signature' } else { 'provenance' }
        Refused $case $reason
    }
    foreach ($file in @('checksums.txt.sigstore.json', 'cerebe-cyclone.intoto.jsonl')) {
        Refused (Case "missing-$file" @{} { param($c); Remove-Item "$($c.Directory)/assets/$file" }) 'download'
    }
    Refused (Case 'tampered-checksums' @{} { param($c); Add-Content "$($c.Directory)/assets/checksums.txt" 'tampered' }) 'checksum-signature'
    Refused (Case 'archive-hash' @{} {
        param($c)
        $assets = "$($c.Directory)/assets"
        $lines = Get-Content "$assets/checksums.txt"
        Get-ChildItem $assets -Filter '*.zip' | ForEach-Object { Add-Content $_.FullName 'tampered' }
        Write-Proof $assets
        Set-Content "$assets/checksums.txt" $lines -Encoding ASCII
        $bundle = Get-Content "$assets/checksums.txt.sigstore.json" -Raw | ConvertFrom-Json
        $bundle.Sum = Hash "$assets/checksums.txt"; Json "$assets/checksums.txt.sigstore.json" $bundle
    }) 'archive-checksum'
    Write-Host 'EC1 passed: accepted release and every refusal before extraction'
}
function EC2 {
    $retry = Case 'path-rejects' @{ STUB_REJECT_PATH = 'both' }; Installed $retry
    foreach ($tool in @('cosign', 'slsa-verifier')) {
        $calls = @(Get-Content "$($retry.Directory)/tools" | Where-Object { $_.StartsWith("$tool ") })
        Assert ($calls.Count -eq 2) "$tool did not retry with its pinned build"
        $reason = if ($tool -eq 'cosign') { 'checksum-signature' } else { 'provenance' }
        Refused (Case "pinned-rejects-$tool" @{ STUB_REJECT_PATH = $tool; STUB_REJECT_PINNED = $tool }) $reason
        $case = Case "corrupt-$tool" @{ STUB_REJECT_PATH = $tool } {
            param($c)
            Get-ChildItem "$($c.Directory)/assets" -Filter "$tool-windows-*.exe" | ForEach-Object { Add-Content $_.FullName 'corrupt' }
        }
        Refused $case 'verifier-checksum'
        Assert (@(Get-Content "$($case.Directory)/tools" | Where-Object { $_.StartsWith("$tool ") }).Count -eq 1) 'corrupt downloaded tool ran'
    }
    Write-Host 'EC2 passed: pinned retries and corrupt tools never run'
}
function EC3 {
    $case = Case 'user-path' @{ CEREBE_INSTALL_DIR = ''; CEREBE_SKIP_REPO = '1' }
    Installed $case; Installed (Execute $case)
    $dir = [IO.Path]::GetFullPath("$($case.Env.LOCALAPPDATA)/Programs/Cerebe")
    $entries = [Environment]::GetEnvironmentVariable('Path', 'User') -split ';'
    Assert (@($entries | Where-Object { $_ -ieq $dir }).Count -eq 1) 'user PATH entry duplicated or absent'
    Assert ([Environment]::GetEnvironmentVariable('Path', 'Machine') -ceq $machinePath) 'machine PATH changed'
    $old = $env:PATH
    try {
        # Rebuild the environment a new login receives; do not inherit the installer's process PATH.
        $env:PATH = $machinePath + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
        foreach ($probe in @('cmd', 'powershell', 'pwsh')) {
            $output = if ($probe -eq 'cmd') { & cmd /d /c 'cerebe --version && cyclone --version' } else {
                & $probe -NoProfile -Command 'cerebe --version; cyclone --version'
            }
            Assert ($LASTEXITCODE -eq 0 -and ($output -join ';') -eq 'cerebe v8.17.1;cyclone v8.17.1') "new $probe session failed"
        }
    } finally { $env:PATH = $old }
    Write-Host 'EC3 passed: per-user default, repeated PATH update, fresh cmd/PowerShell sessions'
}
function EC4 {
    foreach ($mode in @('install', 'init', 'doctor-blocks', 'outside', 'CI', 'CEREBE_SKIP_REPO', 'CEREBE_INSTALL_DIR')) {
        $envs = @{ CEREBE_INSTALL_DIR = '' }
        if ($mode -eq 'CI' -or $mode -eq 'CEREBE_SKIP_REPO') { $envs[$mode] = '1' }
        if ($mode -eq 'doctor-blocks') { $envs.STUB_DOCTOR_FAIL = '1' }
        $case = Case "repo-$mode" $envs {
            param($c)
            if ($mode -ne 'outside') { & git -C $c.Cwd init -q; Assert ($LASTEXITCODE -eq 0) 'git fixture failed' }
            if ($mode -eq 'init') { New-Item -ItemType Directory "$($c.Cwd)/cerebe" | Out-Null; Set-Content "$($c.Cwd)/cerebe/config.json" '{}' }
            if ($mode -eq 'CEREBE_INSTALL_DIR') { $c.Env.CEREBE_INSTALL_DIR = "$($c.Directory)/install" }
        }
        $calls = @(Get-Content "$($case.Directory)/tools" | Where-Object { $_ -match '^cerebe (install|init|doctor)$' })
        $expected = if ($mode -eq 'init') { @('cerebe init', 'cerebe doctor') } elseif ($mode -in @('install', 'doctor-blocks')) { @('cerebe install', 'cerebe doctor') } else { @() }
        Assert (($calls -join ';') -eq ($expected -join ';')) "wrong setup dispatch for $mode"
        Assert (($case.Code -ne 0) -eq ($mode -eq 'doctor-blocks')) "wrong doctor status for $mode"
        if ($mode -eq 'doctor-blocks') { Refusal-Message $case 'repository-doctor' }
        # POSIX oracle exercises the shipped install.sh under the same inputs.
        & "$PSScriptRoot/repo-parity.ps1" $case $mode $expected ($case.Code -ne 0)
    }
    Write-Host 'EC4 passed: repository dispatch and doctor status equal install.sh'
}
function EC5 {
    $api = Case 'latest' @{ CEREBE_VERSION = ''; CEREBE_RELEASE_JSON = '' }; Installed $api
    Assert ((Get-Content "$($api.Directory)/downloads")[0] -eq 'https://api.github.com/repositories/1181720228/releases/latest') 'wrong latest endpoint'
    Installed (Case 'v-prefix' @{ CEREBE_VERSION = 'v8.17.1' })
    $cached = Case 'cached'; Installed $cached
    Assert (!(Get-Content "$($cached.Directory)/downloads" -Raw).Contains('api.github.com')) 'cached release made API call'
    foreach ($pin in @('v', '../8.17.1', '8.17.1?query', '8.17.1 space')) { Refused (Case ('invalid-' + [guid]::NewGuid()) @{ CEREBE_VERSION = $pin }) 'release-version-pin' }
    Refused (Case 'json-without-pin' @{ CEREBE_VERSION = '' }) 'cached-release-pin'
    Refused (Case 'wrong-tag' @{ CEREBE_VERSION = '0.0.0' }) 'release-pin-match'
    Write-Host 'EC5 passed: override behavior, pins and cached release validation'
}
function EC14 {
    foreach ($arch in @('amd64', 'arm64')) {
        # Also model an x64 process running on a native ARM64 machine.
        $native = if ($arch -eq 'arm64') { 'ARM64' } else { 'AMD64' }
        $case = Case "architecture-$arch" @{ PROCESSOR_ARCHITEW6432 = $native; STUB_REJECT_PATH = 'both' } {} {
            param($s); $s -replace '\$windowsBuild = \[Environment\]::OSVersion.Version.Build', '$windowsBuild = 22000'
        }
        Installed $case
        $requests = @(Get-Content "$($case.Directory)/downloads")
        $tools = @($requests | Where-Object { $_ -match '/(?:cosign|slsa-verifier)-windows-.*\.exe$' })
        $expected = @(
            'https://github.com/sigstore/cosign/releases/download/v3.0.6/cosign-windows-amd64.exe',
            "https://github.com/slsa-framework/slsa-verifier/releases/download/v2.7.1/slsa-verifier-windows-$arch.exe"
        )
        Assert (($tools -join ';') -ceq ($expected -join ';')) "wrong $arch verifier builds"
        $archives = @('cerebe', 'cyclone' | ForEach-Object { "${_}_8.17.1_windows_$arch.zip" })
        $downloads = @($requests | Where-Object { $_.EndsWith('.zip') } | ForEach-Object { ([uri]$_).Segments[-1] })
        Assert (($downloads -join ';') -ceq ($archives -join ';')) "wrong $arch archive downloads"
        Assert (((Get-Content "$($case.Directory)/extracts") -join ';') -ceq ($archives -join ';')) "wrong $arch archive extraction"
    }
    Refused (Case 'no-emulation' @{ PROCESSOR_ARCHITECTURE = 'ARM64'; PROCESSOR_ARCHITEW6432 = 'ARM64' } {} {
        param($s); $s -replace '\$windowsBuild = \[Environment\]::OSVersion.Version.Build', '$windowsBuild = 19045'
    }) 'windows-arm64-emulation'
    Write-Host 'EC14 passed: x64 and ARM64 archives and verifier builds; no install without emulation'
}
function EC15 {
    Refused (Case 'not-windows' @{} {} {
        param($s); $s.Replace('[Environment]::OSVersion.Platform', '[PlatformID]::Unix')
    }) 'windows-platform'
    Refused (Case 'unsupported-architecture' @{ PROCESSOR_ARCHITEW6432 = 'x86' }) 'windows-architecture'
    Refused (Case 'cosign-cannot-emulate' @{ PROCESSOR_ARCHITEW6432 = 'ARM64'; STUB_REJECT_PATH = 'cosign'; STUB_REJECT_PINNED = 'cosign' } {} {
        param($s); $s -replace '\$windowsBuild = \[Environment\]::OSVersion.Version.Build', '$windowsBuild = 22000'
    }) 'cosign-emulation'
    Refused (Case 'missing-release-tag' @{} {
        param($c); $r = Get-Content "$($c.Directory)/release.json" -Raw | ConvertFrom-Json
        $r.tag_name = ''; Json "$($c.Directory)/release.json" $r
    }) 'release-tag'
    Refused (Case 'invalid-release-tag' @{ CEREBE_VERSION = ''; CEREBE_RELEASE_JSON = '' } {
        param($c); $r = Get-Content "$($c.Directory)/release.json" -Raw | ConvertFrom-Json
        $r.tag_name = 'v../bad'; Json "$($c.Directory)/release.json" $r
    }) 'release-version'
    foreach ($duplicate in @($false, $true)) {
        Refused (Case "release-asset-$duplicate" @{} {
            param($c); $r = Get-Content "$($c.Directory)/release.json" -Raw | ConvertFrom-Json
            $asset = @($r.assets | Where-Object { $_.browser_download_url.EndsWith('/checksums.txt') })[0]
            if ($duplicate) { $r.assets += $asset } else { $r.assets = @($r.assets | Where-Object { $_ -ne $asset }) }
            Json "$($c.Directory)/release.json" $r
        }) 'release-asset'
    }
    foreach ($file in @('checksums.txt.sigstore.json', 'cerebe-cyclone.intoto.jsonl')) {
        $id = if ($file -eq 'checksums.txt.sigstore.json') { 'checksum-bundle' } else { 'provenance-file' }
        Refused (Case "empty-$file" @{} { param($c); Clear-Content "$($c.Directory)/assets/$file" }) $id
    }
    foreach ($duplicate in @($false, $true)) {
        Refused (Case "checksum-entry-$duplicate" @{} {
            param($c); $assets = "$($c.Directory)/assets"
            $lines = @(Get-Content "$assets/checksums.txt")
            $target = @($lines | Where-Object { $_.EndsWith('  cerebe_8.17.1_windows_amd64.zip') })[0]
            $lines = if ($duplicate) { $lines + $target } else { @($lines | Where-Object { $_ -ne $target }) }
            Set-Content "$assets/checksums.txt" $lines -Encoding ASCII
            $bundle = Get-Content "$assets/checksums.txt.sigstore.json" -Raw | ConvertFrom-Json
            $bundle.Sum = Hash "$assets/checksums.txt"; Json "$assets/checksums.txt.sigstore.json" $bundle
        }) 'archive-checksum-entry'
    }
    $missing = Case 'archive-without-binary' @{} {
        param($c); $assets = "$($c.Directory)/assets"
        Set-Content "$($c.Directory)/README.txt" 'missing executable'
        foreach ($zip in Get-ChildItem $assets -Filter 'cerebe_*.zip') {
            Remove-Item $zip.FullName; Compress-Archive "$($c.Directory)/README.txt" $zip.FullName
        }
        Write-Proof $assets
    }
    Refusal-Message $missing 'archive-binary'
    Assert (!(Test-Path "$($missing.Directory)/install")) 'missing executable wrote install directory'
    Refusal-Message (Case 'installed-command-fails' @{ STUB_FAIL_COMMAND = '--version' }) 'installed-binary'
    Refusal-Message (Case 'setup-command-fails' @{ CEREBE_INSTALL_DIR = ''; STUB_FAIL_COMMAND = 'install' } {
        param($c); & git -C $c.Cwd init -q; Assert ($LASTEXITCODE -eq 0) 'git fixture failed'
    }) 'repository-setup'
    Refused (Case 'unreadable-release-json' @{ CEREBE_RELEASE_JSON = "$work/absent.json" }) 'installer-operation'
    Refusal-Coverage $source

    # Each control executes the real installer and then must fail the same
    # message assertion used above. The first reproduces the base's omission.
    $legacy = Case 'legacy-refusal' @{ CEREBE_VERSION = '../bad' } {} {
        param($s); $s.Replace('cerebe-install: [$Check] $Failure. Next step: $NextStep', 'cerebe-install: $Failure')
    }
    Must-Fail { Refusal-Message $legacy 'release-version-pin' } 'refusal must name the failed check and a next step'
    $noNextStep = Case 'refusal-without-next-step' @{ CEREBE_VERSION = '../bad' } {} {
        param($s); $s.Replace('. Next step: $NextStep', '')
    }
    Must-Fail { Refusal-Message $noNextStep 'release-version-pin' } 'refusal must name the failed check and a next step'
    $noCheck = Case 'refusal-without-check' @{ CEREBE_VERSION = '../bad' } {} {
        param($s); $s.Replace('$Failure. Next step:', '. Next step:')
    }
    Must-Fail { Refusal-Message $noCheck 'release-version-pin' } 'refusal must name the failed check and a next step'
    Must-Fail { Refusal-Coverage ($source + "`nif (`$false) { Refuse 'uncovered-check' 'Unexercised check failed' 'Retry' }") } 'refusal identifier has no reached case: uncovered-check'
    Write-Host 'EC15 passed: every declared refusal reached, named check and next step; missing text and coverage controls fail'
}
try {
    & go build -o "$work/fixture.exe" "$PSScriptRoot/fixture.go"
    Assert ($LASTEXITCODE -eq 0) 'fixture build failed'
    $fixtureHash = Hash "$work/fixture.exe"
    foreach ($tool in @('cosign', 'slsa-verifier')) {
        Copy-Item "$work/fixture.exe" "$work/path-tools/$tool.exe"
        foreach ($arch in @('amd64', 'arm64')) { Copy-Item "$work/fixture.exe" "$work/base/$tool-windows-$arch.exe" }
    }
    foreach ($bin in @('cerebe', 'cyclone')) {
        Copy-Item "$work/fixture.exe" "$work/$bin.exe"
        foreach ($arch in @('amd64', 'arm64')) { Compress-Archive -LiteralPath "$work/$bin.exe" -DestinationPath "$work/base/${bin}_8.17.1_windows_$arch.zip" }
    }
    Write-Proof "$work/base"
    $criteria = if ($Criterion -eq 'All') { @('EC1', 'EC2', 'EC3', 'EC4', 'EC5', 'EC14', 'EC15') }
        elseif ($Criterion -eq 'EC15') { @('EC1', 'EC2', 'EC4', 'EC5', 'EC14', 'EC15') } else { @($Criterion) }
    foreach ($test in $criteria) { & (Get-Item "function:$test") }
} finally {
    [Environment]::SetEnvironmentVariable('Path', $userPath, 'User')
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
# Expected native refusals must not become GitHub's final shell exit status.
exit 0
