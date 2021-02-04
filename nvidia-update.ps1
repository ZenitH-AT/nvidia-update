<#PSScriptInfo
.VERSION 1.5
.GUID dd04650b-78dc-4761-89bf-b6eeee74094c
.AUTHOR ZenitH-AT
.LICENSEURI https://raw.githubusercontent.com/ZenitH-AT/nvidia-update/master/LICENSE
.PROJECTURI https://github.com/ZenitH-AT/nvidia-update
.DESCRIPTION Checks for a new version of the NVIDIA driver, downloads and installs it. 
#>
param (
	[switch] $Clean = $false, # Delete the existing driver and install the latest one
	[switch] $Schedule = $false, # Register a scheduled task to periodically run this script
	[string] $Directory = "$($env:TEMP)" # The directory where the script will download and extract the driver
)

## Constant variables and functions
New-Variable -Name "scriptPath" -Value "$($PSScriptRoot)\$($MyInvocation.MyCommand.Name)" -Option Constant
New-Variable -Name "currentScriptVersion" -Value "$(Test-ScriptFileInfo -Path $scriptPath | ForEach-Object { $_.Version })" -Option Constant
New-Variable -Name "rawRepo" -Value "https://raw.githubusercontent.com/ZenitH-AT/nvidia-update/master" -Option Constant
New-Variable -Name "repoVersionFile" -Value "version.txt" -Option Constant
New-Variable -Name "repoScriptFile" -Value "nvidia-update.ps1" -Option Constant
New-Variable -Name "osArchitecture" -Value "$(if (([System.IntPtr]::Size -eq 4) -and !(Test-Path "env:\PROCESSOR_ARCHITEW6432")) { 32 } else { 64 })" -Option Constant

function Remove-Temp {
	param (
		$TempDir
	)

	if (Test-Path $TempDir) {
		try {
			Remove-Item $TempDir -Recurse -Force -ErrorAction Ignore
		}
		catch {
			Write-Host -ForegroundColor Gray "Some files located at $($TempDir) could not be deleted, you may want to remove them manually later."
		}
	}
}

function Write-ExitError {
	param (
		[string] $ErrorMessage,
		[switch] $RemoveTemp,
		[string] $TempDir
	)

	Write-Host -ForegroundColor Yellow $ErrorMessage

	if ($RemoveTemp) {
		Write-Host "`nRemoving temporary files..."

		Remove-Temp $TempDir

		# Only write new line after any potential error message from Remove-Temp
		Write-Host
	}

	Write-Host "Press any key to exit..."

	$host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

	exit
}

function Write-ExitTimer {
	param (
		[int] $Milliseconds = 5000
	)

	$seconds = [System.Math]::Floor($Milliseconds / 1000)

	Write-Host "`nExiting script in $($seconds) seconds..."
	
	Start-Sleep -Milliseconds $Milliseconds
	
	exit
}

function Close-Stream {
	param (
		$TargetStream,
		$ResponseStream
	)

	$TargetStream.Flush()
	$TargetStream.Close()
	$TargetStream.Dispose()
	$ResponseStream.Dispose()
}

function Get-WebFile {
	param (
		[string] $Url,
		[string] $TargetPath,
		[int] $Timeout = 15000 # 15 seconds
	)

	try {
		$uri = New-Object System.Uri $Url

		$request = [System.Net.HttpWebRequest]::Create($uri)

		$request.set_Timeout($Timeout)

		$response = $request.GetResponse()

		$totalLength = [System.Math]::Floor($response.get_ContentLength() / 1024)

		$responseStream = $response.GetResponseStream()

		$targetStream = New-Object -TypeName System.IO.FileStream -ArgumentList $TargetPath, Create

		$buffer = New-Object byte[] 10KB

		$count = $responseStream.Read($buffer, 0, $buffer.Length)

		$downloadedBytes = $count

		$activity = "Downloading file `"$($url -split "/" | Select-Object -Last 1)`" to `"$($TargetPath)`"..."

		while ($count -gt 0) {
			$targetStream.Write($buffer, 0, $count)

			$count = $responseStream.Read($buffer, 0, $buffer.Length)

			$downloadedBytes += $count

			$downloadedKBytes = [System.Math]::Floor($downloadedBytes / 1024)

			$status = "Downloaded ($($downloadedKBytes)K of $($totalLength)K):"

			$percentComplete = ($downloadedKBytes / $totalLength) * 100

			Write-Progress -Activity $activity -Status $status -PercentComplete $percentComplete
		}

		Close-Stream $targetStream $responseStream
	}
	catch {
		# Remove partially downloaded file if present
		if (Test-Path $TargetPath) {
			if ($targetStream -and $responseStream) {
				Close-Stream $targetStream $responseStream
			} 

			Remove-Item $TargetPath -Force
		}

		Write-ExitError "`nDownload failed. Please try running this script again."
	}
}

function Show-LoadingAnimation {
	param (
		$Process
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
			Write-Host "`b$_" -NoNewline -ForegroundColor Yellow

			Start-Sleep -Milliseconds 250
		}
	}

	# Backspace and overwrite loading character with a space once job is complete
	Write-Host "`b "
}

function Start-Installation {
	param (
		[string] $FilePath,
		[string] $ArgumentList,
		[string] $InstallingMessage,
		[string] $ErrorMessage
	)

	do {
		Write-Host -ForegroundColor Cyan $InstallingMessage -NoNewline

		try {
			$errorOccurred = $false

			$installation = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru

			Show-LoadingAnimation $installation
		}
		catch {
			$errorOccurred = $true

			# Write newline (`n) character to account for -NoNewline
			Write-Host -ForegroundColor Yellow "`n$($ErrorMessage)"

			$decision = $Host.UI.PromptForChoice("", "`nDo you want to try again?", ("&Yes", "&No"), 0)

			if ($decision -eq 1) {
				return $true
			}
		}
	} while ($errorOccurred)

	return $false
}

function Get-GpuData {
	$gpus = @(Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion)

	foreach ($gpu in $gpus) {
		$gpuName = $gpu.Name

		if ($gpuName -match "^NVIDIA") {
			# Format GPU name, accounting for card variants (e.g. 1060 6GB)
			if ($gpuName -match "(?<=NVIDIA )(.*(?= [0-9]+GB)|.*)") {
				$gpuName = $Matches[0].Trim()
			}
			else {
				Write-ExitError "`nUnrecognised GPU name $($gpuName). This should not happen."
			}

			$gpuType = "Desktop"

			if ($gpuName -match "(M|Q(X|\s+(LE|GTX|GTS|GS|GT|G))?$|GeForce Go)") {
				$gpuType = "Notebook" 
			}

			$currentDriverVersion = $gpu.DriverVersion.SubString(7).Remove(1, 1).Insert(3, ".")

			$compatibleGpuFound = $true
			break
		}
	}

	if (!$compatibleGpuFound) {
		Write-ExitError "`nUnable to detect a compatible NVIDIA device."
	}

	return $gpuName, $gpuType, $currentDriverVersion
}

function Get-GpuLookupData {
	param (
		[string] $TypeId,
		[string] $ParentId
	)

	# TypeId - 2: product series; 3: product family (GPU); 4: operating system

	$request = "http://www.nvidia.com/Download/API/lookupValueSearch.aspx?"
	$request += "TypeID=$($TypeId)&ParentID=$($ParentId)"

	try {
		$payload = Invoke-RestMethod $request

		return $payload.LookupValueSearch.LookupValues.LookupValue
	}
	catch {
		Write-ExitError "Unable to get GPU lookup parameters. Please try running this script again."
	}
}

function Get-DriverLookupParameters {
	param (
		[string] $GpuName,
		[string] $GpuType
	)

	# Determine product series ID
	$seriesData = Get-GpuLookupData 2 1

	foreach ($series in $seriesData) {
		# Limit to desktop/notebook
		if ($GpuType -eq "Notebook") {
			if ($series.Name -notlike "*Notebook*") { continue }
		}
		else {
			if ($series.Name -like "*Notebook*") { continue }
		}

		$seriesId = $series.Value

		# Determine product family (GPU) ID
		$familyData = Get-GpuLookupData 3 $seriesId

		foreach ($gpu in $familyData) {
			$searchGpuName = $gpu.Name.Replace("NVIDIA", "").Trim()

			if ($searchGpuName -eq $GpuName) {
				$gpuId = $gpu.Value
				break
			}
			elseif ($searchGpuName -like "*/*") {
				if ((($searchGpuName -replace "(\/|nForce).*$", "").Trim() -eq $GpuName) -or 
					(($searchGpuName -replace "(?:[^\s]+\/|(?:[^\s]+\s+){2}\/|.*?(nForce))", "" -replace "\s+", " ").Trim() -eq $GpuName)) {

					$gpuId = $gpu.Value
					break
				}
			}
		}

		# Stop searching when product series ID is correct
		if ($gpuId) {
			break
		}
	}

	if (!$gpuId) {
		Write-ExitError "`nUnable to determine GPU product family ID. This should not happen."
	}

	# Determine operating system version
	$osVersion = "$([Environment]::OSVersion.Version.Major).$([Environment]::OSVersion.Version.Minor)"

	# Determine operating system ID
	$osData = Get-GpuLookupData 4 $seriesId

	foreach ($os in $osData) {
		if (($os.Code -eq $osVersion) -and ($os.Name -match $osArchitecture)) {
			$osID = $os.Value
			break
		}
	}

	if (!$osId) {
		Write-ExitError "`nCould not find a driver supported by your operating system."
	}

	# Check if using DCH driver
	$dch = 0

	if ($osVersion -eq 10.0) {
		if (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm" -Name "DCHUVen" -ErrorAction Ignore) {
			$dch = 1
		}
	}

	return $gpuId, $osId, $dch
}

function Get-DriverDownloadInfo {
	param (
		[string] $GpuId,
		[string] $OsId,
		[string] $Dch
	)

	$request = "https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?"
	$request += "func=DriverManualLookup&pfid=$($GpuId)&osID=$($OsId)&dch=$($Dch)"

	try {
		$payload = Invoke-RestMethod $request

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

## Register scheduled task if the $Schedule parameter is set
if ($Schedule) {
	$taskName = "nvidia-update $($currentScriptVersion)"
	$description = "NVIDIA Driver Update"
	$scheduleDay = "Sunday"
	$scheduleTime = "12pm"

	$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $scriptPath
	$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -RunOnlyIfIdle -IdleDuration 00:10:00 -IdleWaitTimeout 04:00:00
	$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $scheduleDay -At $scheduleTime

	# Register task if it doesn't already exist or if it references a different script version (and delete outdated tasks)
	$registerTask = $true

	$existingTasks = Get-ScheduledTask | Where-Object { $_.TaskName -match "^nvidia-update." }
	
	foreach ($existingTask in $existingTasks) {
		$registerTask = $false
	
		if ($existingTask.TaskName -notlike "*$($currentScriptVersion)") {
			Unregister-ScheduledTask -TaskName $existingTask.TaskName -Confirm:$false
	
			$registerTask = $true
		}
	}

	if ($registerTask) {
		Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings -Trigger $trigger -Description $description | Out-Null
	}

	Write-Host "This script is scheduled to run every $($scheduleDay) at $($scheduleTime).`n"
}

## Check internet connection
if (!(Get-NetRoute | Where-Object DestinationPrefix -eq "0.0.0.0/0" | Get-NetIPInterface | Where-Object ConnectionState -eq "Connected")) {
	Write-ExitError "No internet connection. After resolving connectivity issues, please try running this script again."
}

## Check for script update and replace script if applicable
Write-Host "Checking for script update..."

Write-Host "`n`tCurrent script version:`t`t$($currentScriptVersion)"

try {
	$latestScriptVersion = Invoke-WebRequest -Uri "$($rawRepo)/$($repoVersionFile)"
	$latestScriptVersion = "$($latestScriptVersion)".Trim()

	Write-Host "`tLatest script version:`t`t$($latestScriptVersion)"
}
catch {
	Write-Host -ForegroundColor Gray "`nUnable to determine latest script version."

	$decision = $Host.UI.PromptForChoice("", "`nDo you want to continue with the current script?", ("&Yes", "&No"), 0)

	if ($decision -eq 1) {
		Write-ExitTimer
	}
}

if ($currentScriptVersion -eq $latestScriptVersion) {
	Write-Host "`nThis is the latest script (version $($currentScriptVersion))."
}
else {
	Write-Host "`nReady to download the latest script file to `"$($scriptPath)`"..."
	Write-Host "Note: `"optional-components.cfg`" will not be affected."

	$decision = $Host.UI.PromptForChoice("", "`nDo you want to update to and run the latest script?", ("&Yes", "&No (use current version)", "&Exit"), 0)

	if ($decision -eq 0) {
		# Download new script to temporary folder
		$dlScriptPath = "$($env:TEMP)\$($repoScriptFile)"

		Write-Host "`nDownloading latest script file..."

		Get-WebFile "$($rawRepo)/$($repoScriptFile)" $dlScriptPath

		# Overwrite this script and delete temporary file
		Copy-Item $dlScriptPath -Destination $scriptPath
		
		Remove-Item $dlScriptPath -Force

		# Run new script with the same parameters
		$parameters = ""

		foreach ($key in $MyInvocation.BoundParameters.keys) {
			$parameters += "-$($key) $($MyInvocation.BoundParameters[$key]) "
		}

		# Include -Schedule parameter if a scheduled task is registered to update the task
		$existingTasks = Get-ScheduledTask | Where-Object { $_.TaskName -match "^nvidia-update." }

		if ($existingTasks) {
			$parameters += "-Schedule"
		}

		Start-Process PowerShell "$($scriptPath) $($parameters)"

		exit
	}
	elseif ($decision -eq 2) {
		Write-ExitTimer
	}
}

## Check if a supported archiver (7-Zip or WinRAR) is installed
$7zInstalled = $false

if (Test-Path "HKLM:\SOFTWARE\7-Zip") {
	$7zpath = Get-ItemProperty -Path "HKLM:\SOFTWARE\7-Zip" -Name "Path"
	$7zpath = $7zpath.Path
	$7zpathexe = $7zpath + "7z.exe"

	if ((Test-Path $7zpathexe) -eq $true) {
		$archiverProgram = $7zpathexe
		$7zInstalled = $true 
	}
}
else {
	if (Test-Path "HKLM:\SOFTWARE\WinRAR") {
		$winrarpath = Get-ItemProperty -Path "HKLM:\SOFTWARE\WinRAR" -Name "exe64"
		$winrarpath = $winrarpath.exe64

		if ((Test-Path $winrarpath) -eq $true) {
			$archiverProgram = $winrarpath
		}
	}
	else {
		Write-Host "`nSorry, but it looks like you don't have a supported archiver."

		$decision = $Host.UI.PromptForChoice("", "`nDo you want to install 7-Zip?", ("&Yes", "&No"), 0)

		if ($decision -eq 0) {
			# Download 7-Zip to temporary folder and silently install
			if ($osArchitecture -eq 64) {
				$archiverUrl = "https://www.7-zip.org/a/7z1900-x64.exe"
			}
			else {
				$archiverUrl = "https://www.7-zip.org/a/7z1900.exe"
			}

			$dlArchiverPath = "$($env:TEMP)\7z1900-x64.exe"

			Write-Host "`nDownloading 7-Zip..."

			Get-WebFile $archiverUrl $dlArchiverPath

			$argumentList = "/S"

			$installingMessage = "`nInstalling 7-zip..."

			$errorMessage = "`nUAC prompt declined or an error occurred during installation."

			$cancelled = Start-Installation $dlArchiverPath $argumentList $installingMessage $errorMessage

			# Delete the installer once it completes
			Remove-Item $dlArchiverPath -Force

			if ($cancelled) {
				Write-ExitError "`n7-Zip installation cancelled. A supported archiver is required to use this script."
			}

			Write-Host -ForegroundColor Green "`n7-Zip installed."
		}
		else {
			Write-ExitError "`nA supported archiver is required to use this script."
		}
	}
}

## Get and display GPU and driver version information
Write-Host "`nDetecting GPU and driver version information..."

$gpuName, $gpuType, $currentDriverVersion = Get-GpuData

Write-Host "`n`tDetected graphics card name:`t$($gpuName)"
Write-Host "`tCurrent driver version:`t`t$($currentDriverVersion)"

try {
	$gpuId, $osId, $dch = Get-DriverLookupParameters $gpuName $gpuType
	$driverDownloadInfo = Get-DriverDownloadInfo $gpuId $osId $dch

	$latestDriverVersion = $driverDownloadInfo.Version

	Write-Host "`tLatest driver version:`t`t$($latestDriverVersion)"
}
catch {
	Write-ExitError "`nUnable to determine latest driver version."
}

## Compare installed driver version to latest driver version
if (!$Clean -and ($currentDriverVersion -eq $latestDriverVersion)) {
	Write-ExitError "`nThe latest driver (version $($currentDriverVersion)) is already installed."
}

## Create temporary folder and download the installer
$tempDir = "$($Directory)\NVIDIA"
$dlDriverPath = "$($tempDir)\$($latestDriverVersion).exe"

Write-Host "`nReady to download the latest driver installer to `"$($dlDriverPath)`"..."

$decision = $Host.UI.PromptForChoice("", "`nDo you want to download and install the latest driver?", ("&Yes", "&No"), 0)

if ($decision -eq 0) {
	# Remove existing temporary folder if present
	Remove-Temp $tempDir

	New-Item -Path $tempDir -ItemType "directory" | Out-Null

	Write-Host "`nDownloading latest driver installer..."

	Get-WebFile $driverDownloadInfo.DownloadURL $dlDriverPath
}
else {
	Write-ExitError "Driver download cancelled." -RemoveTemp $tempDir
}

## Extract setup files
$extractDir = "$($tempDir)\$($latestVersion)"

Write-Host "`nDownload finished. Extracting driver files..."

$filesToExtract = "Display.Driver NVI2 EULA.txt ListDevices.txt setup.cfg setup.exe"

if (Test-Path "$($PSScriptRoot)\optional-components.cfg") {
	Get-Content "$($PSScriptRoot)\optional-components.cfg" | Where-Object { $_ -match "^[^\/]+" } | ForEach-Object {
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
	Write-ExitError "`nNo archive program detected. This should not happen." -RemoveTemp $tempDir
}

## Remove unnecessary dependencies from setup.cfg
try {
	Set-Content -Path "$($extractDir)\setup.cfg" -Value (Get-Content -Path "$($extractDir)\setup.cfg" | Select-String -Pattern 'name="\${{(EulaHtmlFile|FunctionalConsentFile|PrivacyPolicyFile)}}' -notmatch)
}
catch {
	Write-ExitError "`nUnable to remove unnecessary dependencies from setup.cfg because it is being used by another process.`nPlease close any conflicting program and try again." -RemoveTemp $tempDir
}

## Install driver
$argumentList = "-passive -noreboot -noeula -nofinish -s"

if ($Clean) {
	$argumentList += " -clean"
}

$installingMessage = "`nInstalling driver..."

$errorMessage = "`nUAC prompt declined or an error occurred during installation."

$cancelled = Start-Installation "$($extractDir)\setup.exe" $argumentList $installingMessage $errorMessage

if ($cancelled) {
	Write-ExitError "`nDriver installation cancelled." -RemoveTemp $tempDir
}

## Remove temporary (downloaded) files
Write-Host "`nRemoving temporary files..."

Remove-Temp $tempDir

## Driver installed; offer a reboot
Write-Host -ForegroundColor Green "`nDriver installed. You may need to reboot to finish installation."

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
exit