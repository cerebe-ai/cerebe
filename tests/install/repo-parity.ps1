# Distribution is stubbed here; this oracle compares the shipped POSIX setup
# dispatch and exit status. Only its default destination is relocated for isolation.
param($Case, $Mode, $Expected, [bool]$ShouldFail)
$ErrorActionPreference = 'Stop'
$dir = "$($Case.Directory)/oracle"
New-Item -ItemType Directory -Path "$dir/assets", "$dir/bin", "$dir/src" -Force | Out-Null
$binary = @'
#!/bin/sh
b=${0##*/}
printf '%s %s\n' "$b" "$*" >> "$STUB_LOG"
if [ "$1" = --version ]; then echo "$b v8.17.1"; fi
if [ "$1" = doctor ] && [ -n "${STUB_DOCTOR_FAIL:-}" ]; then exit 1; fi
exit 0
'@
foreach ($bin in @('cerebe', 'cyclone')) { [IO.File]::WriteAllText("$dir/src/$bin", $binary.Replace("`r", ''), [Text.Encoding]::ASCII) }
Copy-Item "$($Case.Directory)/release.json" "$dir/release.json"
$installer = (Get-Content "$PSScriptRoot/../../install.sh" -Raw).Replace('DIR="/usr/local/bin"', 'DIR="$STUB_DEFAULT_DIR"')
[IO.File]::WriteAllText("$dir/install.sh", $installer, [Text.Encoding]::ASCII)
$curl = @'
#!/bin/sh
while [ "$#" -gt 0 ]; do
  case "$1" in -o) out=$2; shift 2;; -H) shift 2;; -*) shift;; *) url=$1; shift;; esac
done
cp "$STUB_ASSETS/${url##*/}" "$out"
'@
[IO.File]::WriteAllText("$dir/bin/curl", $curl.Replace("`r", ''), [Text.Encoding]::ASCII)
foreach ($tool in @('cosign', 'slsa-verifier')) { [IO.File]::WriteAllText("$dir/bin/$tool", "#!/bin/sh`nexit 0`n", [Text.Encoding]::ASCII) }
[IO.File]::WriteAllText("$dir/bin/uname", "#!/bin/sh`ncase `"`$1`" in -s) echo Linux;; *) echo x86_64;; esac`n", [Text.Encoding]::ASCII)
$bootstrap = @'
set -eu
export PATH="/usr/bin:/bin:$PATH"
d=$(cygpath -u "$STUB_ORACLE_DATA")
export STUB_ASSETS="$d/assets" STUB_DEFAULT_DIR="$d/default" STUB_LOG="$d/calls"
export PATH="$d/bin:$PATH"
mkdir -p "$STUB_DEFAULT_DIR"
chmod +x "$d"/bin/* "$d"/src/*
for b in cerebe cyclone; do tar -czf "$d/assets/${b}_8.17.1_linux_amd64.tar.gz" -C "$d/src" "$b"; done
(cd "$d/assets" && for f in *.tar.gz; do sum=$(sha256sum "$f"); printf '%s  %s\n' "${sum%% *}" "$f"; done > checksums.txt)
touch "$d/assets/checksums.txt.sigstore.json" "$d/assets/cerebe-cyclone.intoto.jsonl"
echo fixture > "$d/assets/checksums.txt.sigstore.json"
echo fixture > "$d/assets/cerebe-cyclone.intoto.jsonl"
export CEREBE_VERSION=8.17.1 CEREBE_RELEASE_JSON="$d/release.json"
if [ "$STUB_ORACLE_OVERRIDE" = 1 ]; then export CEREBE_INSTALL_DIR="$d/install"; else unset CEREBE_INSTALL_DIR; fi
cd "$(cygpath -u "$STUB_ORACLE_CWD")"
sh "$d/install.sh"
'@
[IO.File]::WriteAllText("$dir/run.sh", $bootstrap.Replace("`r", ''), [Text.Encoding]::ASCII)
$changes = @{
    STUB_ORACLE_DATA = $dir; STUB_ORACLE_CWD = $Case.Cwd
    STUB_ORACLE_OVERRIDE = $(if ($Mode -eq 'CEREBE_INSTALL_DIR') { '1' } else { '0' })
    CI = $Case.Env.CI; CEREBE_SKIP_REPO = $Case.Env.CEREBE_SKIP_REPO; STUB_DOCTOR_FAIL = $Case.Env.STUB_DOCTOR_FAIL
}
$previous = @{}
try {
    foreach ($key in $changes.Keys) { $previous[$key] = [Environment]::GetEnvironmentVariable($key); [Environment]::SetEnvironmentVariable($key, $changes[$key]) }
    $ErrorActionPreference = 'Continue'
    & "$env:ProgramFiles/Git/bin/bash.exe" --noprofile --norc "$dir/run.sh" *> "$dir/out"
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if (!(Test-Path "$dir/calls")) {
        $manifest = if (Test-Path "$dir/assets/checksums.txt") { Get-Content "$dir/assets/checksums.txt" -Raw | ConvertTo-Json -Compress } else { 'not generated' }
        throw "POSIX oracle did not reach the binaries (exit $code): $(Get-Content "$dir/out" -Raw); manifest: $manifest"
    }
    $calls = @(Get-Content "$dir/calls" | Where-Object { $_ -match '^cerebe (install|init|doctor)$' })
    if (($calls -join ';') -ne ($Expected -join ';') -or (($code -ne 0) -ne $ShouldFail)) {
        throw "POSIX parity failed for $Mode : $(Get-Content "$dir/out" -Raw)"
    }
} finally { foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key]) } }
