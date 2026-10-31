# Cerebe Windows installer. Works with Windows PowerShell 5.1 and PowerShell 7.
# Before extraction: verify the checksum bundle, archive provenance, then hashes.
# No parameter or environment variable skips verification.
# Env overrides (same meanings as install.sh):
#   CEREBE_VERSION       pin a release, optionally prefixed with v
#   CEREBE_INSTALL_DIR   install target AND binaries-only
#   CEREBE_SKIP_REPO     binaries-only when nonempty
#   CEREBE_RELEASE_JSON  previously fetched release object; requires a version pin
& {
    $ErrorActionPreference = 'Stop'
    $CERT_IDENTITY = 'https://github.com/cerebe-ai/dark-factory/.github/workflows/cli-release.yml@refs/heads/main'
    $CERT_ISSUER = 'https://token.actions.githubusercontent.com'
    $PROVENANCE_SOURCE = 'github.com/cerebe-ai/dark-factory'
    $PROVENANCE_BRANCH = 'main'
    $PROVENANCE_BUILDER = 'https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml@refs/tags/v2.1.0'
    $BUNDLE_NAME = 'checksums.txt.sigstore.json'
    $PROVENANCE_NAME = 'cerebe-cyclone.intoto.jsonl'
    # cosign's published cosign_checksums.txt; slsa-verifier's bytes at v2.7.1.
    $COSIGN_SHA256 = '9b85a88ebff2d9dd30ff4984a6f61f2cedc232dd87d81fa7f2ff3c0ed96c241c'
    $SLSA_AMD64_SHA256 = '1d8f61ad747ecc3d375d2a563cebf2991748b7da1a9bda9a500804c3c499e3c0'
    $SLSA_ARM64_SHA256 = '44144e98328d221f0490ef6b4a58a465defe8f697f387abbbf07ef5adb68d4ac'
    $originalDirectory = (Get-Location).Path
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('cerebe-install-' + [guid]::NewGuid())

    function Download($Url, $Destination) {
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Destination -Headers @{
            Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'
        } | Out-Null
    }
    function Asset-Url($Name) {
        $urls = @($release.assets | ForEach-Object { $_.browser_download_url } | Where-Object {
            $_ -is [string] -and $_.StartsWith('https://github.com/', [StringComparison]::Ordinal) -and
            $_.EndsWith('/' + $Name, [StringComparison]::Ordinal)
        })
        if ($urls.Count -ne 1) { throw "release v$version has no unique $Name; refusing to install" }
        return $urls[0]
    }
    function Pinned-Tool($Name) {
        $dest = Join-Path $tmp ($Name + '.exe')
        if (Test-Path -LiteralPath $dest) { return $dest }
        if ($Name -eq 'cosign') {
            $url = 'https://github.com/sigstore/cosign/releases/download/v3.0.6/cosign-windows-amd64.exe'
            $expected = $COSIGN_SHA256
        } else {
            $url = "https://github.com/slsa-framework/slsa-verifier/releases/download/v2.7.1/slsa-verifier-windows-$arch.exe"
            $expected = if ($arch -eq 'arm64') { $SLSA_ARM64_SHA256 } else { $SLSA_AMD64_SHA256 }
        }
        Download $url $dest
        if ((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -ne $expected) {
            throw "$Name checksum mismatch; refusing to run an untrusted verifier"
        }
        return $dest
    }
    function Accepts($Tool, [string[]]$Arguments) {
        # Native stderr is an ErrorRecord in 5.1. Its exit status is the verdict.
        $ErrorActionPreference = 'Continue'
        try {
            & $Tool @Arguments > $null 2> $null
            return ($LASTEXITCODE -eq 0)
        } catch { return $false }
    }
    function Verify($Name, [string[]]$Arguments, $Failure) {
        $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command -and (Accepts $command.Source $Arguments)) { return }
        $pinned = Pinned-Tool $Name
        if (!(Accepts $pinned $Arguments)) {
            if ($arch -eq 'arm64' -and $Name -eq 'cosign') {
                throw "$Failure (cosign requires working x64 emulation on Windows ARM64)"
            }
            throw $Failure
        }
    }
    function Path-Key($Value) {
        return [Environment]::ExpandEnvironmentVariables($Value).TrimEnd('\', '/')
    }
    function Add-UserPath($Directory) {
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $entries = @($userPath -split ';' | Where-Object { $_ })
        if (!($entries | Where-Object { (Path-Key $_) -ieq (Path-Key $Directory) })) {
            [Environment]::SetEnvironmentVariable('Path', (($Directory + ';' + $userPath).TrimEnd(';')), 'User')
        }
        $env:PATH = (@($Directory) + @($env:PATH -split ';' | Where-Object {
            $_ -and (Path-Key $_) -ine (Path-Key $Directory)
        })) -join ';'
    }
    function Git-Root {
        $ErrorActionPreference = 'Continue'
        if (!(Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) { return }
        $root = & git -C $originalDirectory rev-parse --show-toplevel 2> $null
        if ($LASTEXITCODE -eq 0) { return $root }
    }
    function Install-Cerebe {
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows is required' }
        # W6432 names the native architecture from a process running in emulation.
        $nativeArchitecture = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITEW6432')
        if (!$nativeArchitecture) { $nativeArchitecture = $env:PROCESSOR_ARCHITECTURE }
        $arch = switch ($nativeArchitecture) {
            'AMD64' { 'amd64' }; 'ARM64' { 'arm64' }
            default { throw "unsupported Windows architecture: $nativeArchitecture" }
        }
        $windowsBuild = [Environment]::OSVersion.Version.Build
        if ($arch -eq 'arm64' -and $windowsBuild -lt 22000) {
            throw 'Windows ARM64 requires Windows 11 x64 emulation for cosign; refusing to install'
        }
        # Match install.sh's plain-release validation, including a bare v refusal.
        $version = $env:CEREBE_VERSION -creplace '^v', ''
        if ($env:CEREBE_VERSION -and $version -cnotmatch '\A[0-9A-Za-z.+_-]+\z') {
            throw "CEREBE_VERSION is not a release version: $env:CEREBE_VERSION"
        }
        $releaseFile = Join-Path $tmp 'release.json'
        if ($env:CEREBE_RELEASE_JSON) {
            if (!$env:CEREBE_VERSION) { throw 'CEREBE_RELEASE_JSON needs a CEREBE_VERSION pin' }
            Copy-Item -LiteralPath $env:CEREBE_RELEASE_JSON -Destination $releaseFile
        } else {
            $endpoint = if ($env:CEREBE_VERSION) { 'tags/v' + $version } else { 'latest' }
            Download "https://api.github.com/repositories/1181720228/releases/$endpoint" $releaseFile
        }
        $release = Get-Content -LiteralPath $releaseFile -Raw | ConvertFrom-Json
        $tag = $release.tag_name
        if ($tag -isnot [string] -or !$tag) { throw 'could not read the release tag' }
        if ($version -and $tag -cne ('v' + $version)) { throw "asked for v$version but GitHub returned $tag" }
        $version = $tag -creplace '^v', ''
        if ($version -cnotmatch '\A[0-9A-Za-z.+_-]+\z') { throw "unexpected release version: $version" }
        Write-Host "Installing Cerebe CLI v$version (windows_$arch)"
        Push-Location $tmp
        try {
            Download (Asset-Url 'checksums.txt') (Join-Path $tmp 'checksums.txt')
            Download (Asset-Url $BUNDLE_NAME) (Join-Path $tmp $BUNDLE_NAME)
            if (!(Get-Item -LiteralPath $BUNDLE_NAME).Length) { throw "empty $BUNDLE_NAME" }
            Verify 'cosign' @('verify-blob', '--bundle', $BUNDLE_NAME, '--certificate-identity',
                $CERT_IDENTITY, '--certificate-oidc-issuer', $CERT_ISSUER, 'checksums.txt') 'checksum signature rejected'
            $archives = @('cerebe', 'cyclone' | ForEach-Object { "${_}_${version}_windows_$arch.zip" })
            foreach ($archive in $archives) { Download (Asset-Url $archive) (Join-Path $tmp $archive) }
            Download (Asset-Url $PROVENANCE_NAME) (Join-Path $tmp $PROVENANCE_NAME)
            if (!(Get-Item -LiteralPath $PROVENANCE_NAME).Length) { throw "empty $PROVENANCE_NAME" }
            Verify 'slsa-verifier' (@('verify-artifact', '--provenance-path', $PROVENANCE_NAME,
                '--source-uri', $PROVENANCE_SOURCE, '--source-branch', $PROVENANCE_BRANCH,
                '--builder-id', $PROVENANCE_BUILDER) + $archives) 'provenance rejected'
            $checksums = @(Get-Content -LiteralPath 'checksums.txt')
            foreach ($archive in $archives) {
                $lines = @($checksums | Where-Object { $_ -cmatch ('\A[0-9a-fA-F]{64} [ *]' + [regex]::Escape($archive) + '\z') })
                if ($lines.Count -ne 1) { throw "no unique checksum entry for $archive" }
                if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $lines[0].Substring(0, 64)) {
                    throw "checksum mismatch for $archive"
                }
            }
            # Every archive passes every check before the first extraction.
            foreach ($binary in @('cerebe', 'cyclone')) {
                Expand-Archive -LiteralPath "${binary}_${version}_windows_$arch.zip" -DestinationPath $binary
                if (!(Test-Path -LiteralPath "$binary/$binary.exe" -PathType Leaf)) { throw "$binary.exe absent from archive" }
            }
            $directory = if ($env:CEREBE_INSTALL_DIR) { $env:CEREBE_INSTALL_DIR } else {
                Join-Path $env:LOCALAPPDATA 'Programs\Cerebe'
            }
            # Resolve overrides against the caller's directory, not the download directory.
            if (![IO.Path]::IsPathRooted($directory)) { $directory = Join-Path $originalDirectory $directory }
            $directory = [IO.Path]::GetFullPath($directory)
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            foreach ($binary in @('cerebe', 'cyclone')) {
                Copy-Item -LiteralPath "$binary/$binary.exe" -Destination (Join-Path $directory "$binary.exe") -Force
            }
        } finally { Pop-Location }
        Add-UserPath $directory
        foreach ($binary in @('cerebe', 'cyclone')) {
            & (Join-Path $directory "$binary.exe") --version
            if ($LASTEXITCODE -ne 0) { throw "just-installed $binary did not run" }
        }
        if ($env:CEREBE_INSTALL_DIR -or $env:CI -or $env:CEREBE_SKIP_REPO) { return }
        $root = Git-Root
        if (!$root) { Write-Host 'Not a git repository; binaries only.'; return }
        $env:CEREBE_BIN = Join-Path $directory 'cerebe.exe'
        Push-Location $root
        try {
            $setup = if (Test-Path -LiteralPath 'cerebe/config.json' -PathType Leaf) { 'init' } else { 'install' }
            & $env:CEREBE_BIN $setup
            if ($LASTEXITCODE -ne 0) { throw "cerebe $setup failed" }
            & $env:CEREBE_BIN doctor
            if ($LASTEXITCODE -ne 0) { throw 'cerebe doctor reported a blocking row' }
        } finally { Pop-Location }
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        New-Item -ItemType Directory -Path $tmp | Out-Null
        Install-Cerebe
    } catch { throw "cerebe-install: $($_.Exception.Message)" }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
