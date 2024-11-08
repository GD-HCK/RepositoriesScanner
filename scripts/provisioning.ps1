If (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    throw "Run provisioning.ps1 in an administrator PowerShell prompt"
}

$ErrorActionPreference = "Stop"

$installLocation = "C:\packages"

if (!(Test-Path $installLocation)) {
    New-Item -ItemType Directory -Path $installLocation | Out-Null
}

$env:TERM = "xterm-256color"

function Write-GitHubOutput {
    param (
        [Parameter(Position = 0, Mandatory = $true)]
        [string]$Message,
        [string]$Color = $null,
        [switch]$NoNewline
    )

    # Define ANSI escape codes for colors
    $Red = "`e[31m"
    $Cyan = "`e[36m"
    $Green = "`e[32m"
    $Yellow = "`e[33m"
    $Magenta = "`e[35m"
    $Blue = "`e[34m"
    $Reset = "`e[0m"

    switch ($Color) {
        "Red" { $Message = "${Red}$Message${Reset}" }
        "Green" { $Message = "${Green}$Message${Reset}" }
        "Yellow" { $Message = "${Yellow}$Message${Reset}" }
        "Blue" { $Message = "${Blue}$Message${Reset}" }
        "Magenta" { $Message = "${Magenta}$Message${Reset}" }
        "Cyan" { $Message = "${Cyan}$Message${Reset}" }
    }
    if ($NoNewline) {
        [Console]::Write($Message)
    }
    else {
        [Console]::WriteLine($Message)
    }
}

$modules = @(
    [PSCustomObject]@{
        name        = "MYSYS2-mingw64"
        type        = "ScriptBlock"
        ScriptBlock =
        {
            # Add MSYS2 to PATH
            $env:Path += ";C:\msys64\usr\bin;C:\msys64\mingw64\bin"
            [System.Environment]::SetEnvironmentVariable("Path", $env:Path, [System.EnvironmentVariableTarget]::Machine)

            # Update MSYS2
            C:\msys64\msys2_shell.cmd -defterm -no-start -mingw64 -c 'pacman -Sy --noconfirm'
            C:\msys64\msys2_shell.cmd -defterm -no-start -mingw64 -c 'pacman -Su --noconfirm'

            # Install required packages
            C:\msys64\msys2_shell.cmd -defterm -no-start -mingw64 -c 'pacman -S --noconfirm mingw-w64-x86_64-gcc mingw-w64-x86_64-make mingw-w64-x86_64-harfbuzz mingw-w64-x86_64-freetype mingw-w64-x86_64-pkgconf mingw-w64-x86_64-curl mingw-w64-x86_64-mbedtls mingw-w64-x86_64-cmake'

            # Verify installation
            C:\msys64\msys2_shell.cmd -defterm -no-start -mingw64 -c 'gcc --version'
            C:\msys64\msys2_shell.cmd -defterm -no-start -mingw64 -c 'cmake --version'
        }
    }
    [PSCustomObject]@{
        name        = "Botan"
        type        = "ScriptBlock"
        ScriptBlock =
        {
            # Define variables
            Set-Location $installLocation
            $botanArchivePath = ((Invoke-WebRequest -Uri "https://botan.randombit.net/releases" -UseBasicParsing).Links.href | ? { $_ -like "*tar.xz" }) | Sort-Object -Descending | Select-Object -First 1
            $botanUrl = "https://botan.randombit.net/releases/$botanArchivePath"
            $botanTarPath = $botanArchivePath -replace ".xz"
            $botanDir = $botanTarPath -replace ".tar"
            $botanExtractPathTemp = "C:\packages\temp"

            # Download and extract Botan
            Invoke-WebRequest -Uri $botanUrl -OutFile $botanArchivePath
            7z x $botanArchivePath "-o$installLocation" -y
            7z x $botanTarPath "-o$botanExtractPathTemp" -y

            Rename-Item "$botanExtractPathTemp\$botanDir" "$botanExtractPathTemp\Botan"
            Move-Item "$botanExtractPathTemp\Botan" $installLocation
            Remove-Item $botanArchivePath
            Remove-Item $botanTarPath
            Remove-Item $botanExtractPathTemp

            # Configure and build Botan
            Set-Location "$installLocation\Botan"
            Start-Process -FilePath "python" -ArgumentList "configure.py --prefix=Botan --cc=gcc" -Wait

            # Add Botan to PATH
            $env:Path += ";$botanExtractPath\Botan\bin"
            [System.Environment]::SetEnvironmentVariable("Path", $env:Path, [System.EnvironmentVariableTarget]::Machine)
        }
    }
    [PSCustomObject]@{
        name        = "powershell-yaml"
        type        = "PowerShell"
        ScriptBlock = $null
    }
)

Write-GitHubOutput "Installing modules"

foreach ($item in $modules) {

    $name, $type, $ScriptBlock = $null

    $name = $item.name
    $type = $item.type
    $ScriptBlock = $item.ScriptBlock

    Write-GitHubOutput "    --> Installing $name ($type) ..." -Color Green

    switch ($type) {
        "powershell" {
            Install-Module $name -AllowClobber -Force -Scope AllUsers
        }
        "ScriptBlock" {
            Invoke-Command -ScriptBlock $scriptBlock
        }
    }

    switch ($LASTEXITCODE){
        0 { Write-GitHubOutput "    --> $name installed successfully!" -Color Green }
        1 { Write-GitHubOutput "    --> Unable to install $name" -Color Red }
        default { Write-GitHubOutput "    --> Warnings detected when installing $name" -Color Yellow }
    }

    Write-GitHubOutput " "
}

Write-GitHubOutput "Packages installed successfully!" -Color Green
