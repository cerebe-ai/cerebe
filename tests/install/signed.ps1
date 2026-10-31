# Official verifier bytes and signed v9.5.0 release, with no trust-anchor substitution.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Import-Module Microsoft.PowerShell.Archive
$work = Join-Path ([IO.Path]::GetTempPath()) ('cerebe-signed-' + [guid]::NewGuid())
$source = Get-Content "$PSScriptRoot/../../install.ps1" -Raw
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' } else { 'amd64' }
$saved = @{}
foreach ($key in @('PATH', 'CEREBE_VERSION', 'CEREBE_RELEASE_JSON', 'CEREBE_INSTALL_DIR', 'CEREBE_SKIP_REPO')) { $saved[$key] = [Environment]::GetEnvironmentVariable($key) }
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
New-Item -ItemType Directory -Path "$work/cache", "$work/path-tools" -Force | Out-Null
function Invoke-WebRequest($Uri, $OutFile, $Headers, [switch]$UseBasicParsing) {
    $name = ([uri]$Uri).Segments[-1]
    Add-Content "$case/downloads" $name
    Copy-Item -LiteralPath "$case/assets/$name" -Destination $OutFile
}
function Expand-Archive($LiteralPath, $DestinationPath) {
    Add-Content "$case/extracts" $LiteralPath
    Microsoft.PowerShell.Archive\Expand-Archive -LiteralPath $LiteralPath -DestinationPath $DestinationPath
}
try {
    # The token is injected by Actions. Never fetch or print a credential.
    $releaseText = & gh api repos/cerebe-ai/cerebe/releases/tags/v9.5.0
    if ($LASTEXITCODE -ne 0) { throw 'could not fetch signed release object' }
    $releaseText | Set-Content "$work/release.json" -Encoding UTF8
    $release = $releaseText -join "`n" | ConvertFrom-Json
    $names = @('checksums.txt', 'checksums.txt.sigstore.json', 'cerebe-cyclone.intoto.jsonl',
        "cerebe_9.5.0_windows_$arch.zip", "cyclone_9.5.0_windows_$arch.zip")
    foreach ($name in $names) {
        $url = @($release.assets | Where-Object { $_.name -ceq $name })
        if ($url.Count -ne 1) { throw "signed release is missing $name" }
        Microsoft.PowerShell.Utility\Invoke-WebRequest -UseBasicParsing -Uri $url[0].browser_download_url -OutFile "$work/cache/$name"
    }
    foreach ($url in @('https://github.com/sigstore/cosign/releases/download/v3.0.6/cosign-windows-amd64.exe',
        "https://github.com/slsa-framework/slsa-verifier/releases/download/v2.7.1/slsa-verifier-windows-$arch.exe")) {
        Microsoft.PowerShell.Utility\Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile (Join-Path "$work/cache" ([uri]$url).Segments[-1])
    }
    # Force the documented retry: PATH tools reject, official pinned tools decide.
    foreach ($name in @('cosign', 'slsa-verifier')) { Set-Content "$work/path-tools/$name.cmd" '@exit /b 1' -Encoding ASCII }
    $env:PATH = "$work/path-tools;$env:PATH"
    $env:CEREBE_VERSION = '9.5.0'; $env:CEREBE_RELEASE_JSON = "$work/release.json"
    foreach ($scenario in @('accepted', 'checksums', 'archive', 'bundle', 'provenance', 'identity', 'issuer', 'source', 'branch', 'builder')) {
        $case = "$work/$scenario"
        New-Item -ItemType Directory -Path "$case/assets" -Force | Out-Null
        Copy-Item "$work/cache/*" "$case/assets"
        $env:CEREBE_INSTALL_DIR = "$case/install"
        $script = $source
        switch ($scenario) {
            'checksums' { Add-Content "$case/assets/checksums.txt" 'tampered' }
            'archive' { Add-Content "$case/assets/cerebe_9.5.0_windows_$arch.zip" 'tampered' }
            'bundle' { Remove-Item "$case/assets/checksums.txt.sigstore.json" }
            'provenance' { Remove-Item "$case/assets/cerebe-cyclone.intoto.jsonl" }
            'identity' { $script = $script.Replace('cli-release.yml@refs/heads/main', 'other.yml@refs/heads/main') }
            'issuer' { $script = $script.Replace('https://token.actions.githubusercontent.com', 'https://other.invalid') }
            'source' { $script = $script.Replace("'github.com/cerebe-ai/dark-factory'", "'github.com/other/repository'") }
            'branch' { $script = $script.Replace("`$PROVENANCE_BRANCH = 'main'", "`$PROVENANCE_BRANCH = 'other'") }
            'builder' { $script = $script.Replace('generator_generic_slsa3.yml@refs/tags/v2.1.0', 'other.yml@refs/tags/v2.1.0') }
        }
        Set-Content "$case/installer.ps1" $script -Encoding ASCII
        $rejected = $false
        try { . "$case/installer.ps1" *> "$case/out" } catch { $rejected = $true; Add-Content "$case/out" $_.Exception.Message }
        if ($scenario -eq 'accepted') {
            if ($rejected) { throw (Get-Content "$case/out" -Raw) }
            foreach ($bin in @('cerebe', 'cyclone')) {
                $version = & "$case/install/$bin.exe" --version
                if ($LASTEXITCODE -ne 0 -or !($version -match '(^|\s)v?9\.5\.0($|\s)')) { throw "wrong signed $bin version: $version" }
            }
            $downloads = Get-Content "$case/downloads" -Raw
            if (!$downloads.Contains('cosign-windows-amd64.exe') -or !$downloads.Contains("slsa-verifier-windows-$arch.exe")) { throw 'PATH rejection did not retry pinned builds' }
        } else {
            $reason = switch ($scenario) {
                { $_ -in @('checksums', 'identity', 'issuer') } { 'checksum signature rejected' }
                'bundle' { 'checksums.txt.sigstore.json' }
                'provenance' { 'cerebe-cyclone.intoto.jsonl' }
                default { 'provenance rejected' }
            }
            if (!$rejected -or !(Get-Content "$case/out" -Raw).Contains($reason) -or (Test-Path "$case/install") -or (Test-Path "$case/extracts")) {
                throw "signed $scenario did not refuse before extraction: $(Get-Content "$case/out" -Raw)"
            }
        }
        Write-Host "EC1 signed $arch $scenario passed"
    }
} finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
    [Environment]::SetEnvironmentVariable('Path', $userPath, 'User')
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
# Expected native refusals must not become GitHub's final shell exit status.
exit 0
