<#PSScriptInfo
.VERSION 1.15
.GUID dd04650b-78dc-4761-89bf-b6eeee74094c
.AUTHOR ZenitH-AT
.LICENSEURI https://raw.githubusercontent.com/ZenitH-AT/nvidia-update/main/LICENSE
.PROJECTURI https://github.com/ZenitH-AT/nvidia-update
.DESCRIPTION Checks for a new version of the NVIDIA driver, downloads and installs it. 
#>
param (
	[switch] $Force = $false, # Install the driver even if the latest driver is already installed
	[switch] $Clean = $false, # Remove any existing driver and its configuration data
	[switch] $Msi = $false, # Enable message-signalled interrupts (MSI) after driver installation (must be enabled every time); requires elevation
	[switch] $Schedule = $false, # Register a scheduled task to run this script weekly; arguments passed alongside this will be appended to the scheduled task action
	[string] $GpuId = $null, # Manually specify product family (GPU) ID rather than determine automatically
	[string] $OsId = $null, # Manually specify operating system ID rather than determine automatically
	[switch] $Desktop = $false, # Override the desktop/notebook check and download the desktop driver; useful when using an external GPU or unable to find a driver
	[switch] $Notebook = $false, # Override the desktop/notebook check and download the notebook driver
	[string] $DownloadDirectory = "$($env:TEMP)\NVIDIA", # The directory where the script will download and extract the driver package;
	[switch] $KeepDownload = $false, # Don't delete the downloaded driver package after installation (or if an error occurred)
	[string] $AjaxDriverServiceUrl = "https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php" # AjaxDriverService URL; e.g., replace .com with .com to solve connectivity issues
)

## Constant variables and functions
New-Variable -Name "configFilePath" -Value "$($PSScriptRoot)\optional-components.cfg" -Option Constant
New-Variable -Name "currentReleaseVersion" -Value ([System.Version]::New("$(Test-ScriptFileInfo -Path $PSCommandPath | ForEach-Object VERSION)")) -Option Constant
New-Variable -Name "scriptRepoUri" -Value "$(Test-ScriptFileInfo -Path $PSCommandPath | ForEach-Object PROJECTURI)" -Option Constant
New-Variable -Name "defaultScriptFileName" -Value "nvidia-update.ps1" -Option Constant
New-Variable -Name "gpuDataFileUrl" -Value "https://raw.githubusercontent.com/ZenitH-AT/nvidia-data/main/gpu-data.json" -Option Constant
New-Variable -Name "osDataFileUrl" -Value "https://raw.githubusercontent.com/ZenitH-AT/nvidia-data/main/os-data.json" -Option Constant
New-Variable -Name "driverLookupUri" -Value "$($AjaxDriverServiceUrl)?func=DriverManualLookup&pfid={0}&osID={1}&dch={2}" -Option Constant
New-Variable -Name "osBits" -Value "$(if ([Environment]::Is64BitOperatingSystem) { 64 } else { 32 })" -Option Constant
New-Variable -Name "notebookChassisTypes" -Value @(8, 9, 10, 11, 12, 14, 18, 21, 31, 32) -Option Constant
New-Variable -Name "dchSupportedOsIds" -Value @(56, 57, 135) -Option Constant
New-Variable -Name "dataDividends" -Value @(1, 1024, 1048576) -Option Constant
New-Variable -Name "dataUnits" -Value @("B", "KiB", "MiB") -Option Constant

function Remove-Temp {
	if (-not (Test-Path $DownloadDirectory)) {
		return
	}

	try {
		Get-ChildItem -Path $DownloadDirectory -Exclude "$(if ($KeepDownload) { "*exe" })" | Remove-Item -Recurse -Force -ErrorAction Ignore
	}
	catch {
		Write-Host "Some files located at $($DownloadDirectory) could not be deleted, you may want to remove them manually later." -ForegroundColor Gray
	}
}

function Write-ExitError {
	param (
		[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ErrorMessage,
		[switch] $RemoveTemp
	)

	Write-Host $ErrorMessage -ForegroundColor Yellow

	if ($RemoveTemp) {
		Write-Host "`nRemoving temporary files..."
		Remove-Temp
		Write-Host # Only write new line after any potential error message from Remove-Temp
	}

	Write-Host "Press any key to exit..."

	$host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

	exit
}

function Write-ExitTimer {
	param (
		[ValidateNotNullOrEmpty()] [int] $Milliseconds = 5000
	)

	$seconds = [System.Math]::Floor($Milliseconds / 1000)

	Write-Host "`nExiting script in $($seconds) seconds..."
	Start-Sleep -Milliseconds $Milliseconds

	exit
}

function Write-Time {
	Write-Host "`n[$("{0:HH:mm:ss}" -f (Get-Date))] " -NoNewline
}

function Get-DecimalsAndUnitIndex {
	param (
		[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [double] $Bytes
	)

	# 2: MiB; 1: KiB; 0: B
	$unitIndex = 3

	# Return no decimals and bytes unit index if bytes less than 1 KiB
	if ($Bytes -ge $dataDividends[1]) {
		# Determine the appropriate number of decimals and unit index
		while ($unitIndex-- -gt 0) {
			$convertedBytes = $Bytes / $dataDividends[$unitIndex]
			$decimals = 3 - [System.Math]::Round($convertedBytes).ToString().Length

			if ([System.Math]::Floor($convertedBytes) -gt 0) {
				return $decimals, $unitIndex
			}
		}
	}

	return 0, 0
}

function Get-ConvertedBytesString {
	param (
		[Parameter(Position = 0, Mandatory)] [ValidateNotNullOrEmpty()] [double] $Bytes,
		[Parameter(Position = 1, Mandatory)] [ValidateNotNullOrEmpty()] [int] $Decimals,
		[Parameter(Position = 2, Mandatory)] [ValidateNotNullOrEmpty()] [string] $UnitIndex
	)

	return [System.Math]::Round(($Bytes / $dataDividends[$UnitIndex]), $Decimals).ToString("0.$("0" * $Decimals)")
}

function Get-WebFile {
	param (
		[Parameter(Position = 0, Mandatory)] [ValidateNotNullOrEmpty()] [string] $Url,
		[Parameter(Position = 1, Mandatory)] [ValidateNotNullOrEmpty()] [string] $TargetPath
	)

	# Create runspace pool and runspace for download
	$pool = [RunspaceFactory]::CreateRunspacePool(1, [Environment]::ProcessorCount + 1)
	$pool.ApartmentState = "MTA"
	$pool.Open()

	$runspace = [PowerShell]::Create()
	$runspace.RunspacePool = $pool

	# Handle download in a script block
	$totalBytes = $false
	$downloadedBytes = 0
	$downloadHadError = $false

	$scriptBlock = {
		param (
			[Parameter(Position = 0, Mandatory)] [ValidateNotNullOrEmpty()] [string] $parentPid,	
			[Parameter(Position = 1, Mandatory)] [ValidateNotNullOrEmpty()] [string] $Url,
			[Parameter(Position = 2, Mandatory)] [ValidateNotNullOrEmpty()] [string] $TargetPath,
			[Parameter(Position = 3, Mandatory)] [ValidateNotNullOrEmpty()] [ref] [int] $TotalBytes,
			[Parameter(Position = 4, Mandatory)] [ValidateNotNullOrEmpty()] [ref] [int] $DownloadedBytes,
			[Parameter(Position = 5, Mandatory)] [ValidateNotNullOrEmpty()] [ref] [bool] $DownloadHadError
		)

		try {
			$response = [System.Net.WebRequest]::Create($url).GetResponse()
			$TotalBytes.Value = $response.get_ContentLength()
			$responseStream = $response.GetResponseStream()
			$targetStream = [System.IO.FileStream]::New($TargetPath, "Create")
			$buffer = [byte[]]::New(65536) # 64 KiB

			# Download file until completion or parent process killed
			do {
				$count = $responseStream.Read($buffer, 0, $buffer.Length)

				$targetStream.Write($buffer, 0, $count)

				$DownloadedBytes.Value += $count
			} while ($count -gt 0 -and (Get-Process -Id $parentPid -ErrorAction Ignore))
		}
		catch {
			$DownloadHadError.Value = $true
		}
		finally {
			# Close streams and exit (complete runspace)
			if ($responseStream) {
				$responseStream.Dispose()
			}

			if ($targetStream) {
				$targetStream.Flush()
				$targetStream.Close()
				$targetStream.Dispose()
			}

			exit
		}
	}

	$runspace.AddScript($scriptblock) > $null
	$runspace.AddArgument($PID) > $null
	$runspace.AddArgument($Url) > $null
	$runspace.AddArgument($TargetPath) > $null
	$runspace.AddArgument([ref]$totalBytes) > $null
	$runspace.AddArgument([ref]$downloadedBytes) > $null
	$runspace.AddArgument([ref]$downloadHadError) > $null

	$download = [PSCustomObject]@{ Status = $runspace.BeginInvoke() }

	# Wait for total bytes to be set in script block; timeout being reached in script block will cause exception and completed status
	while (-not $totalBytes) {
		Start-Sleep -Milliseconds 100

		if ($downloadHadError) {
			break
		}
	}

	# Check and display download progress every 200 milliseconds until runspace completion
	$activity = "Downloading file to `"$($TargetPath)`"..."
	$decimals, $unitIndex = Get-DecimalsAndUnitIndex $totalBytes
	$totalString = Get-ConvertedBytesString $totalBytes $decimals $unitIndex

	while ($download.Status.IsCompleted -eq $false) {
		$downloadedString = Get-ConvertedBytesString $downloadedBytes $decimals $unitIndex
		$status = "Downloaded $($downloadedString) of $($totalString) $($dataUnits[$unitIndex])"
		$percentComplete = ($downloadedBytes / $totalBytes) * 100

		Write-Progress -Activity $activity -Status $status -PercentComplete $percentComplete
		Start-Sleep -Milliseconds 200
	}

	Write-Progress -Activity $activity -Completed

	# Dispose of runspace pool
	$pool.Close()
	$pool.Dispose()

	# Show error and exit if download failed
	if ($downloadHadError) {
		# Remove partially downloaded file if present
		if (Test-Path $TargetPath) {
			Remove-Item $TargetPath -Force
		}

		Write-Time
		Write-ExitError "Download failed. Please try running this script again."
	}
}

function Get-GpuData {
	$gpus = @(Get-CimInstance Win32_VideoController | Select-Object PNPDeviceID, Name, DriverVersion)

	foreach ($gpu in $gpus) {
		$gpuName = $gpu.Name

		if ($gpuName -match "^NVIDIA") {
			# Clean GPU name, accounting for card variants (e.g., 1060 6GB, 760Ti (OEM))
			if (-not ($gpuName -match "(?<=NVIDIA )(.*(?= [0-9]+GB)|.*(?= with Max-Q Design)|.*(?= \([A-Z]+\))|.*)")) {
				Write-ExitError "`nUnrecognised GPU name $($gpuName). This should not happen."
			}

			$gpuName = $Matches[0].Replace("Super", "SUPER").Trim()
			$currentDriverVersion = ($gpu.DriverVersion.Replace(".", "")[-5..-1] -join "").Insert(3, ".")
			$isNotebook = [bool](Get-CimInstance -ClassName Win32_SystemEnclosure).ChassisTypes.Where({ $_ -in $notebookChassisTypes })
			$pnpDeviceId = $gpu.PNPDeviceID

			break
		}
	}

	if (-not $currentDriverVersion) {
		Write-ExitError "`nUnable to detect a compatible NVIDIA device."
	}

	return $gpuName, $currentDriverVersion, $isNotebook, $pnpDeviceId
}

function Get-DriverLookupParameters {
	param (
		[Parameter(Position = 0, Mandatory)] [ValidateNotNullOrEmpty()] [string] $GpuName,
		[Parameter(Position = 1, Mandatory)] [ValidateNotNullOrEmpty()] [bool] $IsNotebook
	)

	$gpuType = if ($Desktop -or -not ($Notebook -or $IsNotebook)) { "desktop" } else { "notebook" }

	# Determine product family (GPU) ID
	$gpuId = $GpuId # Initially assume user manually specified GPU ID

	if (!$GpuId) {
		try {
			$gpuId = (Invoke-RestMethod -Uri $gpuDataFileUrl | ConvertTo-Json | ConvertFrom-Json).$gpuType.$GpuName
		}
		catch {
			Write-ExitError "`nUnable to retrieve GPU data. Please try running this script again."
		}
	}

	if (-not $gpuId) {
		Write-ExitError "`nUnable to determine GPU product family ID. This should not happen."
	}

	# Determine operating system version
	$osVersion = "$([Environment]::OSVersion.Version.Major).$([Environment]::OSVersion.Version.Minor)"

	# Determine operating system ID
	$osId = $OsId # Initially assume user manually specified OS ID

	if (!$OsId) {
		try {
			$osData = Invoke-RestMethod -Uri $osDataFileUrl
		}
		catch {
			Write-ExitError "Unable to retrieve OS data. Please try running this script again."
		}

		foreach ($os in $osData) {
			# TODO: Improve Windows 11 detection (shouldn't matter for now since Windows 10 64-bit and Windows 11 use the same drivers)
			if ($os.code -eq $osVersion -and $os.name -match $osBits) {
				$osId = $os.id

				break
			}
		}
	}

	if (-not $osId) {
		Write-ExitError "`nCould not find a driver supported by your operating system."
	}

	# Check if DCH supported and if using DCH driver
	$dchSupported = $osId -in $dchSupportedOsIds
	$dch = $osId -in $dchSupportedOsIds -and (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm" -Name "DCHUVen" -ErrorAction Ignore)

	return $gpuId, $osId, $dchSupported, $dch
}

function Get-DriverDownloadInfo {
	param (
		[Parameter(Position = 0, Mandatory)] [ValidateNotNullOrEmpty()] [string] $GpuId,
		[Parameter(Position = 1, Mandatory)] [ValidateNotNullOrEmpty()] [string] $OsId,
		[Parameter(Position = 2, Mandatory)] [ValidateNotNullOrEmpty()] [bool] $Dch
	)

	try {
		$payload = Invoke-RestMethod -Uri ($driverLookupUri -f $GpuId, $OsId, [int]$Dch)

		if ($payload.Success -ne 1) {
			return $null
		}

		return $payload.IDS[0].downloadInfo
	}
	catch {
		Write-ExitError "Unable to get driver download info. Please try running this script again."
	}
}

function Get-RegistryValueData {
	param(
		[Parameter(Position = 0, Mandatory)] [ValidateNotNullOrEmpty()] [string] $Key,
		[Parameter(Position = 1, Mandatory)] [ValidateNotNullOrEmpty()] [string] $Value,
		[Parameter(Position = 2)] [string] $DataSuffix
	)

	if (Get-ItemProperty $Key $Value -ErrorAction Ignore) {
		return "$(Get-ItemPropertyValue -Path $Key -Name $Value)$($DataSuffix)"
	}

	return $null
}

function Show-LoadingAnimation {
	param (
		[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] $Process
	)

	$loadingAnimation = @("|", "/", "-", "\")
	
	# Write two spaces to account for backspace (`b) character
	Write-Host "  " -NoNewline

	# Show loading animation until the process returns an exit code
	while ($Process.ExitCode -ne 0) {
		# Throw an error if the process returns an exit code other than 0 (EXIT_FAILURE) 
		if ($Process.ExitCode -gt 0) {
			throw
		}

		$loadingAnimation | ForEach-Object {
			Write-Host "`b$_" -ForegroundColor Yellow -NoNewline
			Start-Sleep -Milliseconds 250
		}
	}

	# Backspace and overwrite loading character with a space once process is complete
	Write-Host "`b "
}

function Start-Installation {
	param (
		[Parameter(Position = 0, Mandatory)] [ValidateNotNullOrEmpty()] [string] $FilePath,
		[Parameter(Position = 1, Mandatory)] [ValidateNotNullOrEmpty()] [string] $ArgumentList,
		[Parameter(Position = 2, Mandatory)] [ValidateNotNullOrEmpty()] [string] $InstallingMessage,
		[Parameter(Position = 3, Mandatory)] [ValidateNotNullOrEmpty()] [string] $ErrorMessage
	)

	do {
		Write-Time
		Write-Host $InstallingMessage -ForegroundColor Cyan -NoNewline

		try {
			$errorOccurred = $false
			$installation = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru

			Show-LoadingAnimation $installation
		}
		catch {
			$errorOccurred = $true

			# Write newline (`n) character to account for -NoNewline
			Write-Host "`n$($ErrorMessage)" -ForegroundColor Yellow

			$decision = $Host.UI.PromptForChoice("", "`nDo you want to try again?", @("&Yes", "&No"), 0)

			if ($decision -eq 1) {
				return $true
			}
		}
	} while ($errorOccurred)

	return $false
}

## Register scheduled task if the "-Schedule" parameter is set
if ($Schedule) {
	$taskName = "nvidia-update $($currentReleaseVersion)"
	$description = "NVIDIA Driver Update"
	$scheduleDay = "Sunday"
	$scheduleTime = "12pm"

	$action = New-ScheduledTaskAction -Execute $powershellExe -Argument "-File `"$($PSCommandPath)`" $($MyInvocation.UnboundArguments)"
	$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -RunOnlyIfIdle -IdleDuration 00:10:00 -IdleWaitTimeout 04:00:00
	$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $scheduleDay -At $scheduleTime

	# Unregister any existing nvidia-update tasks
	foreach ($existingTask in Get-ScheduledTask | Where-Object TaskName -match "^nvidia-update.") {
		Unregister-ScheduledTask -TaskName $existingTask.TaskName -Confirm:$false
	}

	Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings -Trigger $trigger -Description $description > $null
	Write-Host "This script is scheduled to run every $($scheduleDay) at $($scheduleTime).`n"
}

if ($Msi) {
	if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
		if ([int](Get-CimInstance -Class Win32_OperatingSystem | Select-Object -ExpandProperty BuildNumber) -ge 6000) {
			Write-Host "This script must be run as administrator for message-signalled interrupts to be enabled after driver installation. MSI will not be enabled.`n" -ForegroundColor Gray
			
			$Msi = $false
		}
	}
}

## Get PowerShell executable
$powershellExe = if ($PSVersionTable.PSVersion.Major -lt 6) { "powershell" } else { "pwsh" }

## Check internet connection
if (-not (Get-NetRoute | Where-Object DestinationPrefix -eq "0.0.0.0/0" | Get-NetIPInterface | Where-Object ConnectionState -eq "Connected")) {
	Write-ExitError "No internet connection. After resolving connectivity issues, please try running this script again."
}

## Check for script update and replace script if applicable
Write-Host "Checking for script update..."
Write-Host "`n`tCurrent script version:`t`t$($currentReleaseVersion)"

try {
	$latestReleaseUrl = [System.Net.WebRequest]::Create("$($scriptRepoUri)/releases/latest").GetResponse().ResponseUri.OriginalString
	$latestReleaseVersion = [System.Version]::New($latestReleaseUrl.Split("/")[-1])

	Write-Host "`tLatest script version:`t`t$($latestReleaseVersion)"

	if ($currentReleaseVersion.CompareTo($latestReleaseVersion) -lt 0) {
		Write-Host "`nReady to download the latest script file to `"$($PSCommandPath)`"..."

		if (Test-Path $configFilePath) {
			Write-Host "NOTE: $($configFilePath.Split("\")[-1]) won't be affected."
		}

		$decision = $Host.UI.PromptForChoice("", "`nDo you want to update to and run the latest script?", @("&Yes", "&No (use current version)", "&Exit"), 0)

		if ($decision -eq 0) {
			# Download new script to temporary folder
			$scriptFileUrl = "$($latestReleaseUrl.Replace("tag", "download"))/$($defaultScriptFileName)"
			$scriptDownloadPath = "$($env:TEMP)\$($defaultScriptFileName)"

			Write-Host "`nDownloading latest script file..."
			Get-WebFile $scriptFileUrl $scriptDownloadPath

			# Overwrite this script and delete temporary file
			Copy-Item $scriptDownloadPath -Destination $PSCommandPath
			Remove-Item $scriptDownloadPath -Force

			# Run new script with the same arguments; include -Schedule if a scheduled task is already registered, to update the task
			$argumentList = "$($MyInvocation.UnboundArguments)$(if (Get-ScheduledTask | Where-Object TaskName -match "^nvidia-update .") { " -Schedule" })"

			Start-Process -FilePath $powershellExe -ArgumentList "-File `"$($PSCommandPath)`" $($argumentList)"

			exit
		}
		elseif ($decision -eq 2) {
			Write-ExitTimer
		}
	}
}
catch {
	Write-Host "`nUnable to determine latest script version. Check $($scriptRepoUri)/releases/latest manually for an update." -ForegroundColor Gray

	$decision = $Host.UI.PromptForChoice("", "`nDo you want to continue with the current script?", @("&Yes", "&No"), 0)

	if ($decision -eq 1) {
		Write-ExitTimer
	}
}

## Get and display GPU and driver version information
try {
	Write-Host "`nDetecting GPU and driver version information..."

	$gpuName, $currentDriverVersion, $isNotebook, $pnpDeviceId = Get-GpuData

	Write-Host "`n`tDetected graphics card name:`t$($gpuName)"
	Write-Host "`tCurrent driver version:`t`t$($currentDriverVersion)"

	$gpuId, $osId, $dchSupported, $dch = Get-DriverLookupParameters $gpuName $isNotebook
	$driverDownloadInfo = Get-DriverDownloadInfo $gpuId $osId $dch

	if ($driverDownloadInfo) {
		$latestDriverVersion = $driverDownloadInfo.Version
		$driverDownloadUrl = $driverDownloadInfo.DownloadURL
	
		Write-Host "`tLatest driver version:`t`t$($latestDriverVersion)"
	}

	$dchDriverDownloadInfo = Get-DriverDownloadInfo $gpuId $osId $true
	$dchAvailableAndUsingNonDchDriver = $dchDriverDownloadInfo -and $dchSupported -and $dch -eq $false

	if ($dchAvailableAndUsingNonDchDriver) {
		# DCH supported and DCH driver available but using non-DCH driver
		# NOTE: $latestDriverVersion and $driverDownloadUrl represent non-DCH driver data in this case
		$latestDchDriverVersion = $dchDriverDownloadInfo.Version
		$dchDriverDownloadUrl = $dchDriverDownloadInfo.DownloadURL

		Write-Host "`tLatest driver version (DCH):`t$($latestDchDriverVersion)"
	}

	if (-not ($driverDownloadInfo -or $dchDriverDownloadInfo)) {
		Write-ExitError "`nCould not find a driver for your GPU."
	}
}
catch {
	Write-ExitError "`nUnable to determine latest driver version."
}

## Get archiver (7-Zip or WinRAR) executable path and argument list
$archiverPath = Get-RegistryValueData "HKLM:\SOFTWARE\7-Zip" "Path" "7z.exe"
$extractionArgumentList = "x -bso0 -bsp1 -bse1 `"{0}`" -o`"{1}`" {2}"

if (-not $archiverPath) {
	# 7-Zip not installed; use WinRAR if installed
	$winRarPath = Get-RegistryValueData "HKLM:\SOFTWARE\WinRAR" "exe64"

	if ($osBits -eq 32) {
		$winRarPath = Get-RegistryValueData "HKLM:\SOFTWARE\WOW6432Node\WinRAR" "exe32"
	}

	if ($winRarPath) {
		$archiverPath = $winRarPath
		$extractionArgumentList = "x `"{0}`" `"{1}`" -IBCK {2}"
	}
	else {
		# WinRAR not installed; offer 7-Zip installation
		Write-Host "`nA supported archiver is required to extract driver files."

		$decision = $Host.UI.PromptForChoice("", "`nDo you want to download and install 7-Zip?", @("&Yes", "&No"), 0)

		if ($decision -eq 1) {
			Write-ExitError "`nDriver files cannot be extracted without a supported archiver."
		}

		# Download 7-Zip to temporary folder and silently install
		$archiverDownloadUrl = "$(if ($osBits -eq 64) { "https://www.7-zip.org/a/7z2201-x64.exe" } else { "https://www.7-zip.org/a/7z2201.exe" })"
		$archiverDownloadPath = "$($env:TEMP)\7z-install.exe"

		Write-Time
		Write-Host "Downloading 7-Zip..."
		Get-WebFile $archiverDownloadUrl $archiverDownloadPath

		$argumentList = "/S"
		$installingMessage = "Installing 7-Zip..."
		$errorMessage = "`nUAC prompt declined or an error occurred during installation."

		$cancelled = Start-Installation $archiverDownloadPath $argumentList $installingMessage $errorMessage

		# Installation complete; delete downloaded file
		Remove-Item $archiverDownloadPath -Force

		if ($cancelled) {
			Write-Time
			Write-ExitError "7-Zip installation cancelled. A supported archiver is required to use this script."
		}

		Write-Time
		Write-Host "7-Zip installed." -ForegroundColor Green

		$archiverPath = Get-RegistryValueData "HKLM:\SOFTWARE\7-Zip" "Path" "7z.exe"
	}
}

## Compare installed driver version to latest driver version
if (-not $Force -and -not $dchAvailableAndUsingNonDchDriver -and $currentDriverVersion -eq $latestDriverVersion) {
	Write-ExitError "`nThe latest driver (version $($currentDriverVersion)) is already installed."
}

## Offer driver download and installation
$driverDownloadPath = "$($DownloadDirectory)\install.exe"

Write-Host "`nReady to download the latest driver installer to `"$($driverDownloadPath)`"..."

$options = @("&Yes", "&No")

if ($dchAvailableAndUsingNonDchDriver) {
	$options = @("&Yes (upgrade to DCH driver)", "Y&es", "&No")

	if ($currentDriverVersion -eq $latestDriverVersion) {
		$options = @("&Yes (upgrade to DCH driver)", "&No")
	}
}

$decision = $Host.UI.PromptForChoice("", "`nDo you want to download and install the latest driver?", $options, 0)

if ($decision -eq $options.Length - 1) {
	Write-Time
	Write-ExitError "Driver download cancelled."
}

## Create/recreate temporary folder and download the installer
Remove-Temp
New-Item -Path $DownloadDirectory -ItemType "directory" > $null

Write-Time
Write-Host "Downloading latest driver installer..."

# Set driver download URL based on selection if a non-DCH driver is installed and a newer DCH driver is available
$driverDownloadUrl = if ($dchAvailableAndUsingNonDchDriver -and $decision -eq 0) { $dchDriverDownloadUrl } else { $driverDownloadUrl }

Get-WebFile $driverDownloadUrl $driverDownloadPath

## Extract setup files
Write-Time
Write-Host "Extracting driver files..."

$extractDir = "$($DownloadDirectory)\driver"
$filesToExtract = "Display.Driver NVI2 EULA.txt ListDevices.txt setup.cfg setup.exe"

if (Test-Path $configFilePath) {
	Get-Content -Path $configFilePath | Where-Object { $_ -match "^[^\/]+" } | ForEach-Object {
		$filesToExtract += " $($_.Split(" /")[0])"
	}
}

try {
	Start-Process -FilePath $archiverPath -NoNewWindow -ArgumentList ($extractionArgumentList -f $driverDownloadPath, $extractDir, $filesToExtract) -Wait
}
catch {
	Write-ExitError "`nAn error occurred while extracting driver files."
}

## Remove unnecessary dependencies from setup.cfg
try {
	Set-Content -Path "$($extractDir)\setup.cfg" -Value (Get-Content -Path "$($extractDir)\setup.cfg" | Select-String -Pattern "name=`"\$`{{(EulaHtmlFile|FunctionalConsentFile|PrivacyPolicyFile)}}" -notmatch)
}
catch {
	Write-ExitError "`nUnable to remove unnecessary dependencies from `"setup.cfg`" because it is being used by another process.`nPlease close any conflicting program and try again." -RemoveTemp
}

## Install driver
$argumentList = "-passive -noreboot -noeula -nofinish -s"

if ($Clean) {
	$argumentList += " -clean"
}

$installingMessage = "Installing driver..."
$errorMessage = "`nUAC prompt declined or an error occurred during installation."

$cancelled = Start-Installation "$($extractDir)\setup.exe" $argumentList $installingMessage $errorMessage

if ($cancelled) {
	Write-Time
	Write-ExitError "Driver installation cancelled." -RemoveTemp
}

# Installation complete; remove temporary driver installer files
Write-Host "`nRemoving temporary files..."
Remove-Temp

## Enable message-signalled interrupts if the "-Msi" parameter is set
if ($Msi) {
	Write-Host "`nEnabling message-signalled interrupts..."

	$regPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($pnpDeviceId)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"

	if (-not (Test-Path $regPath)) {
		New-Item -Path $regPath > $null
	}

	Set-ItemProperty -Path $regPath -Name "MSISupported" -Value 1
}

## Driver installed; offer a reboot
Write-Time
Write-Host "Driver installed. " -ForegroundColor Green -NoNewline 
Write-Host "You may need to reboot to finish installation."

$decision = $Host.UI.PromptForChoice("", "`nDo you want to reboot?", @("&Yes", "&No"), 1)

if ($decision -eq 1) {
	Write-ExitTimer
}

Write-host "`nRebooting now..."
Restart-Computer