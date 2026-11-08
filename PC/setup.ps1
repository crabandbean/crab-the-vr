# One-click PC setup for Crab the VR.
#
# Double-click it (or the .cmd next to it). It checks for the free C++ build
# tools, installs them with winget if they are missing, gets the OpenVR headers,
# builds the SteamVR driver and copies it into SteamVR.
#
# It writes nothing outside this PC folder except the installed driver.

$ErrorActionPreference = 'Stop'

function Write-Step([string]$text) {
    Write-Host ""
    Write-Host "== $text ==" -ForegroundColor Cyan
}

function Stop-WithMessage([string]$text) {
    Write-Host ""
    Write-Host $text -ForegroundColor Red
    Read-Host "Press Enter to close"
    exit 1
}

function Find-Tool([string]$name, [string[]]$fallbacks) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($path in $fallbacks) {
        if ($path -and (Test-Path $path)) { return $path }
    }
    return $null
}

function Find-VSInstall {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { return '' }
    $path = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($path) { return $path.Trim() }
    return ''
}

Write-Host "Crab the VR - PC setup" -ForegroundColor Green
Write-Host "This builds the SteamVR driver and installs it for you."

$pcRoot = $PSScriptRoot

# ---------------------------------------------------------------- build tools

$git = Find-Tool 'git' @(
    "$env:ProgramFiles\Git\cmd\git.exe",
    "${env:ProgramFiles(x86)}\Git\cmd\git.exe",
    "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe"
)
$cmake = Find-Tool 'cmake' @(
    "$env:ProgramFiles\CMake\bin\cmake.exe",
    "${env:ProgramFiles(x86)}\CMake\bin\cmake.exe"
)
$vsPath = Find-VSInstall

$missing = @()
if (-not $git) { $missing += 'Git' }
if (-not $cmake) { $missing += 'CMake' }
if (-not $vsPath) { $missing += 'Visual Studio C++ build tools' }

if ($missing.Count -gt 0) {
    Write-Step "Missing: $($missing -join ', ')"

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Stop-WithMessage @"
The free C++ build tools are not installed and winget is not available.

Install them once from Microsoft:
  https://aka.ms/vs/17/release/vs_BuildTools.exe
  (choose "Desktop development with C++")

Then install Git and CMake, or just run this setup again.
"@
    }

    $answer = Read-Host "Install the missing build tools now with winget? This can take a while. (Y/n)"
    if ($answer -match '^n') {
        Stop-WithMessage "Setup stopped. See PC/README.md for the manual steps."
    }

    if (-not $git) {
        Write-Step "Installing Git"
        & winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { Stop-WithMessage "Git could not be installed." }
    }

    if (-not $cmake) {
        Write-Step "Installing CMake"
        & winget install --id Kitware.CMake -e --source winget --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { Stop-WithMessage "CMake could not be installed." }
    }

    if (-not $vsPath) {
        Write-Step "Installing the Visual Studio C++ build tools (large download)"
        & winget install --id Microsoft.VisualStudio.2022.BuildTools -e --source winget --accept-package-agreements --accept-source-agreements --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
        if ($LASTEXITCODE -ne 0) { Stop-WithMessage "The C++ build tools could not be installed." }
    }

    # winget updates the PATH for new processes; refresh it here.
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path', 'User')

    $git = Find-Tool 'git' @(
        "$env:ProgramFiles\Git\cmd\git.exe",
        "${env:ProgramFiles(x86)}\Git\cmd\git.exe",
        "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe"
    )
    $cmake = Find-Tool 'cmake' @(
        "$env:ProgramFiles\CMake\bin\cmake.exe",
        "${env:ProgramFiles(x86)}\CMake\bin\cmake.exe"
    )
    $vsPath = Find-VSInstall

    if (-not $git -or -not $cmake -or -not $vsPath) {
        Stop-WithMessage "The tools were installed but are not visible yet. Close this window, open a new one and run Setup again."
    }
}

Write-Step "Using Git, CMake and the Visual Studio C++ tools"

# ---------------------------------------------------------------- OpenVR

$openVR = Join-Path $pcRoot 'third_party\openvr'
$driverHeader = Join-Path $openVR 'headers\openvr_driver.h'

if (-not (Test-Path $driverHeader)) {
    Write-Step "Downloading the OpenVR headers"
    if (Test-Path $openVR) { Remove-Item -Recurse -Force $openVR }
    New-Item -ItemType Directory -Force (Split-Path $openVR) | Out-Null
    & $git clone --depth 1 https://github.com/ValveSoftware/openvr $openVR
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $driverHeader)) {
        Stop-WithMessage "Could not download OpenVR. Check your internet connection and try again."
    }
}

# ---------------------------------------------------------------- build

Write-Step "Building the SteamVR driver"
Push-Location $pcRoot
& $cmake -S driver -B build -A x64
if ($LASTEXITCODE -ne 0) {
    Pop-Location
    Stop-WithMessage "CMake could not configure the driver. The messages above show why."
}

& $cmake --build build --config Release
$buildCode = $LASTEXITCODE
Pop-Location

if ($buildCode -ne 0) {
    Stop-WithMessage "The driver did not build. The compiler errors above show why."
}

$dll = Join-Path $pcRoot 'build\Release\driver_joyvr.dll'
if (-not (Test-Path $dll)) {
    $found = Get-ChildItem -Path (Join-Path $pcRoot 'build') -Recurse -Filter 'driver_joyvr.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) {
        $dll = $found.FullName
    } else {
        Stop-WithMessage "The build finished but driver_joyvr.dll was not found."
    }
}

# ---------------------------------------------------------------- SteamVR

function Find-SteamVR {
    $candidates = @()

    $steamReg = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction SilentlyContinue
    if ($steamReg -and $steamReg.SteamPath) {
        $steam = $steamReg.SteamPath -replace '/', '\'
        $candidates += (Join-Path $steam 'steamapps\common\SteamVR')
    }

    $candidates += @(
        'C:\Program Files (x86)\Steam\steamapps\common\SteamVR',
        'C:\Program Files\Steam\steamapps\common\SteamVR',
        'D:\Steam\steamapps\common\SteamVR',
        'D:\SteamLibrary\steamapps\common\SteamVR',
        'E:\SteamLibrary\steamapps\common\SteamVR'
    )

    foreach ($candidate in $candidates) {
        if (Test-Path (Join-Path $candidate 'bin\win64\vrserver.exe')) {
            return $candidate
        }
    }
    return ''
}

Write-Step "Installing into SteamVR"
$steamVR = Find-SteamVR
if (-not $steamVR) {
    Write-Host "SteamVR was not found in the usual places."
    $entered = Read-Host "Paste your SteamVR folder (the one with bin\win64\vrserver.exe), or leave empty to stop"
    if ($entered) { $steamVR = $entered.Trim('"') }
}

if (-not $steamVR -or -not (Test-Path (Join-Path $steamVR 'bin\win64\vrserver.exe'))) {
    Stop-WithMessage "SteamVR was not found. Install SteamVR from Steam, then run Setup again."
}

$driverRoot = Join-Path $steamVR 'drivers\joyvr'
$binFolder = Join-Path $driverRoot 'bin\win64'
New-Item -ItemType Directory -Force -Path $binFolder | Out-Null

Copy-Item -Force (Join-Path $pcRoot 'driver\driver.vrdrivermanifest') $driverRoot
Copy-Item -Force $dll (Join-Path $binFolder 'driver_joyvr.dll')

Write-Step "Done"
Write-Host "The driver is installed at: $driverRoot"
Write-Host ""
Write-Host "Restart SteamVR. It will list a headset called 'Crab the VR'." -ForegroundColor Green
Write-Host "Then open the phone app, Link tab, find this PC and tap Enter VR."
Write-Host ""
Read-Host "Press Enter to close"
