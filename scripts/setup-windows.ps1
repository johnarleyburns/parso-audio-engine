<#
.SYNOPSIS
    Install and configure the native Windows and .NET toolchains.

.DESCRIPTION
    Uses winget to install Visual Studio 2022 C++ Build Tools, CMake, Ninja,
    Git, and the .NET 8 SDK. Then configures and tests the native MSVC CMake
    build and the C# consumer against the generated parso.dll.

    Run from PowerShell on Windows 10/11. Visual Studio Build Tools installation
    requires an elevated PowerShell prompt. Reopen PowerShell after installation
    if newly installed commands are not yet on PATH.

.EXAMPLE
    .\scripts\setup-windows.ps1

.EXAMPLE
    .\scripts\setup-windows.ps1 -NoInstall

.EXAMPLE
    .\scripts\setup-windows.ps1 -NoBuild
#>
[CmdletBinding()]
param(
    [switch]$NoInstall,
    [switch]$NoBuild,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [string]$BuildDirectory = 'build-native'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$BuildPath = Join-Path $RepoRoot $BuildDirectory

function Write-Step([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name was not found on PATH. Reopen PowerShell after installation and rerun the script."
    }
}

function Install-WingetPackage([string]$Id, [string]$Override = '') {
    $installed = winget list --id $Id --exact --accept-source-agreements 2>$null | Select-String -SimpleMatch $Id
    if ($installed) {
        Write-Host "Already installed: $Id"
        return
    }

    Write-Step "Installing $Id"
    $arguments = @(
        'install', '--id', $Id, '--exact',
        '--accept-package-agreements', '--accept-source-agreements'
    )
    if ($Override) {
        $arguments += @('--override', $Override)
    }
    & winget @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "winget failed to install $Id with exit code $LASTEXITCODE"
    }
}

if ($env:OS -ne 'Windows_NT') {
    throw 'setup-windows.ps1 must run on Windows.'
}

if (-not $NoInstall) {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script from an elevated PowerShell prompt to install Visual Studio Build Tools.'
    }
    Require-Command 'winget'
    Write-Step 'Installing Windows native and managed build prerequisites'
    Install-WingetPackage 'Git.Git'
    Install-WingetPackage 'Kitware.CMake'
    Install-WingetPackage 'Ninja-build.Ninja'
    Install-WingetPackage 'Microsoft.DotNet.SDK.8'
    Install-WingetPackage 'Microsoft.VisualStudio.2022.BuildTools' `
        '--wait --passive --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
}

if ($NoBuild) {
    Write-Host 'Toolchain installation complete; skipping build verification.'
    exit 0
}

Require-Command 'cmake'
Require-Command 'ctest'
Require-Command 'dotnet'

Write-Step 'Configuring the native MSVC CMake build'
cmake -S $RepoRoot -B $BuildPath `
    -G 'Visual Studio 17 2022' `
    -A x64 `
    -DPARSO_BUILD_TESTS=ON `
    -DPARSO_BUILD_SHARED_API=ON
if ($LASTEXITCODE -ne 0) { throw 'CMake configuration failed.' }

Write-Step 'Building native C/C++ targets'
cmake --build $BuildPath --config $Configuration --parallel
if ($LASTEXITCODE -ne 0) { throw 'Native CMake build failed.' }

Write-Step 'Running native CTest targets'
ctest --test-dir $BuildPath -C $Configuration --output-on-failure
if ($LASTEXITCODE -ne 0) { throw 'Native CTest failed.' }

Write-Step 'Building and running the C# consumer'
$ConsumerProject = Join-Path $RepoRoot 'Bindings/ParsoAudioSharp.Consumer/ParsoAudioSharp.Consumer.csproj'
dotnet build $ConsumerProject --configuration $Configuration
if ($LASTEXITCODE -ne 0) { throw 'C# consumer build failed.' }

$NativeReleasePath = Join-Path $BuildPath $Configuration
$env:Path = "$NativeReleasePath;$env:Path"
dotnet run --project $ConsumerProject --configuration $Configuration --no-build
if ($LASTEXITCODE -ne 0) { throw 'C# native consumer failed.' }

Write-Host ''
Write-Host 'Windows native and .NET setup complete.' -ForegroundColor Green
Write-Host "  CMake build: $BuildPath"
