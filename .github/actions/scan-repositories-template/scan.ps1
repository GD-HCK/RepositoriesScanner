[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string]$GITHUB_API_URL = "https://api.github.com",
    [Parameter(Mandatory)]
    [string[]]$ApiFilters,
    [Parameter(Mandatory)]
    [array]$Languages,
    [Parameter(Mandatory)]
    [int]$RepositorySearchLimit,
    [Parameter(Mandatory)]
    [int]$RepositoriesToCompile,
    [Parameter(Mandatory)]
    [int]$LinesOfCodeForBlackList,
    [Parameter(Mandatory)]
    [string]$RootDirectory
)

# Main script
# Set the GitHub API URL and the Personal Access Token
$Token = $ENV:ACCESSTOKEN

if (-not $Token) {
    Write-Error "Valid GitHub Personal Access Token required"
    break
}

# Set the headers for the API requests
$headers = @{
    "Accept"        = "application/vnd.github.v3+json"
    "Authorization" = "token $token"  # Uncomment if authentication is needed
}

# Function to write console output with colors
function Write-GitHubOutput {
    param (
        [Parameter(Position = 0, Mandatory = $true)]
        [string]$Message,
        [string]$Color = $null,
        [switch]$NoNewline
    )

    $env:TERM = "xterm-256color"
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

# Function to get top repositories based on filters
function Get-TopRepositories {
    param (
        [array]$repositoriesToExclude,
        [Parameter(Mandatory)]
        [string[]]$Apifilters,
        [string]$language,
        [int]$Limit = 10
    )

    $filter = $Apifilters -join " "

    # https://docs.github.com/en/rest/search/search?apiVersion=2022-11-28#search-repositories
    if ($repositoriesToExclude) {
        $repositoriesToExclude = $repositoriesToExclude | ForEach-Object { "NOT $_" }
        $filter += " $repositoriesToExclude"
    }
    $query = "$filter language:$language"
    Write-GitHubOutput "------------------------------------------------------------------------------------------------" -Color Yellow
    Write-GitHubOutput "Searching top $limit repositories with filter: " -Color Magenta -NoNewline; Write-GitHubOutput $query
    $query = [System.Web.HttpUtility]::UrlEncode($query)
    $url = "$GITHUB_API_URL/search/repositories?q=$query&sort=stars&order=desc&per_page=$limit"
    $response = Invoke-RestMethod -Uri $url -Headers $headers
    return $response.items
}

# Function to get commits for a repository
function Get-Commits {
    param (
        [string]$repoFullName,
        [ValidateScript({ $_ -gt 0 })]
        [int]$Limit = 1
    )
    $url = "$GITHUB_API_URL/repos/$repoFullName/commits"
    $response = Invoke-RestMethod -Uri $url -Headers $headers
    return $response[0..($limit - 1)]
}

# Function to check if a file is safe using tip.neiki.dev for scanning
function Invoke-FileScanner {
    param (
        [Parameter(Mandatory)]
        [string]$filePath
    )
    $headers = @{
        'accept'        = 'application/json, text/plain, */*'
        'authorization' = 'guest'
        'content-type'  = 'multipart/form-data; boundary=----WebKitFormBoundaryrhzMRUhynn3t6YPY'
    }

    $formData = @{
        "file" = Get-Item -Path $filePath
    }

    $obj = [PSCustomObject]@{
        IsSafe = $false
        Report = $null
    }

    try {

        $reportId = Invoke-RestMethod -Uri 'https://tip.neiki.dev/api/upload/file/ui' `
            -Headers $headers `
            -Method POST `
            -Form $formData `
            -ContentType "multipart/form-data"
    }
    catch {
        $errorMsgjson = $_
        try {
            $errorMsg = $errorMsgjson | ConvertFrom-Json
            if ($errorMsg.status -eq "ITEM_ALREADY_EXISTS") {
                Write-GitHubOutput "    --> $($errorMsg.error)" -Color Yellow
                $reportId = $errorMsg.optional
            }
            else {
                Write-GitHubOutput "    --> $($errorMsgjson)" -Color Red
                $obj.IsSafe = $false
                $obj.Report = $errorMsgjson
                return $obj
            }
        }
        catch {
            Write-GitHubOutput "    --> Failed to upload file: $($_.Exception.Message)" -Color Red
            $obj.IsSafe = $false
            $obj.Report = "Failed to upload file: $($_.Exception.Message)"
            return $obj
        }
    }

    $headers = @{
        'accept'        = 'application/json, text/plain, */*'
        'authorization' = 'guest'
    }

    $counter = 0

    while ($true) {
        try {
            $scanResult = Invoke-RestMethod -Uri "https://tip.neiki.dev/api/reports/file/$reportId" `
                -Headers $headers `
                -Method GET

            if ($scanResult.pending -or $scanResult.queued) {
                if ($counter % 60 -eq 0) {
                    if ($scanResult.pending) {
                        Write-GitHubOutput "    --> Scan is pending" -Color Yellow
                    }
                    elseif ($scanResult.queued) {
                        Write-GitHubOutput "    --> Scan is queued" -Color Yellow
                    }
                }
                Start-Sleep -Seconds 1
                $counter++
            }
            else {
                if ($scanResult.report.verdict -eq "MALICIOUS") {
                    Write-GitHubOutput "    --> Scan completed with result: $($scanResult.report.verdict)" -Color Red
                    $obj.Report = $scanResult.report
                }
                elseif ($scanResult.report.verdict -eq "SUSPICIOUS") {
                    Write-GitHubOutput "    --> Scan completed with result: $($scanResult.report.verdict)" -Color Yellow
                    $obj.Report = $scanResult.report
                }
                else {
                    Write-GitHubOutput "    --> Scan completed with result: $($scanResult.report.verdict)" -Color Green
                    $obj.IsSafe = $true
                    $obj.Report = $scanResult.report
                }
                break
            }
        }
        catch {
            $errorMsgjson = $_
            try {
                $errorMsg = $errorMsgjson | ConvertFrom-Json
                if ($errorMsg.status -eq "ITEM_NOT_FOUND") {
                    Write-GitHubOutput "    --> $($errorMsg.error)" -Color Yellow
                }
                else {
                    Write-GitHubOutput "    --> $($errorMsgjson)" -Color Red
                    $obj.IsSafe = $false
                    $obj.Report = $errorMsgjson
                    return $obj
                }
            }
            catch {
                Write-GitHubOutput "    --> Failed to retrieve file $($reportId): $($_.Exception.Message)" -Color Red
                $obj.IsSafe = $false
                $obj.Report = "Failed to retrieve file $($reportId): $($_.Exception.Message)"
                return $obj
            }
        }
    }

    return $obj
}

# Function to check if a commit has more than a certain number of lines of code
function Invoke-CommitChecker {
    param (
        [string]$commitSha,
        [string]$repoFullName,
        [int]$LinesOfCodeForBlackList = 10
    )
    $url = "$GITHUB_API_URL/repos/$repoFullName/commits/$commitSha"
    $response = Invoke-RestMethod -Uri $url -Headers $headers
    if ($response.stats.total -gt 0) {
        foreach ($file in $response.files) {
            if (($response.files.patch -split "`n").Count -gt $LinesOfCodeForBlackList) {
                return $true
            }
        }
    }
    return $false
}

# Function to check if the repository has a workable file structure for building
function Test-BuildFiles {
    param (
        [string]$WorkingDirectory,
        [string]$language
    )
    switch ($language) {
        "Python" {
            if (
                ((Get-ChildItem $WorkingDirectory -Filter "*.py" | Where-Object { $_.Name -match "main|build|setup|install" }).Name `
                | Sort-Object -Property Length `
                | Select-Object -First 1) -or
                ((Get-ChildItem $WorkingDirectory -Filter "*.py").Count -eq 1)
            )
            { return $true }
        }
        "C++" {
            if (
                (Test-Path "$WorkingDirectory\Makefile") `
                    -or (Test-Path "$WorkingDirectory\CMakeLists.txt") `
                    -or ((Get-ChildItem $WorkingDirectory -Filter "*.vcxproj").Count -gt 0) `
                    -or ((Get-ChildItem $WorkingDirectory -Filter "*.sln").Count -eq 1)
            ) {
                return $true
            }
        }
        "Go" {
            $files = (Get-ChildItem $WorkingDirectory -Recurse -Filter "*go*" | Where-Object { $_.Name -match ".go|go.mod" })
            if ($files.Count -gt 0) {
                return $true
            }
        }
        "C" {
            if ((Test-Path "$WorkingDirectory\Makefile") -or (Test-Path "$WorkingDirectory\CMakeLists.txt")) {
                return $true
            }
        }
        "Rust" {
            if (Test-Path "$WorkingDirectory\Cargo.toml") {
                return $true
            }
        }
    }

    return $false
}

# Function to build the project
function Invoke-ProjectBuilder {
    param (
        [object]$repo,
        [string]$language,
        [string]$WorkingDirectory
    )

    Set-Location $WorkingDirectory
    $artifacts = @()
    $repoUrl = $repo.clone_url
    $repoName = $repo.name
    $reason = $null
    $RepoWorkingDirectory = "$WorkingDirectory\$repoName"

    Write-GitHubOutput "Working on repository $repoName [$language]" -Color Yellow

    if (-not(Test-Path $repoName)) {
        Write-GitHubOutput "    --> Cloning: $WorkingDirectory\$repoName" -Color Magenta
        $reason = git clone --depth 1 --single-branch --no-tags $repoUrl 2>&1
    }

    # Creating a custom object to store the build status

    $obj = [PSCustomObject]@{
        repoUrl     = $repo.clone_url
        language    = $language
        buildStatus = $null
        ScanStatus  = $null
        reason      = ''
        blacklisted = $null
        artifacts   = $null
    }

    # Check if the repository was cloned successfully
    # If not, return with the reason

    if ($LASTEXITCODE -ne 0) {
        $obj.reason = $reason
        $obj.buildStatus = "CloneFailed"
        $obj.blacklisted = $true
        return $obj
        Write-GitHubOutput "Failed to clone repository $repoName" -Color Red
    }

    # Check if the repository has a typical project structure
    # If not, return with the reason
    if (Test-BuildFiles -WorkingDirectory $RepoWorkingDirectory -language $language) {
        Write-GitHubOutput "    --> building solution" -Color Yellow
    }
    else {
        $reason = "The build files do not conform to a typical $language project structure. Unable to build"
        Write-Warning $reason
        Remove-Item $RepoWorkingDirectory -Recurse -Force
        $obj.reason = $reason
        $obj.buildStatus = "CheckFailed"
        $obj.blacklisted = $true
        return $obj
    }

    Set-Location $RepoWorkingDirectory

    # Set up the safe directory for the git config
    git config --global --add safe.directory $RepoWorkingDirectory

    # Build the project based on the language

    switch ($language) {
        "Python" {
            # Check for main.py or build.py or setup.py or install.py

            [array]$MainPy = (Get-ChildItem -Filter "*.py" | Where-Object { $_.Name -match "main|build|setup|install" }).BaseName `
            | Sort-Object -Property L\ength `
            | Select-Object -First 1

            # If no main.py or build.py or setup.py or install.py found, use the first .py file
            if ($MainPy.Count -eq 0) {
                $MainPy = (Get-ChildItem -Filter "*.py").BaseName
            }

            # Check if there is a requirements.txt file
            # If yes, create an environment and install the requirements

            Write-GitHubOutput "    --> python -m venv venv" -Color Blue
            $reason = python -m venv venv 2>&1

            # Check for both possible activation script paths
            $activateScript = "$RepoWorkingDirectory\venv\Scripts\Activate.ps1"
            if (-Not (Test-Path $activateScript)) {
                $activateScript = "$RepoWorkingDirectory\venv\bin\Activate.ps1"
            }

            Write-GitHubOutput "    --> & $activateScript" -Color Blue
            $reason = & $activateScript 2>&1

            if (Test-Path "requirements.txt") {
                Write-GitHubOutput "    --> pip install -r requirements.txt" -Color Blue
                $reason = pip install -r requirements.txt 2>&1
                $code = $LASTEXITCODE
            }

            # Build the project using pyinstaller

            Write-GitHubOutput "    --> pyinstaller --onefile $MainPy.py" -Color Blue
            $reason = pyinstaller --onefile "$MainPy.py" 2>&1 # Assuming main.py is the entry point

            # Deactivate the virtual environment
            Write-GitHubOutput "    --> deactivate" -Color Blue
            deactivate
            $code = $LASTEXITCODE
            $artifacts += (Get-ChildItem "$RepoWorkingDirectory\dist\$MainPy.exe" -ErrorAction SilentlyContinue).FullName
        }
        "C++" {
            # Check if there are any .cpp files in the repository
            # If yes, build the project using g++
            if (Get-ChildItem $RepoWorkingDirectory -Filter *.cpp) {
                Write-GitHubOutput "    --> g++ -o main.exe *.cpp" -Color Blue
                $reason = g++ -o main.exe *.cpp 2>&1
                $code = $LASTEXITCODE
                $artifacts += (Get-Item "$RepoWorkingDirectory\main.exe" -ErrorAction SilentlyContinue).FullName
            }
            else {
                # Check for .sln files
                # If yes, build the project using MSBuild
                # If no, set up vcpkg and build the project using CMake
                $msbuildFiles = Get-ChildItem $RepoWorkingDirectory -Filter *.sln

                if ($msbuildFiles.Count -eq 0) {
                    $vkpkgRoot = "$RepoWorkingDirectory\vcpkg"
                    $env:VCPKG_ROOT = $vkpkgRoot

                    # Set up vcpkg if vcpkg.json exists

                    if (Test-Path "$RepoWorkingDirectory\vcpkg.json") {
                        # Clone vcpkg and install the required packages
                        if (Test-Path $vkpkgRoot) {
                            Remove-Item $vkpkgRoot -Recurse -Force
                        }
                        Write-GitHubOutput "    --> git clone `"https://github.com/microsoft/vcpkg.git`" $vkpkgRoot" -Color Blue
                        $reason = git clone "https://github.com/microsoft/vcpkg.git" $vkpkgRoot --recurse-submodules 2>&1
                        $reason = & "$vkpkgRoot\bootstrap-vcpkg.bat" -disableMetrics 2>&1
                        Write-GitHubOutput "    --> & `"$vkpkgRoot\vcpkg.exe`" install --triplet x64-windows" -Color Blue
                        $reason = & "$vkpkgRoot\vcpkg.exe" install --triplet x64-windows 2>&1
                        $code = $LASTEXITCODE
                    }

                    if ($LASTEXITCODE -eq 0) {
                        # Configure the project with CMake
                        Write-GitHubOutput "    --> cmake -S . -B build" -Color Blue
                        $reason = cmake -S . -B build 2>&1
                        $code = $LASTEXITCODE
                        if ($LASTEXITCODE -eq 0) { $build = $true }
                    }

                    # If the build failed, remove the build directory and try again
                    if ($code -ne 0) {

                        Remove-Item .\build -Recurse -Force -ErrorAction SilentlyContinue

                        # Configure the project with CMake using the toolchain file
                        @"
# mingw_toolchain.cmake

set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_C_COMPILER "C:/msys64/mingw64/bin/gcc.exe")
set(CMAKE_CXX_COMPILER "C:/msys64/mingw64/bin/g++.exe")

# Add paths to libraries and include directories
set(CMAKE_PREFIX_PATH "C:/msys64/mingw64")
set(CMAKE_LIBRARY_PATH "C:/msys64/mingw64/lib")
set(CMAKE_INCLUDE_PATH "C:/msys64/mingw64/include")

# Add specific libraries if needed
find_library(FREETYPE_LIBRARY freetype PATHS "C:/msys64/mingw64/lib")
find_path(FREETYPE_INCLUDE_DIR freetype PATHS "C:/msys64/mingw64/include/freetype2")

# Debug messages
message(STATUS "FREETYPE_LIBRARY: `${FREETYPE_LIBRARY}")
message(STATUS "FREETYPE_INCLUDE_DIR: `${FREETYPE_INCLUDE_DIR}")

# Set the found paths
set(FREETYPE_LIBRARY `${FREETYPE_LIBRARY} CACHE STRING "Freetype library")
set(FREETYPE_INCLUDE_DIR `${FREETYPE_INCLUDE_DIR} CACHE STRING "Freetype include directory")
"@ | Out-File "$RepoWorkingDirectory\mingw_toolchain.cmake"

                        # Configure the project with CMake using the toolchain file
                        Write-GitHubOutput "    --> cmake -S . -B build -G `"MinGW Makefiles`" -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++ -DCMAKE_TOOLCHAIN_FILE=`"mingw_toolchain.cmake`"" -Color Blue
                        $reason = cmake -S . -B build -G "MinGW Makefiles" -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++ -DCMAKE_TOOLCHAIN_FILE="$RepoWorkingDirectory\mingw_toolchain.cmake" 2>&1
                        $code = $LASTEXITCODE
                        if ($LASTEXITCODE -eq 0) { $build = $true }
                    }

                    if ($build -and $code -eq 0) {
                        # Build the project with CMake
                        Write-GitHubOutput "    --> cmake --build build --config Release" -Color Blue
                        $reason = cmake --build build --config Release 2>&1
                        $code = $LASTEXITCODE

                        # Check if the build was successful
                        # If yes, get the artifacts
                        # If no, set the build status to failed
                        if ($LASTEXITCODE -eq 0) {
                            if (Test-Path $vkpkgRoot) {
                                # Run CMake to configure the project with vcpkg toolchain
                                Write-GitHubOutput "    --> cmake -DCMAKE_TOOLCHAIN_FILE=`"$vkpkgRoot\scripts\buildsystems\vcpkg.cmake`" ." -Color Blue
                                $reason = cmake -DCMAKE_TOOLCHAIN_FILE="$vkpkgRoot\scripts\buildsystems\vcpkg.cmake" build 2>&1
                                $code = $LASTEXITCODE
                            }
                        }
                        $artifacts += (Get-Item "$RepoWorkingDirectory\build\main.exe" -ErrorAction SilentlyContinue).FullName
                    }
                }
                else {
                    # Build the project using MSBuild
                    foreach ($file in $msbuildFiles) {
                        Write-GitHubOutput "    --> msbuild `"$($file.FullName)`" -property:Configuration=Release" -Color Blue
                        $reason = msbuild $file.FullName -property:Configuration=Release 2>&1
                        $code = $LASTEXITCODE
                        $artifacts += (Get-Item "$RepoWorkingDirectory\Release\*.exe" -ErrorAction SilentlyContinue).FullName
                    }
                }
            }
        }
        "Go" {
            # Build the Go project and specify the output directory
            $files = (Get-ChildItem $RepoWorkingDirectory -Recurse -Filter "go.mod")
            # Check if there is a go.mod file
            # If yes, build the project using go build
            if ($files.Count -gt 0) {
                foreach ($file in $files) {
                    $dir = $file.Directory.FullName
                    Set-Location $dir
                    $outputFile = "$dir\dist\main.exe"
                    if (-not(Test-Path "$dir\dist")) {
                        New-Item "$dir\dist" -ItemType Directory | Out-Null
                    }
                    Write-GitHubOutput "    --> go build -o $outputFile" -Color Blue
                    $reason = go build -o $outputFile 2>&1
                    $code = $LASTEXITCODE
                    $artifacts += (Get-Item $outputFile -ErrorAction SilentlyContinue).FullName
                }
            }
            else {
                $outputFile = "$RepoWorkingDirectory\dist\main.exe"
                if (-not(Test-Path "$RepoWorkingDirectory\dist")) {
                    New-Item "$RepoWorkingDirectory\dist" -ItemType Directory | Out-Null
                }
                Write-GitHubOutput "    --> go build -o $outputFile" -Color Blue
                $reason = go build -o $outputFile 2>&1
                $code = $LASTEXITCODE
                $artifacts += (Get-Item $outputFile -ErrorAction SilentlyContinue).FullName
            }
        }
        "C" {
            # Check if there are any .c files in the repository
            # If yes, build the project using gcc
            Write-GitHubOutput "    --> gcc -o `"$RepoWorkingDirectory\Release\$($file.BaseName).exe`" *.c" -Color Blue
            $reason = gcc -o "$RepoWorkingDirectory\Release\$($file.BaseName).exe" *.c 2>&1
            $code = $LASTEXITCODE
            $artifacts += (Get-ChildItem "$RepoWorkingDirectory\Release\*.exe" -ErrorAction SilentlyContinue).FullName
        }
        "Rust" {
            # Check if there is a Cargo.toml file
            # If yes, build the project using cargo
            Write-GitHubOutput "    --> cargo build --release" -Color Blue
            $reason = cargo build --release 2>&1
            $code = $LASTEXITCODE
            Get-ChildItem "$RepoWorkingDirectory\" -Recurse
            $artifacts += (Get-Item "$RepoWorkingDirectory\target\release\*.exe" -ErrorAction SilentlyContinue).FullName
        }
    }

    # Check if the build was successful
    #   --> If no, set the build status to failed
    #   --> If yes, scan the artifacts
    #       --> If the scan fails, set the scan status to failed and blacklisted status to true
    #       --> If the scan is successful, set the scan status to succeeded and blacklisted status to false

    if ($code -ne 0) {
        Write-GitHubOutput "    --> Failed to build $repoName [$language]" -Color Red
        $obj.reason = $reason
        $obj.buildStatus = "BuildFailed"
        $obj.blacklisted = $true
    }
    else {
        $scanFailed = $false

        if ($artifacts.Count -eq 0) {
            Write-GitHubOutput "    --> No artifacts found for $repoName" -Color Red
        }
        else {
            foreach ($artifact in $artifacts) {
                Write-GitHubOutput "    --> Scanning artifact $artifact" -Color blue
                $ScanResult = Invoke-FileScanner -filePath $artifact
                if (!$ScanResult.IsSafe) {
                    $scanFailed = $true
                    break
                }
            }
        }

        if ($scanFailed) {
            $obj.reason = "Scan verdict reported as $($ScanResult.Report.Verdict), please review"
            $obj.buildStatus = "BuildSucceeed"
            $obj.ScanStatus = "ScanFailed"
            $obj.blacklisted = $true
            $obj.artifacts = $artifacts
            Write-GitHubOutput "    --> Build of $repoName succedeed but scan failed!" -Color Red
        }
        else {
            $obj.reason = 'Build and scan completed successfully'
            $obj.buildStatus = "BuildSucceeed"
            $obj.ScanStatus = "ScanSucceeded"
            $obj.blacklisted = $false
            $obj.artifacts = $artifacts
            Write-GitHubOutput "    --> Build of $repoName succedeed!" -Color Green
        }
    }

    Set-Location $WorkingDirectory

    # Remove the repository directory
    Remove-Item $RepoWorkingDirectory -Recurse -Force

    return $obj
}

$publishedArtifacts = "$rootDirectory\Artifacts"
$SuccessfulBuildsPath = "$rootDirectory\SuccessfulBuilds.json"
$FailedBuildsPath = "$rootDirectory\FailedBuilds.json"

$AllRepositories = @()

# Set the directories and files to exclude from building
$FoldersFilesToExclude = @($publishedArtifacts, $SuccessfulBuildsPath, $FailedBuildsPath)

# Create the root directory if it does not exist
if (-not(Test-Path $rootDirectory)) {
    New-Item $rootDirectory -ItemType Directory | Out-Null
}

Set-Location $rootDirectory

Write-GitHubOutput "Cleaning up $rootDirectory" -Color Yellow
Get-ChildItem $rootDirectory | Where-Object { $_.FullName -notin $FoldersFilesToExclude } | Foreach-Object { Remove-Item -Recurse -Force $_.FullName }
New-Item $publishedArtifacts -ItemType Directory -ErrorAction SilentlyContinue | Out-Null

# Loop through the languages and search for repositories
foreach ($language in $languages) {
    $repositoriesToKeep = @()
    $repositoriesToExclude = @()
    try {
        # Get the top repositories based on the filters
        $repos = Get-TopRepositories `
            -Apifilters $Apifilters `
            -language $language `
            -Limit $RepositorySearchLimit `
            -repositoriesToExclude $repositoriesToExclude

        # Loop through the repositories
        foreach ($repo in $repos) {

            # Check if the repository has already been built successfully
            if (Test-Path $SuccessfulBuildsPath) { $SuccessList = Get-Content $SuccessfulBuildsPath | ConvertFrom-Json }

            # Check if the repository has already failed to build
            if (Test-Path $FailedBuildsPath) { $FailedList = Get-Content $FailedBuildsPath | ConvertFrom-Json }

            Write-GitHubOutput "### $($repo.full_name) ###" -Color Yellow
            if ($repositoriesToKeep.Count -lt $RepositoriesToCompile) {
                if ($SuccessList -and $SuccessList.repoUrl -contains $repo.clone_url) {
                    Write-GitHubOutput "    --> Skipping $($repo.full_name) as it was already built successfully" -Color Yellow
                    continue
                }
                elseif ($FailedList -and $FailedList.repoUrl -contains $repo.clone_url) {
                    Write-GitHubOutput "    --> Skipping $($repo.full_name) as it failed to build" -Color Yellow
                    continue
                }

                # Get the commits for the repository
                $repoFullName = $repo.full_name
                $repoUrl = $repo.html_url
                $Commits = $null
                [array]$Commits = Get-Commits -repoFullName $repoFullName -Limit 5

                # Check if the repository has commits

                if ($Commits.Count -gt 0) {

                    $GoodCommits = 0

                    # Loop through the commits
                    # Check if the commit has more than a certain number of lines of code
                    # If yes, increment the GoodCommits counter
                    foreach ($commit in $Commits) {
                        Write-GitHubOutput "    --> Checking commit $($commit.commit.author.date.ToString("[dd/MM/yyyy HH:ss]")) - $($commit.sha)"
                        if (Invoke-CommitChecker -commitSha $commit.sha -repoFullName $repoFullName -LinesOfCode $LinesOfCodeForBlackList) {
                            $GoodCommits++
                        }
                    }

                    # If the GoodCommits counter is greater than 0, add the repository to the list of repositories to keep
                    if ($GoodCommits -gt 0) {
                        Write-GitHubOutput "    --> Check matched for $repoFullName! " -Color Green
                        $AllRepositories += [PSCustomObject]@{
                            Language   = $language
                            Repository = $repo
                        }
                        $repositoriesToKeep += $repoFullName
                    }
                    else {
                        Write-GitHubOutput "    --> Check failed for $repoFullName" -Color Red
                    }
                }
                $repositoriesToExclude += $repoFullName
            }
            else {
                break
            }
        }
    }
    catch {
        Write-GitHubOutput ($errormsg.ErrorDetails.Message) -Color Red
        continue
    }
}

# Loop through the repositories and build them
foreach ($repo in $AllRepositories) {
    $language = $repo.language
    $WorkingDirectory = "$rootDirectory\$language"
    New-Item $WorkingDirectory -ItemType Directory -ErrorAction SilentlyContinue | Out-Null

    # Build the project
    $BuildResult = Invoke-ProjectBuilder -repo $repo.repository -language $repo.language -WorkingDirectory $WorkingDirectory

    # Check if the build was successful
    #   --> If yes, add the repository to the successful builds log
    #   --> If no, add the repository to the failed builds log
    if ($BuildResult.blacklisted) {
        Write-GitHubOutput "    --> Adding failed build to log" -Color Red
        $BuildResult.reason = $BuildResult.reason -join "`n"
        if (Test-Path $FailedBuildsPath) { $FailedList = Get-Content $FailedBuildsPath | ConvertFrom-Json } else { $FailedList = @() }
        [array]$FailedList += $BuildResult
        $FailedList | ConvertTo-Json -Depth 6 | Out-File -Path $FailedBuildsPath
    }
    else {
        Write-GitHubOutput "    --> Adding successful build to log" -Color Green
        if (Test-Path $SuccessfulBuildsPath) { $SuccessList = Get-Content $SuccessfulBuildsPath | ConvertFrom-Json } else { $SuccessList = @() }
        [array]$SuccessList += $BuildResult
        $SuccessList | ConvertTo-Json -Depth 6 | Out-File -Path $SuccessfulBuildsPath
    }
}

$LASTEXITCODE = 0