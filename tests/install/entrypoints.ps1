# Run the published command, or the checked-out shell handoff, with real trust
# verification. A native observer records the environment after MSYS conversion.
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('cmd', 'powershell', 'gitbash', 'msys2', 'cygwin')]
    [string]$Shell,
    [string]$MsysRoot,
    [string]$CygwinRoot
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = (Resolve-Path "$PSScriptRoot/../..").Path
$commands = Get-Content "$root/install-commands.json" -Raw | ConvertFrom-Json
$work = Join-Path ([IO.Path]::GetTempPath()) ('cerebe entrypoints ' + [guid]::NewGuid())
$saved = @{}
Get-ChildItem Env: | Where-Object { $_.Name -match '^(CI$|PATH$|CEREBE_|HANDOFF_)' } | ForEach-Object { $saved[$_.Name] = $_.Value }
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
New-Item -ItemType Directory -Path "$work/shim", "$work/caller with spaces" -Force | Out-Null
try {
    $env:HANDOFF_POWERSHELL = (Get-Command powershell.exe).Source
    $env:HANDOFF_TRACE = "$work/trace.json"
    # Forward the original native command line, preserving its quoting. The
    # observer makes no installer decisions and exits with the real PS result.
    Add-Type -OutputAssembly "$work/shim/powershell.exe" -OutputType ConsoleApplication -ReferencedAssemblies System.Web.Extensions -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Web.Script.Serialization;
public class ObservePowerShell {
    public static int Main() {
        var env = new Dictionary<string, string>();
        foreach (DictionaryEntry item in Environment.GetEnvironmentVariables()) {
            string key = (string)item.Key;
            if (String.Equals(key, "CI", StringComparison.OrdinalIgnoreCase) || key.StartsWith("CEREBE_", StringComparison.OrdinalIgnoreCase))
                env[key] = (string)item.Value;
        }
        File.WriteAllText(Environment.GetEnvironmentVariable("HANDOFF_TRACE"),
            new JavaScriptSerializer().Serialize(new { cwd = Environment.CurrentDirectory, environment = env }));
        string line = Environment.CommandLine;
        int end = line[0] == '"' ? line.IndexOf('"', 1) + 1 : line.IndexOf(' ');
        var start = new ProcessStartInfo(Environment.GetEnvironmentVariable("HANDOFF_POWERSHELL"), line.Substring(end).TrimStart());
        start.UseShellExecute = false;
        using (var child = Process.Start(start)) { child.WaitForExit(); return child.ExitCode; }
    }
}
'@
    $env:PATH = "$work/shim;$env:PATH"
    $env:CI = 'ci /literal:with spaces'
    $env:CEREBE_SENTINEL = '/do/not/convert:/second path' + [char]0x03bb + "`nthird line"
    $env:CEREBE_VERSION = '9.5.0'
    $env:CEREBE_SKIP_REPO = '1'
    $env:CEREBE_INSTALL_DIR = "$work/installed binaries"
    $env:CEREBE_RELEASE_JSON = "$work/release.json"
    $release = & gh api repositories/1181720228/releases/tags/v9.5.0
    if ($LASTEXITCODE -ne 0) { throw 'authenticated release lookup failed' }
    [IO.File]::WriteAllText($env:CEREBE_RELEASE_JSON, ($release -join "`n"))
    $expected = @{}
    Get-ChildItem Env: | Where-Object { $_.Name -match '^(CI$|CEREBE_)' } | ForEach-Object { $expected[$_.Name] = $_.Value }
    Push-Location "$work/caller with spaces"
    try {
        switch ($Shell) {
            'cmd' {
                [IO.File]::WriteAllText("$work/command.cmd", "@echo off`r`n$($commands.windows)`r`nexit /b %ERRORLEVEL%`r`n")
                & cmd.exe /d /c "`"$work/command.cmd`""
            }
            'powershell' {
                [IO.File]::WriteAllText("$work/command.ps1", "$($commands.windows)`r`nexit `$LASTEXITCODE`r`n")
                & $env:HANDOFF_POWERSHELL -NoProfile -ExecutionPolicy ByPass -File "$work/command.ps1"
            }
            default {
                $bash = switch ($Shell) {
                    'gitbash' { 'C:\Program Files\Git\bin\bash.exe' }
                    'msys2' { Join-Path $MsysRoot 'usr/bin/bash.exe' }
                    'cygwin' { Join-Path $CygwinRoot 'bin/bash.exe' }
                }
                # bash maps the inherited native working directory; avoid a
                # login shell, which would deliberately cd to the user's home.
                $env:HANDOFF_INSTALLER = "$root/install.sh"
                $start = New-Object Diagnostics.ProcessStartInfo
                $start.FileName = $bash
                $start.Arguments = '--noprofile --norc -s'
                $start.WorkingDirectory = (Get-Location).Path
                $start.UseShellExecute = $false
                $start.RedirectStandardInput = $true
                $child = [Diagnostics.Process]::Start($start)
                $child.StandardInput.Write('exec sh "$(cygpath -u "$HANDOFF_INSTALLER")"' + "`n")
                $child.StandardInput.Close()
                $child.WaitForExit()
                $LASTEXITCODE = $child.ExitCode
                $child.Dispose()
            }
        }
        if ($LASTEXITCODE -ne 0) { throw "$Shell install exited $LASTEXITCODE" }
        $trace = Get-Content $env:HANDOFF_TRACE -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($trace.cwd -ne (Get-Location).Path) { throw "$Shell changed the working directory" }
        if (@($trace.environment.PSObject.Properties).Count -ne $expected.Count) { throw "$Shell changed the environment keys" }
        foreach ($key in $expected.Keys) {
            if ($trace.environment.$key -cne $expected[$key]) { throw "$Shell changed environment variable $key" }
        }
        foreach ($name in @('cerebe', 'cyclone')) {
            $version = & "$env:CEREBE_INSTALL_DIR/$name.exe" --version
            if ($LASTEXITCODE -ne 0 -or "$version" -notmatch '(^|\s)v?9\.5\.0($|\s)') { throw "$name installed version mismatch" }
        }
        Write-Output "PASS $Shell verified both signed binaries; native cwd and every CI/CEREBE_ value preserved"
    } finally { Pop-Location }
} finally {
    [Environment]::SetEnvironmentVariable('Path', $userPath, 'User')
    Get-ChildItem Env: | Where-Object { $_.Name -match '^(CI$|PATH$|CEREBE_|HANDOFF_)' } | ForEach-Object { [Environment]::SetEnvironmentVariable($_.Name, $null) }
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
    Remove-Item -LiteralPath $work -Recurse -Force
}
