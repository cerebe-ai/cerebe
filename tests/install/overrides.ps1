# Header additions must acquire a behavioral test, rather than silently drifting.
$ErrorActionPreference = 'Stop'
$posix = Get-Content "$PSScriptRoot/../../install.sh" -Raw
$header = [regex]::Match($posix, '(?s)# Env overrides:(.*?)set -eu').Groups[1].Value
$names = @([regex]::Matches($header, '(?m)^#\s+(CEREBE_[A-Z_]+)=') | ForEach-Object { $_.Groups[1].Value })
$coverage = @{ CEREBE_VERSION = 'EC5'; CEREBE_RELEASE_JSON = 'EC5'; CEREBE_INSTALL_DIR = 'EC3/EC4'; CEREBE_SKIP_REPO = 'EC4' }
if (!$names.Count) { throw 'no override names read from install.sh header' }
foreach ($name in $names) { if (!$coverage.ContainsKey($name)) { throw "no PowerShell behavior test for $name" } }
& "$PSScriptRoot/run.ps1" -Criterion EC5
Write-Host ('EC5 override coverage: ' + ($names -join ', '))
