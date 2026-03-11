<#
SYNOPSIS
    Backs up local user profiles and OneDrive for Business content into a single ZIP,
    using Robocopy for staging and comprehensive logging.

DESCRIPTION
    This script:
      1) Creates destination and log directories (if missing).
      2) Enumerates user profiles under C:\Users, excluding common non-user profiles.
      3) Detects OneDrive for Business roots matching the pattern 'OneDrive -*'.
      4) Stages data with Robocopy into a short path (C:\Robocopy) to avoid MAX_PATH issues.
         - Uses /XJ to skip junctions, /ZB for resilient copy, and /MT:16 for multithreaded performance.
      5) Archives the staged content to C:\Temp\<hostname>_User Export.zip via Compress-Archive.
      6) Writes a master log and per-profile Robocopy logs under C:\ProgramData\IntuneEnroll\Logs.
      7) Optionally cleans up the staging directory (controlled by $KeepStaging).

AUTHOR
    Isaac Cooper

DATE
    02-17-26
#>

# ==========================
# CONFIGURATION
# ==========================
$SourcePath       = "C:\Users"
$DestinationDir   = "C:\Temp"
$LogDir           = "C:\ProgramData\IntuneEnroll\Logs"
$Timestamp        = Get-Date -Format 'yyyyMMdd_HHmmss'
$ZipFileName      = "$(hostname)_User Export.zip"
$ZipFilePath      = Join-Path $DestinationDir $ZipFileName

# Keep staging directory for troubleshooting? ($true/$false)
$KeepStaging      = $false

# Short staging path to avoid MAX_PATH issues
$StagingRoot      = "C:\Robocopy"

# Profiles to skip
$ExcludedProfiles = @('Default','Public','defaultuser0','All Users')

# OneDrive Business folder pattern
$OneDriveBusinessPattern = 'OneDrive -*'

# Robocopy options
$RoboOptions = @('/E','/R:1','/W:1','/XJ','/ZB','/MT:16','/NFL','/NDL','/NJH','/NJS','/NP')

# ==========================
# PREP
# ==========================
foreach ($dir in @($DestinationDir, $LogDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
}

# Master log
$LogFile = Join-Path $LogDir "FullUserProfilesBackup_$Timestamp.log"
"=== Full User Profile Backup (Local + OneDrive Business) ===" | Out-File $LogFile -Encoding UTF8
"Start Time: $(Get-Date)"                                       | Out-File $LogFile -Append -Encoding UTF8
"Destination ZIP: $ZipFilePath"                                 | Out-File $LogFile -Append -Encoding UTF8
"Staging Root: $StagingRoot"                                    | Out-File $LogFile -Append -Encoding UTF8
"Excluded Profiles: $($ExcludedProfiles -join ', ')"            | Out-File $LogFile -Append -Encoding UTF8
"OneDrive Pattern: $OneDriveBusinessPattern"                    | Out-File $LogFile -Append -Encoding UTF8
""                                                              | Out-File $LogFile -Append -Encoding UTF8

# Build profile list
$Profiles = Get-ChildItem -Path $SourcePath -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin $ExcludedProfiles }

if (-not $Profiles) {
    Write-Error "No user profiles found to process."
    "ERROR: No user profiles found to process." | Out-File $LogFile -Append -Encoding UTF8
    exit 1
}

# Create staging
New-Item -Path $StagingRoot -ItemType Directory -Force | Out-Null

# ==========================
# COPY (STAGE) CONTENT
# ==========================
$TotalCopiedItems = 0
foreach ($Profile in $Profiles) {
    $ProfileName = $Profile.Name
    "Profile: $ProfileName" | Out-File $LogFile -Append -Encoding UTF8

    # Detect OneDrive Business roots
    $OneDriveRoots = Get-ChildItem -Path $Profile.FullName -Directory -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -like $OneDriveBusinessPattern }

    if ($OneDriveRoots) {
        "  OneDrive roots: $($OneDriveRoots.FullName -join '; ')" | Out-File $LogFile -Append -Encoding UTF8
    } else {
        "  OneDrive roots: (none detected)" | Out-File $LogFile -Append -Encoding UTF8
    }

    # Candidate roots: local profile + OneDrive roots
    $CandidateRoots = @($Profile.FullName)
    if ($OneDriveRoots) { $CandidateRoots += $OneDriveRoots.FullName }

    foreach ($SourceFolder in $CandidateRoots) {
        if (Test-Path $SourceFolder) {
            $rootLabel = if ($SourceFolder -eq $Profile.FullName) { 'Local' } else { 'OneDrive' }
            $DestFolder = Join-Path $StagingRoot (Join-Path $ProfileName $rootLabel)
            New-Item -Path $DestFolder -ItemType Directory -Force | Out-Null

            # Robocopy log
            $RoboLogPath = Join-Path $LogDir "robocopy_${ProfileName}_${rootLabel}_$Timestamp.log"

            # Compose robocopy args
            $Args = @(
                "`"$SourceFolder`"",
                "`"$DestFolder`""
            ) + $RoboOptions + @("/LOG:`"$RoboLogPath`"")

            "    Copy: $SourceFolder -> $DestFolder" | Out-File $LogFile -Append -Encoding UTF8
            & robocopy @Args | Out-Null
            $rc = $LASTEXITCODE

            if ($rc -gt 7) {
                "    WARN: Robocopy exit code $rc for $SourceFolder (see $RoboLogPath)" |
                    Out-File $LogFile -Append -Encoding UTF8
            }

            # Count staged files
            $copied = @(Get-ChildItem -Path $DestFolder -Recurse -File -ErrorAction SilentlyContinue).Count
            $TotalCopiedItems += $copied
            "    Staged files: $copied" | Out-File $LogFile -Append -Encoding UTF8
        }
    }

    "" | Out-File $LogFile -Append -Encoding UTF8
}

if ($TotalCopiedItems -eq 0) {
    Write-Warning "No files were staged. Nothing to archive."
    "WARNING: No files staged—nothing to archive." | Out-File $LogFile -Append -Encoding UTF8
    if (-not $KeepStaging) { Remove-Item -Path $StagingRoot -Recurse -Force -ErrorAction SilentlyContinue }
    exit 2
}

# ==========================
# CREATE ZIP
# ==========================
try {
    Write-Host "Creating ZIP: $ZipFilePath"
    Compress-Archive -Path (Join-Path $StagingRoot '*') `
                     -DestinationPath $ZipFilePath `
                     -CompressionLevel Optimal `
                     -Force `
                     -ErrorAction Stop
    "ZIP created successfully." | Out-File $LogFile -Append -Encoding UTF8
}
catch {
    $msg = "ERROR: Failed to create ZIP file: $($_.Exception.Message)"
    Write-Error $msg
    $msg | Out-File $LogFile -Append -Encoding UTF8
    if (-not $KeepStaging) { Remove-Item -Path $StagingRoot -Recurse -Force -ErrorAction SilentlyContinue }
    exit 3
}

# ==========================
# VERIFY & CLEANUP
# ==========================
if (Test-Path $ZipFilePath) {
    "ZIP Location: $ZipFilePath" | Out-File $LogFile -Append -Encoding UTF8
    "Total files staged: $TotalCopiedItems" | Out-File $LogFile -Append -Encoding UTF8
    "End Time: $(Get-Date)" | Out-File $LogFile -Append -Encoding UTF8
    Write-Host "ZIP file created at: $ZipFilePath"
    Write-Host "Log file created at: $LogFile"

    if (-not $KeepStaging) {
        Remove-Item -Path $StagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit 0
}
else {
    $msg = "ZIP file was not created."
    Write-Error $msg
    $msg | Out-File $LogFile -Append -Encoding UTF8
    if (-not $KeepStaging) { Remove-Item -Path $StagingRoot -Recurse -Force -ErrorAction SilentlyContinue }
    exit 4
}