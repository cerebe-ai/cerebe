# Cerebe Windows installer. Works with Windows PowerShell 5.1 and PowerShell 7.
# Before extraction: verify the checksum bundle, archive provenance, then hashes.
# No parameter or environment variable skips verification.
# Windows persists the selected directory in the user PATH, including overrides.
# "Binaries-only" skips repository setup.
# Env overrides (same meanings as install.sh):
#   CEREBE_VERSION       pin a release, optionally prefixed with v
#   CEREBE_INSTALL_DIR   install target AND binaries-only
#   CEREBE_SKIP_REPO     binaries-only when nonempty
#   CEREBE_RELEASE_JSON  previously fetched release object; requires a version pin
& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
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

    # Deliberate refusals use literal identifiers so the offline tests can
    # require a reached case for every check, including operational failures.
    function Refuse($Check, $Failure, $NextStep) {
        throw "cerebe-install: [$Check] $Failure. Next step: $NextStep"
    }
    function Download($Url, $Destination) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Destination -Headers @{
                Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'
            } | Out-Null
        } catch {
            Refuse 'download' "Download failed for ${Url}: $($_.Exception.Message)" 'Check access to GitHub and the release asset, then retry the installer'
        }
    }
    function Asset-Url($Name) {
        $urls = @($release.assets | ForEach-Object { $_.browser_download_url } | Where-Object {
            $_ -is [string] -and $_.StartsWith('https://github.com/', [StringComparison]::Ordinal) -and
            $_.EndsWith('/' + $Name, [StringComparison]::Ordinal)
        })
        if ($urls.Count -ne 1) { Refuse 'release-asset' "Release v$version has no unique $Name" 'Select a release containing exactly one matching asset, or report the incomplete release to its publisher' }
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
            Refuse 'verifier-checksum' "$Name checksum mismatch; refusing to run an untrusted verifier" 'Remove any download proxy or cache that changes executable bytes, then retry the pinned download'
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
    function Verify($Name, [string[]]$Arguments) {
        $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command -and (Accepts $command.Source $Arguments)) { return }
        $pinned = Pinned-Tool $Name
        if (!(Accepts $pinned $Arguments)) {
            if ($arch -eq 'arm64' -and $Name -eq 'cosign') {
                Refuse 'cosign-emulation' 'checksum signature rejected; cosign requires working x64 emulation on Windows ARM64' 'Enable x64 emulation on Windows 11 and retry; if it already works, select a release with a valid checksum signature'
            }
            if ($Name -eq 'cosign') {
                Refuse 'checksum-signature' 'checksum signature rejected' 'Retry with an official release whose checksum bundle matches the expected signing identity and issuer; report a repeated failure to the publisher'
            }
            Refuse 'provenance' 'Release provenance rejected' 'Select an official release with provenance for the expected source repository, branch and builder; report a repeated failure to the publisher'
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
    function Run-Installed($Tool, [string[]]$Arguments) {
        # Keep native stderr visible without letting its 5.1 ErrorRecord bypass
        # the caller's check-specific refusal. Output must not become the return value.
        $ErrorActionPreference = 'Continue'
        # Native commands update this automatic variable in global scope. A
        # failed launch must keep a nonzero sentinel rather than an older success.
        $global:LASTEXITCODE = 1
        try {
            & $Tool @Arguments | Out-Host
            return $global:LASTEXITCODE
        } catch {
            Write-Host $_.Exception.Message
            return 1
        }
    }
    function Install-Cerebe {
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Refuse 'windows-platform' 'Windows is required' 'Run install.ps1 on Windows, or use install.sh on Linux or macOS' }
        # W6432 names the native architecture from a process running in emulation.
        $nativeArchitecture = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITEW6432')
        if (!$nativeArchitecture) { $nativeArchitecture = $env:PROCESSOR_ARCHITECTURE }
        $arch = switch ($nativeArchitecture) {
            'AMD64' { 'amd64' }; 'ARM64' { 'arm64' }
            default { Refuse 'windows-architecture' "Unsupported Windows architecture: $nativeArchitecture" 'Run the installer on x64 Windows or Windows ARM64 with x64 emulation' }
        }
        $windowsBuild = [Environment]::OSVersion.Version.Build
        if ($arch -eq 'arm64' -and $windowsBuild -lt 22000) {
            Refuse 'windows-arm64-emulation' 'Windows ARM64 requires Windows 11 x64 emulation for cosign; refusing to install' 'Upgrade to Windows 11 with x64 emulation, then rerun the installer'
        }
        # Match install.sh's plain-release validation, including a bare v refusal.
        $version = $env:CEREBE_VERSION -creplace '^v', ''
        if ($env:CEREBE_VERSION -and $version -cnotmatch '\A[0-9A-Za-z.+_-]+\z') {
            Refuse 'release-version-pin' "CEREBE_VERSION is not a release version: $env:CEREBE_VERSION" 'Set CEREBE_VERSION to a plain release version, optionally prefixed with v, or unset it for the latest release'
        }
        $releaseFile = Join-Path $tmp 'release.json'
        if ($env:CEREBE_RELEASE_JSON) {
            if (!$env:CEREBE_VERSION) { Refuse 'cached-release-pin' 'CEREBE_RELEASE_JSON needs a CEREBE_VERSION pin' 'Set CEREBE_VERSION to the cached release version, or unset CEREBE_RELEASE_JSON to fetch release metadata' }
            Copy-Item -LiteralPath $env:CEREBE_RELEASE_JSON -Destination $releaseFile
        } else {
            $endpoint = if ($env:CEREBE_VERSION) { 'tags/v' + $version } else { 'latest' }
            Download "https://api.github.com/repositories/1181720228/releases/$endpoint" $releaseFile
        }
        $release = Get-Content -LiteralPath $releaseFile -Raw | ConvertFrom-Json
        $tag = $release.tag_name
        if ($tag -isnot [string] -or !$tag) { Refuse 'release-tag' 'Could not read the release tag' 'Refresh the release JSON from GitHub and retry with metadata containing a tag_name' }
        if ($version -and $tag -cne ('v' + $version)) { Refuse 'release-pin-match' "Asked for v$version but GitHub returned $tag" 'Set CEREBE_VERSION to the intended release and refresh CEREBE_RELEASE_JSON to that same release' }
        $version = $tag -creplace '^v', ''
        if ($version -cnotmatch '\A[0-9A-Za-z.+_-]+\z') { Refuse 'release-version' "Unexpected release version: $version" 'Select an official release with a plain version tag and refresh the release metadata' }
        Write-Host "Installing Cerebe CLI v$version (windows_$arch)"
        Push-Location $tmp
        try {
            Download (Asset-Url 'checksums.txt') (Join-Path $tmp 'checksums.txt')
            Download (Asset-Url $BUNDLE_NAME) (Join-Path $tmp $BUNDLE_NAME)
            if (!(Get-Item -LiteralPath $BUNDLE_NAME).Length) { Refuse 'checksum-bundle' "Empty $BUNDLE_NAME" 'Select a release with a nonempty checksum signature bundle, or report the incomplete release to its publisher' }
            Verify 'cosign' @('verify-blob', '--bundle', $BUNDLE_NAME, '--certificate-identity',
                $CERT_IDENTITY, '--certificate-oidc-issuer', $CERT_ISSUER, 'checksums.txt')
            $archives = @('cerebe', 'cyclone' | ForEach-Object { "${_}_${version}_windows_$arch.zip" })
            foreach ($archive in $archives) { Download (Asset-Url $archive) (Join-Path $tmp $archive) }
            Download (Asset-Url $PROVENANCE_NAME) (Join-Path $tmp $PROVENANCE_NAME)
            if (!(Get-Item -LiteralPath $PROVENANCE_NAME).Length) { Refuse 'provenance-file' "Empty $PROVENANCE_NAME" 'Select a release with nonempty archive provenance, or report the incomplete release to its publisher' }
            Verify 'slsa-verifier' (@('verify-artifact', '--provenance-path', $PROVENANCE_NAME,
                '--source-uri', $PROVENANCE_SOURCE, '--source-branch', $PROVENANCE_BRANCH,
                '--builder-id', $PROVENANCE_BUILDER) + $archives)
            $checksums = @(Get-Content -LiteralPath 'checksums.txt')
            foreach ($archive in $archives) {
                $lines = @($checksums | Where-Object { $_ -cmatch ('\A[0-9a-fA-F]{64} [ *]' + [regex]::Escape($archive) + '\z') })
                if ($lines.Count -ne 1) { Refuse 'archive-checksum-entry' "No unique checksum entry for $archive" 'Select a release with exactly one checksum for each archive, or report the invalid checksum manifest to its publisher' }
                if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $lines[0].Substring(0, 64)) {
                    Refuse 'archive-checksum' "Checksum mismatch for $archive" 'Retry the download from the official release; if the mismatch persists, report it to the publisher'
                }
            }
            # Every archive passes every check before the first extraction.
            foreach ($binary in @('cerebe', 'cyclone')) {
                Expand-Archive -LiteralPath "${binary}_${version}_windows_$arch.zip" -DestinationPath $binary
                if (!(Test-Path -LiteralPath "$binary/$binary.exe" -PathType Leaf)) { Refuse 'archive-binary' "$binary.exe absent from archive" 'Select a release containing both executable files, or report the incomplete archive to its publisher' }
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
            if ((Run-Installed (Join-Path $directory "$binary.exe") @('--version')) -ne 0) {
                Refuse 'installed-binary' "Just-installed $binary did not run" 'Run the installed executable with --version to inspect its error, check Windows architecture compatibility, then reinstall an official release'
            }
        }
        if ($env:CEREBE_INSTALL_DIR -or $env:CI -or $env:CEREBE_SKIP_REPO) { return }
        $root = Git-Root
        if (!$root) { Write-Host 'Not a git repository; binaries only.'; return }
        $env:CEREBE_BIN = Join-Path $directory 'cerebe.exe'
        Push-Location $root
        try {
            $setup = if (Test-Path -LiteralPath 'cerebe/config.json' -PathType Leaf) { 'init' } else { 'install' }
            if ((Run-Installed $env:CEREBE_BIN @($setup)) -ne 0) {
                Refuse 'repository-setup' "cerebe $setup failed" "Correct the error printed by cerebe $setup, then rerun cerebe $setup from the repository root"
            }
            if ((Run-Installed $env:CEREBE_BIN @('doctor')) -ne 0) {
                Refuse 'repository-doctor' 'cerebe doctor reported a blocking row' 'Apply the fix shown on each blocking doctor row, then rerun cerebe doctor from the repository root'
            }
        } finally { Pop-Location }
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        New-Item -ItemType Directory -Path $tmp | Out-Null
        Install-Cerebe
    } catch {
        if ($_.Exception.Message.StartsWith('cerebe-install: [')) { throw }
        Refuse 'installer-operation' "Installer operation failed: $($_.Exception.Message)" 'Correct the file, JSON or permission error shown above, then retry the installer'
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
