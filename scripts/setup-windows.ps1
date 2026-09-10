<#
.SYNOPSIS
    Install and configure the native Windows and .NET toolchains.

.DESCRIPTION
    Uses winget to install Visual Studio 2022 C++ Build Tools, CMake, Ninja,
    Git, and the .NET 8 SDK, plus Google's official Android CLI and Android
    SDK/NDK/CMake packages. Then configures and tests the native MSVC CMake
    build, C# consumer, and Android arm64-v8a/x86_64 cross-builds.

    Run from PowerShell on Windows 10/11. Visual Studio Build Tools installation
    requires an elevated PowerShell prompt. Reopen PowerShell after installation
    if newly installed commands are not yet on PATH.

.EXAMPLE
    .\scripts\setup-windows.ps1

.EXAMPLE
    .\scripts\setup-windows.ps1 -NoInstall

.EXAMPLE
    .\scripts\setup-windows.ps1 -NoBuild

.EXAMPLE
    .\scripts\setup-windows.ps1 -NoAndroidBuild
#>
[CmdletBinding()]
param(
    [switch]$NoInstall,
    [switch]$NoBuild,
    [switch]$NoAndroid,
    [switch]$NoAndroidBuild,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [string]$BuildDirectory = 'build-native',
    [string]$AndroidSdkRoot = ''
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$BuildPath = Join-Path $RepoRoot $BuildDirectory
$AndroidSdkRoot = if ($AndroidSdkRoot) {
    $AndroidSdkRoot
} elseif ($env:ANDROID_HOME) {
    $env:ANDROID_HOME
} elseif ($env:ANDROID_SDK_ROOT) {
    $env:ANDROID_SDK_ROOT
} else {
    Join-Path $env:LOCALAPPDATA 'Android\Sdk'
}
$AndroidApiLevel = if ($env:PARSO_ANDROID_API_LEVEL) { $env:PARSO_ANDROID_API_LEVEL } else { '26' }
$AndroidCompileSdk = if ($env:PARSO_ANDROID_COMPILE_SDK) { $env:PARSO_ANDROID_COMPILE_SDK } else { '36' }
$AndroidNdkPackage = if ($env:PARSO_ANDROID_NDK_PACKAGE) { $env:PARSO_ANDROID_NDK_PACKAGE } else { '' }
$AndroidCmakePackage = if ($env:PARSO_ANDROID_CMAKE_PACKAGE) { $env:PARSO_ANDROID_CMAKE_PACKAGE } else { '' }
$AndroidCli = $null
$AndroidNdkRoot = $null
$AndroidCmakeBin = $null

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

function Get-LatestAndroidPackage([string]$Family) {
    $lines = & $script:AndroidCli "--sdk=$script:AndroidSdkRoot" sdk list --all "$Family/*"
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list Android SDK packages for $Family."
    }

    $bestPackage = $null
    $bestVersion = [version]'0.0'
    $familyPattern = [regex]::Escape($Family)
    foreach ($line in $lines) {
        $match = [regex]::Match([string]$line, "^\s*($familyPattern/[0-9][^\s]*)\s+([0-9]+(?:\.[0-9]+){0,3})")
        if (-not $match.Success -or [string]$line -match '-(rc|beta|canary)') {
            continue
        }
        try {
            $version = [version]$match.Groups[2].Value
        } catch {
            continue
        }
        if ($version -gt $bestVersion) {
            $bestVersion = $version
            $bestPackage = $match.Groups[1].Value
        }
    }
    if (-not $bestPackage) {
        throw "No stable Android SDK package was found for $Family."
    }
    return $bestPackage
}

function Set-AndroidEnvironment {
    $script:AndroidNdkRoot = Join-Path $script:AndroidSdkRoot ($script:AndroidNdkPackage -replace '/', '\')
    $cmakeRoot = Join-Path $script:AndroidSdkRoot ($script:AndroidCmakePackage -replace '/', '\')
    $script:AndroidCmakeBin = Join-Path $cmakeRoot 'bin\cmake.exe'
    if (-not (Test-Path (Join-Path $script:AndroidNdkRoot 'build\cmake\android.toolchain.cmake'))) {
        throw "Android NDK toolchain was not found at $script:AndroidNdkRoot."
    }
    if (-not (Test-Path $script:AndroidCmakeBin)) {
        throw "Android CMake was not found at $script:AndroidCmakeBin."
    }

    $platformTools = Join-Path $script:AndroidSdkRoot 'platform-tools'
    $androidBin = Join-Path $env:USERPROFILE '.local\bin'
    $env:ANDROID_HOME = $script:AndroidSdkRoot
    $env:ANDROID_SDK_ROOT = $script:AndroidSdkRoot
    $env:ANDROID_NDK_HOME = $script:AndroidNdkRoot
    $env:ANDROID_NDK_ROOT = $script:AndroidNdkRoot
    $env:PARSO_ANDROID_NDK_PACKAGE = $script:AndroidNdkPackage
    $env:PARSO_ANDROID_CMAKE_PACKAGE = $script:AndroidCmakePackage
    $env:PARSO_ANDROID_API_LEVEL = $script:AndroidApiLevel
    $env:PARSO_ANDROID_COMPILE_SDK = $script:AndroidCompileSdk
    $env:Path = "$androidBin;$platformTools;$(Split-Path $script:AndroidCmakeBin);$env:Path"

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $userEntries = @($userPath -split ';' | Where-Object { $_ })
    foreach ($entry in @($androidBin, $platformTools, (Split-Path $script:AndroidCmakeBin))) {
        if ($userEntries -notcontains $entry) { $userEntries += $entry }
    }
    [Environment]::SetEnvironmentVariable('Path', ($userEntries -join ';'), 'User')
    foreach ($name in @('ANDROID_HOME', 'ANDROID_SDK_ROOT', 'ANDROID_NDK_HOME', 'ANDROID_NDK_ROOT',
            'PARSO_ANDROID_NDK_PACKAGE', 'PARSO_ANDROID_CMAKE_PACKAGE',
            'PARSO_ANDROID_API_LEVEL', 'PARSO_ANDROID_COMPILE_SDK')) {
        [Environment]::SetEnvironmentVariable($name, (Get-Item "env:$name").Value, 'User')
    }
}

function Install-AndroidToolchain([bool]$AllowInstall) {
    $androidBin = Join-Path $env:USERPROFILE '.local\bin'
    $env:Path = "$androidBin;$env:Path"
    $androidCommand = Get-Command android -ErrorAction SilentlyContinue
    if (-not $androidCommand -and $AllowInstall) {
        Write-Step 'Installing the official Android CLI'
        $installer = Join-Path $env:TEMP 'parso-android-install.cmd'
        Invoke-WebRequest -UseBasicParsing `
            'https://dl.google.com/android/cli/latest/windows_x86_64/install.cmd' `
            -OutFile $installer
        & $installer
        Remove-Item -Force $installer
        $env:Path = "$androidBin;$env:Path"
        $androidCommand = Get-Command android -ErrorAction SilentlyContinue
    }
    if (-not $androidCommand) {
        throw 'The Android CLI was not found. Install it or rerun without -NoInstall.'
    }
    $script:AndroidCli = $androidCommand.Source
    & $script:AndroidCli '--version'
    if ($LASTEXITCODE -ne 0) { throw 'The Android CLI failed its version check.' }

    New-Item -ItemType Directory -Force -Path $script:AndroidSdkRoot | Out-Null
    Write-Step "Initializing Android SDK at $script:AndroidSdkRoot"
    & $script:AndroidCli "--sdk=$script:AndroidSdkRoot" init
    if ($LASTEXITCODE -ne 0) { throw 'Android SDK initialization failed.' }

    if ($AllowInstall) {
        if (-not $script:AndroidNdkPackage) { $script:AndroidNdkPackage = Get-LatestAndroidPackage 'ndk' }
        if (-not $script:AndroidCmakePackage) { $script:AndroidCmakePackage = Get-LatestAndroidPackage 'cmake' }
        $buildToolsPackage = Get-LatestAndroidPackage 'build-tools'
        $platformPackage = "platforms/android-$script:AndroidCompileSdk"
        foreach ($package in @('platform-tools', $platformPackage, $buildToolsPackage,
                $script:AndroidNdkPackage, $script:AndroidCmakePackage)) {
            Write-Step "Installing Android SDK package $package"
            & $script:AndroidCli "--sdk=$script:AndroidSdkRoot" sdk install $package
            if ($LASTEXITCODE -ne 0) { throw "Android SDK package installation failed: $package" }
        }
    } else {
        if (-not $script:AndroidNdkPackage) {
            $ndk = Get-ChildItem (Join-Path $script:AndroidSdkRoot 'ndk') -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | Select-Object -First 1
            if ($ndk) { $script:AndroidNdkPackage = "ndk/$($ndk.Name)" }
        }
        if (-not $script:AndroidCmakePackage) {
            $cmake = Get-ChildItem (Join-Path $script:AndroidSdkRoot 'cmake') -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | Select-Object -First 1
            if ($cmake) { $script:AndroidCmakePackage = "cmake/$($cmake.Name)" }
        }
    }
    if (-not $script:AndroidNdkPackage -or -not $script:AndroidCmakePackage) {
        throw 'Existing Android NDK/CMake packages were not found.'
    }
    Set-AndroidEnvironment
}

function Build-Android {
    foreach ($abi in @('arm64-v8a', 'x86_64')) {
        $androidBuildPath = Join-Path $script:RepoRoot "build-android-windows-$abi"
        Write-Step "Cross-building Android targets for $abi"
        & $script:AndroidCmakeBin `
            -S $script:RepoRoot `
            -B $androidBuildPath `
            -G Ninja `
            "-DCMAKE_TOOLCHAIN_FILE=$script:AndroidNdkRoot/build/cmake/android.toolchain.cmake" `
            "-DANDROID_ABI=$abi" `
            "-DANDROID_PLATFORM=android-$script:AndroidApiLevel" `
            "-DANDROID_NDK=$script:AndroidNdkRoot" `
            '-DCMAKE_BUILD_TYPE=Release' `
            '-DPARSO_BUILD_TESTS=OFF'
        if ($LASTEXITCODE -ne 0) { throw "Android CMake configuration failed for $abi." }
        & $script:AndroidCmakeBin --build $androidBuildPath --parallel
        if ($LASTEXITCODE -ne 0) { throw "Android build failed for $abi." }
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

if (-not $NoAndroid) {
    Install-AndroidToolchain (-not $NoInstall)
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

if (-not $NoAndroid -and -not $NoAndroidBuild) {
    Build-Android
}

Write-Host ''
Write-Host 'Windows native, .NET, and Android setup complete.' -ForegroundColor Green
Write-Host "  CMake build: $BuildPath"
if (-not $NoAndroid) {
    Write-Host "  Android SDK:  $script:AndroidSdkRoot"
    Write-Host "  Android NDK:  $script:AndroidNdkRoot"
}
