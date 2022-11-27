<#PSScriptInfo
.VERSION 1.12
.GUID dd04650b-78dc-4761-89bf-b6eeee74094c
.AUTHOR ZenitH-AT
.LICENSEURI https://raw.githubusercontent.com/ZenitH-AT/nvidia-update/master/LICENSE
.PROJECTURI https://github.com/ZenitH-AT/nvidia-update
.DESCRIPTION Checks for a new version of the NVIDIA driver, downloads and installs it. 
#>
param (
	[switch] $Clean = $false, # Delete the existing driver and install the latest one
	[switch] $Msi = $false, # Enable message-signalled interrupts (MSI) for this update only; requires elevation
	[switch] $Schedule = $false, # Register a scheduled task to periodically run this script; MSI will always be enabled if it "-Msi" was also set
	[switch] $Desktop = $false, # Override the desktop/notebook check and download the desktop driver; useful when using an external GPU or unable to find a driver
	[switch] $Notebook = $false, # Override the desktop/notebook check and download the notebook driver
	[string] $Directory = "$($env:TEMP)\NVIDIA" # The directory where the script will download and extract the driver
)

## Constant variables and functions
New-Variable -Name "originalWindowTitle" -Value $host.UI.RawUI.WindowTitle
New-Variable -Name "scriptPath" -Value $PSCommandPath -Option Constant
New-Variable -Name "currentScriptVersion" -Value "$(Test-ScriptFileInfo -Path $scriptPath | ForEach-Object Version)" -Option Constant
New-Variable -Name "rawScriptRepo" -Value "https://raw.githubusercontent.com/ZenitH-AT/nvidia-update/master" -Option Constant
New-Variable -Name "scriptRepoVersionFile" -Value "version.txt" -Option Constant
New-Variable -Name "scriptRepoScriptFile" -Value "nvidia-update.ps1" -Option Constant
New-Variable -Name "rawDataRepo" -Value "https://raw.githubusercontent.com/ZenitH-AT/nvidia-data/main" -Option Constant
New-Variable -Name "dataRepoGpuDataFile" -Value "gpu-data.json" -Option Constant
New-Variable -Name "dataRepoOsDataFile" -Value "os-data.json" -Option Constant
New-Variable -Name "osBits" -Value "$(if ([Environment]::Is64BitOperatingSystem) { 64 } else { 32 })" -Option Constant
New-Variable -Name "dataDividends" -Value @(1, 1024, 1048576) -Option Constant
New-Variable -Name "dataUnits" -Value @("B", "KiB", "MiB") -Option Constant

function Exit-Script {
	$host.UI.RawUI.WindowTitle = $originalWindowTitle
	exit
}

function Remove-Temp {
	if (Test-Path $Directory) {
		try {
			Remove-Item $Directory -Recurse -Force -ErrorAction Ignore
		}
		catch {
			Write-Host "Some files located at $($Directory) could not be deleted, you may want to remove them manually later." -ForegroundColor Gray
		}
	}
}

function Write-ExitError {
	param (
		[Parameter(Position = 0, Mandatory)] [ValidateNotNullOrEmpty()] [string] $ErrorMessage,
		[Parameter(Position = 1)] [switch] $RemoveTemp
	)

	Write-Host $ErrorMessage -ForegroundColor Yellow

	if ($RemoveTemp) {
		Write-Host "`nRemoving temporary files..."

		Remove-Temp $Directory

		# Only write new line after any potential error message from Remove-Temp
		Write-Host
	}

	Write-Host "Press any key to exit..."

	$host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

	Exit-Script
}

function Write-ExitTimer {
	param (
		[ValidateNotNullOrEmpty()] [int] $Milliseconds = 5000
	)

	$seconds = [System.Math]::Floor($Milliseconds / 1000)

	Write-Host "`nExiting script in $($seconds) seconds..."

	Start-Sleep -Milliseconds $Milliseconds

	Exit-Script
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

	$convertedBytes = [System.Math]::Round(($Bytes / $dataDividends[$UnitIndex]), $Decimals)

	return $convertedBytes.ToString("0.$("0" * $Decimals)")
}

function Get-WebFile {
	param (
		[Parameter(Position = 0, Mandatory)] [ValidateNotNullOrEmpty()] [string] $Url,
		[Parameter(Position = 1, Mandatory)] [ValidateNotNullOrEmpty()] [string] $TargetPath
	)

	# Create runspace pool and runspace for download
	$pool = [RunspaceFactory]::CreateRunspacePool(1, [int]$env:NUMBER_OF_PROCESSORS + 1)
		
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
			[Parameter(Position = 0, Mandatory)] [ValidateNotNullOrEmpty()] [string] $Url,
			[Parameter(Position = 1, Mandatory)] [ValidateNotNullOrEmpty()] [string] $TargetPath,
			[Parameter(Position = 2, Mandatory)] [ValidateNotNullOrEmpty()] [ref] [int] $TotalBytes,
			[Parameter(Position = 3, Mandatory)] [ValidateNotNullOrEmpty()] [ref] [int] $DownloadedBytes,
			[Parameter(Position = 4, Mandatory)] [ValidateNotNullOrEmpty()] [ref] [bool] $DownloadHadError
		)

		try {
			$uri = New-Object -TypeName "System.Uri" $Url

			$request = [System.Net.HttpWebRequest]::Create($uri)

			$request.set_Timeout(15000) # 15 seconds

			$response = $request.GetResponse()

			$TotalBytes.Value = $response.get_ContentLength()

			$responseStream = $response.GetResponseStream()

			$targetStream = New-Object -TypeName "System.IO.FileStream" -ArgumentList $TargetPath, Create

			$buffer = New-Object byte[] 10240 # 10 KiB

			do {
				$count = $responseStream.Read($buffer, 0, $buffer.Length)

				$targetStream.Write($buffer, 0, $count)

				$DownloadedBytes.Value += $count

				# TODO: Stop download if parent process ended
			} while ($count -gt 0)
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
	$activity = "Downloading file `"$($Url -split "/" | Select-Object -Last 1)`" to `"$($TargetPath)`"..."

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

			$decision = $Host.UI.PromptForChoice("", "`nDo you want to try again?", ("&Yes", "&No"), 0)

			if ($decision -eq 1) {
				return $true
			}
		}
	} while ($errorOccurred)

	return $false
}

function Get-GpuData {
	$gpus = @(Get-CimInstance Win32_VideoController | Select-Object PNPDeviceID, Name, DriverVersion)

	foreach ($gpu in $gpus) {
		$pnpDeviceId = $gpu.PNPDeviceID
		$gpuName = $gpu.Name

		if ($gpuName -match "^NVIDIA") {
			# Clean GPU name, accounting for card variants (e.g. 1060 6GB, 760Ti (OEM))
			if ($gpuName -match "(?<=NVIDIA )(.*(?= [0-9]+GB)|.*(?= \([A-Z]+\))|.*)") {
				$gpuName = $Matches[0].Trim()
			}
			else {
				Write-ExitError "`nUnrecognised GPU name $($gpuName). This should not happen."
			}

			$currentDriverVersion = ($gpu.DriverVersion.Replace(".", "")[-5..-1] -join "").Insert(3, ".")

			# Determine if computer is a notebook to always download the correct driver,
			# since some GPUs are present in both a desktop and notebook series (e.g. GeForce GTX 1050 Ti)
			$isNotebook = [bool] (Get-CimInstance -ClassName Win32_SystemEnclosure).ChassisTypes.Where({ $_ -in @(9, 10, 14) })

			$compatibleGpuFound = $true
			break
		}
	}

	if (-not $compatibleGpuFound) {
		Write-ExitError "`nUnable to detect a compatible NVIDIA device."
	}

	return $pnpDeviceId, $gpuName, $currentDriverVersion, $isNotebook
}

function Get-DriverLookupParameters {
	param (
		[Parameter(Position = 0, Mandatory)] [ValidateNotNullOrEmpty()] [string] $GpuName,
		[Parameter(Position = 1, Mandatory)] [ValidateNotNullOrEmpty()] [bool] $IsNotebook
	)

	# Determine product family (GPU) ID
	try {
		$gpuData = Invoke-RestMethod -Uri "$($rawDataRepo)/$($dataRepoGpuDataFile)" | ConvertFrom-Json -AsHashTable

		if (-not $Notebook -and ($Desktop -or -not $IsNotebook)) {
			$gpuId = $gpuData."desktop".$GpuName
		}
		else {
			$gpuId = $gpuData."notebook".$GpuName
		}
	}
	catch {
		Write-ExitError "Unable to retrieve GPU data. Please try running this script again."
	}

	if (-not $gpuId) {
		Write-ExitError "`nUnable to determine GPU product family ID. This should not happen."
	}

	# Determine operating system version
	$osVersion = "$([Environment]::OSVersion.Version.Major).$([Environment]::OSVersion.Version.Minor)"

	# Determine operating system ID
	try {
		$osData = Invoke-RestMethod -Uri "$($rawDataRepo)/$($dataRepoOsDataFile)"
	}
	catch {
		Write-ExitError "Unable to retrieve OS data. Please try running this script again."
	}

	foreach ($os in $osData) {
		if (($os.code -eq $osVersion) -and ($os.name -match $osBits)) {
			$osId = $os.id
			break
		}
	}

	if (-not $osId) {
		Write-ExitError "`nCould not find a driver supported by your operating system."
	}

	# Check if using DCH driver
	$dch = 0

	if ($osVersion -eq "10.0") {
		if (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm" -Name "DCHUVen" -ErrorAction Ignore) {
			$dch = 1
		}
	}

	return $gpuId, $osId, $dch
}

function Get-DriverDownloadInfo {
	param (
		[Parameter(Position = 0, Mandatory)] [ValidateNotNullOrEmpty()] [string] $GpuId,
		[Parameter(Position = 1, Mandatory)] [ValidateNotNullOrEmpty()] [string] $OsId,
		[Parameter(Position = 2, Mandatory)] [ValidateNotNullOrEmpty()] [string] $Dch
	)

	$request = "https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?"
	$request += "func=DriverManualLookup&pfid=$($GpuId)&osID=$($OsId)&dch=$($Dch)"

	try {
		$payload = Invoke-RestMethod -Uri $request

		if ($payload.Success -eq 1) {
			return $payload.IDS[0].downloadInfo
		}
		else {
			Write-ExitError "`nCould not find a driver for your GPU."
		}
	}
	catch {
		Write-ExitError "Unable to get driver download info. Please try running this script again."
	}
}

## Set window title
$host.UI.RawUI.WindowTitle = $scriptPath -split "\\" | Select-Object -Last 1

## Register scheduled task if the "-Schedule" parameter is set
if ($Schedule) {
	$taskName = "nvidia-update $($currentScriptVersion)"
	$description = "NVIDIA Driver Update"
	$scheduleDay = "Sunday"
	$scheduleTime = "12pm"
	$actionArgument = "-File `"$($scriptPath)`""
	
	# Enable message-signalled interrupts on sheduled driver updates if the "-Msi" parameter is also set
	if ($Msi) {
		$actionArgument += " -Msi"
	}

	$action = New-ScheduledTaskAction -Execute "powershell" -Argument $actionArgument
	$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -RunOnlyIfIdle -IdleDuration 00:10:00 -IdleWaitTimeout 04:00:00
	$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $scheduleDay -At $scheduleTime

	# Register task if it doesn't already exist or if it references a different script version (and delete outdated tasks)
	$registerTask = $true

	$existingTasks = Get-ScheduledTask | Where-Object TaskName -match "^nvidia-update."
	
	foreach ($existingTask in $existingTasks) {
		$registerTask = $false
	
		if ($existingTask.TaskName -notlike "*$($currentScriptVersion)") {
			Unregister-ScheduledTask -TaskName $existingTask.TaskName -Confirm:$false
	
			$registerTask = $true
		}
	}

	if ($registerTask) {
		Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings -Trigger $trigger -Description $description > $null
	}

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

## Check internet connection
if (-not (Get-NetRoute | Where-Object DestinationPrefix -eq "0.0.0.0/0" | Get-NetIPInterface | Where-Object ConnectionState -eq "Connected")) {
	Write-ExitError "No internet connection. After resolving connectivity issues, please try running this script again."
}

## Check for script update and replace script if applicable
Write-Host "Checking for script update..."

Write-Host "`n`tCurrent script version:`t`t$($currentScriptVersion)"

try {
	$latestScriptVersion = Invoke-WebRequest -Uri "$($rawScriptRepo)/$($scriptRepoVersionFile)"
	$latestScriptVersion = "$($latestScriptVersion)".Trim()

	Write-Host "`tLatest script version:`t`t$($latestScriptVersion)"

	if ($currentScriptVersion -eq $latestScriptVersion) {
		Write-Host "`nThis is the latest script (version $($currentScriptVersion))."
	}
	else {
		Write-Host "`nReady to download the latest script file to `"$($scriptPath)`"..."
		Write-Host "Note: `"optional-components.cfg`" will not be affected."

		$decision = $Host.UI.PromptForChoice("", "`nDo you want to update to and run the latest script?", ("&Yes", "&No (use current version)", "&Exit"), 0)

		if ($decision -eq 0) {
			# Download new script to temporary folder
			$dlScriptPath = "$($env:TEMP)\$($scriptRepoScriptFile)"

			Write-Host "`nDownloading latest script file..."

			Get-WebFile "$($rawScriptRepo)/$($scriptRepoScriptFile)" $dlScriptPath

			# Overwrite this script and delete temporary file
			Copy-Item $dlScriptPath -Destination $scriptPath

			Remove-Item $dlScriptPath -Force

			# Run new script with the same arguments; include -Schedule if a scheduled task is registered to update the task
			$argumentList = "$($MyInvocation.UnboundArguments)$(if (Get-ScheduledTask | Where-Object TaskName -match "^nvidia-update.") { " -Schedule" })"

			Start-Process -FilePath "powershell" -ArgumentList "-File `"$($scriptPath)`" $($argumentList)"

			Exit-Script
		}
		elseif ($decision -eq 2) {
			Write-ExitTimer
		}
	}
}
catch {
	Write-Host "`nUnable to determine latest script version." -ForegroundColor Gray

	$decision = $Host.UI.PromptForChoice("", "`nDo you want to continue with the current script?", ("&Yes", "&No"), 0)

	if ($decision -eq 1) {
		Write-ExitTimer
	}
}

## Check if a supported archiver (7-Zip or WinRAR) is installed
$7zInstalled = $false

if (Test-Path "HKLM:\SOFTWARE\7-Zip") {
	$7zPath = "$(Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\7-Zip" -Name "Path")7z.exe"

	if (Test-Path $7zPath) {
		$archiverProgram = $7zPath
		$7zInstalled = $true 
	}
}
else {
	if (Test-Path "HKLM:\SOFTWARE\WinRAR") {
		$winRarPath = Get-ItemProperty -Path "HKLM:\SOFTWARE\WinRAR" -Name "exe64"

		if (Test-Path $winRarPath) {
			$archiverProgram = $winRarPath
		}
	}
	else {
		Write-Host "`nSorry, but it looks like you don't have a supported archiver."

		$decision = $Host.UI.PromptForChoice("", "`nDo you want to install 7-Zip?", ("&Yes", "&No"), 0)

		if ($decision -eq 0) {
			# Download 7-Zip to temporary folder and silently install
			# TODO: Get URL of latest version dynamically
			if ($osBits -eq "64") {
				$archiverUrl = "https://www.7-zip.org/a/7z1900-x64.exe"
			}
			else {
				$archiverUrl = "https://www.7-zip.org/a/7z1900.exe"
			}

			$dlArchiverPath = "$($env:TEMP)\7z1900-x64.exe"

			Write-Time
			Write-Host "Downloading 7-Zip..."

			Get-WebFile $archiverUrl $dlArchiverPath

			$argumentList = "/S"

			$installingMessage = "Installing 7-zip..."

			$errorMessage = "`nUAC prompt declined or an error occurred during installation."

			$cancelled = Start-Installation $dlArchiverPath $argumentList $installingMessage $errorMessage

			# Delete the installer once it completes
			Remove-Item $dlArchiverPath -Force

			if ($cancelled) {
				Write-Time
				Write-ExitError "7-Zip installation cancelled. A supported archiver is required to use this script."
			}

			Write-Time
			Write-Host "7-Zip installed." -ForegroundColor Green
		}
		else {
			Write-ExitError "`nA supported archiver is required to use this script."
		}
	}
}

## Get and display GPU and driver version information
try {
	Write-Host "`nDetecting GPU and driver version information..."

	$pnpDeviceId, $gpuName, $currentDriverVersion, $isNotebook = Get-GpuData

	Write-Host "`n`tDetected graphics card name:`t$($gpuName)"
	Write-Host "`tCurrent driver version:`t`t$($currentDriverVersion)"

	$gpuId, $osId, $dch = Get-DriverLookupParameters $gpuName $isNotebook
	$driverDownloadInfo = Get-DriverDownloadInfo $gpuId $osId $dch

	$latestDriverVersion = $driverDownloadInfo.Version

	Write-Host "`tLatest driver version:`t`t$($latestDriverVersion)"
}
catch {
	Write-ExitError "`nUnable to determine latest driver version."
}

## Compare installed driver version to latest driver version
if (-not $Clean -and ($currentDriverVersion -eq $latestDriverVersion)) {
	Write-ExitError "`nThe latest driver (version $($currentDriverVersion)) is already installed."
}

## Create temporary folder and download the installer
$dlDriverPath = "$($Directory)\$($latestDriverVersion).exe"

Write-Host "`nReady to download the latest driver installer to `"$($dlDriverPath)`"..."

$decision = $Host.UI.PromptForChoice("", "`nDo you want to download and install the latest driver?", ("&Yes", "&No"), 0)

if ($decision -eq 0) {
	# Remove existing temporary folder if present
	Remove-Temp $Directory

	New-Item -Path $Directory -ItemType "directory" > $null

	Write-Time
	Write-Host "Downloading latest driver installer..."

	Get-WebFile $driverDownloadInfo.DownloadURL $dlDriverPath
}
else {
	Write-Time
	Write-ExitError "Driver download cancelled."
}

## Extract setup files
$extractDir = "$($Directory)\$($latestVersion)"

Write-Time
Write-Host "Extracting driver files..."

$filesToExtract = "Display.Driver NVI2 EULA.txt ListDevices.txt setup.cfg setup.exe"

if (Test-Path "$($PSScriptRoot)\optional-components.cfg") {
	Get-Content -Path "$($PSScriptRoot)\optional-components.cfg" | Where-Object { $_ -match "^[^\/]+" } | ForEach-Object {
		$filesToExtract += " $($_)"
	}
}

if ($7zInstalled) {
	Start-Process -FilePath $archiverProgram -NoNewWindow -ArgumentList "x -bso0 -bsp1 -bse1 -aoa $($dlDriverPath) $($filesToExtract) -o$($extractDir)" -Wait
}
elseif ($archiverProgram -eq $winrarpath) {
	Start-Process -FilePath $archiverProgram -NoNewWindow -ArgumentList "x $($dlDriverPath) $($extractDir) -IBCK $($filesToExtract)" -Wait
}
else {
	Write-ExitError "`nNo archive program detected. This should not happen." -RemoveTemp
}

## Remove unnecessary dependencies from setup.cfg
try {
	Set-Content -Path "$($extractDir)\setup.cfg" -Value (Get-Content -Path "$($extractDir)\setup.cfg" | Select-String -Pattern 'name="\${{(EulaHtmlFile|FunctionalConsentFile|PrivacyPolicyFile)}}' -notmatch)
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

## Remove temporary (downloaded) files
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

$decision = $Host.UI.PromptForChoice("", "`nDo you want to reboot?", ("&Yes", "&No"), 1)

if ($decision -eq 0) {
	Write-host "`nRebooting now..."

	Start-Sleep -Milliseconds 2000

	Restart-Computer
}
else {
	Write-ExitTimer
}

## End of script
Exit-Script