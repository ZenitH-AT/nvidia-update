# Script options and information
param (
	[switch] $Clean		= $false, # Will delete old drivers and install the new ones
	[switch] $Schedule 	= $false, # Creates a scheduled task to run to check for driver updates
	[string] $Folder 	= "$env:TEMP" # Downloads and extracts the driver here
)

$Parms = @{
	Version 	= "1.3"
	Author 		= "ZenitH-AT"
	Description 	= "Checks for a new version of the Nvidia driver, downloads and installs it."
}


# Functions
function Remove-Temp {
	param (
		$TempFolder
	)

	try {
		Remove-Item $TempFolder -Recurse -Force
	}
	catch {
		Write-Host -ForegroundColor Gray "`nSome files located at $TempFolder could not be deleted, you may want to remove them manually later."
	}
}

function Write-ExitError {
	param (
		[string] $ErrorMessage,
		[switch] $RemoveTemp,
		[string] $TempFolder
	)

	Write-Host -ForegroundColor Yellow $ErrorMessage

	if ($RemoveTemp) {
		Write-Host "Removing temporary files..."

		Remove-Temp $TempFolder
	}

	Write-Host "Press any key to exit..."

	$host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
	exit
}

function Get-GpuData {
	$gpus = @(Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion)

	foreach ($gpu in $gpus) {
		$gpuName = $gpu.Name

		if ($gpuName -match "^NVIDIA") {
            # Formatting GPU name, accounting for card variants (e.g. 1060 6GB)
            if ($gpuName -match "(?<=NVIDIA )(.*(?= [0-9]+GB)|.*)") {
                $gpuName = $Matches[0].Trim()
            }
            else {
                Write-ExitError "`nUnrecognised GPU name $gpuName. This should not happen."
            }

			$gpuType = "Desktop"

			if ($gpuName -match "(M|Q(X|\s+(LE|GTX|GTS|GS|GT|G))?$|GeForce Go)") {
			   $gpuType = "Notebook" 
			}

			$driverVersion = $gpu.DriverVersion.SubString(7).Remove(1, 1).Insert(3, ".")

			$compatibleGpuFound = $true
			break
		}
	}

	if (!$compatibleGpuFound) {
		Write-ExitError "`nUnable to detect a compatible Nvidia device."
	}

	return $gpuName, $gpuType, $driverVersion
}

function Get-GpuLookupData {
	param (
		[string] $TypeId,
		[string] $ParentId
	)

	# TypeId - 2: product series; 3: product family (GPU); 4: operating system

	$request = "http://www.nvidia.com/Download/API/lookupValueSearch.aspx?"
	$request += "TypeID=$TypeId&ParentID=$ParentId"

	$payload = Invoke-RestMethod $request -UseBasicParsing

	return $payload.LookupValueSearch.LookupValues.LookupValue
}

function Get-DriverLookupParameters {
	param (
		[string] $GpuName,
		[string] $GpuType
	)

	# Determining product series ID
	$seriesData = Get-GpuLookupData 2 1

	foreach ($series in $seriesData) {
		# Limit to desktop/notebook
		if ($GpuType -eq "Notebook") {
			if ($series.Name -notlike "*Notebook*") { continue }
		} else {
			if ($series.Name -like "*Notebook*") { continue }
		}

		$seriesId = $series.Value

		# Determining product family (GPU) ID
		$familyData = Get-GpuLookupData 3 $seriesId

		foreach ($gpu in $familyData) {
			$searchGpuName = $gpu.Name.Replace("NVIDIA", "").Trim()

			if ($searchGpuName -eq $GpuName) {
				$gpuId = $gpu.Value
				break
			}
			elseif ($searchGpuName -like "*/*") {
				if ((($searchGpuName -replace "(\/|nForce).*$","").Trim() -eq $GpuName) -or 
				   (($searchGpuName -replace "(?:[^\s]+\/|(?:[^\s]+\s+){2}\/|.*?(nForce))", "" -replace "\s+", " ").Trim() -eq $GpuName)) {

					$gpuId = $gpu.Value
					break
				}
			}
		}

		# Current product series ID correct, stop searching
		if ($gpuId) { break }
	}

	if (!$gpuId) {
		Write-ExitError "`nUnable to determine GPU product family ID. This should not happen."
	}

	# Determining operating system version and architecture
	$osVersion = "$([Environment]::OSVersion.Version.Major).$([Environment]::OSVersion.Version.Minor)"

	$osArchitecture = 64

	if (([System.IntPtr]::Size -eq 4) -and !(Test-Path env:\PROCESSOR_ARCHITEW6432)) {
		$osArchitecture = 32
	}

	# Determining operating system ID
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

	# Checking if using DCH driver
	$dch = 0

	if ($osVersion -eq 10.0) {
		if (Get-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm -Name "DCHUVen" -ErrorAction Ignore) {
			$dch = 1
		}
	}

	return $gpuId, $osId, $dch
}

function Get-DownloadInfo {
	param (
		[string] $GpuId,
		[string] $OsId,
		[string] $Dch
	)

	$request = "https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?"
	$request += "func=DriverManualLookup&pfid=$GpuId&osID=$OsId&dch=$Dch"

	$payload = Invoke-RestMethod $request -UseBasicParsing

	if ($payload.Success -eq 1) {
		return $payload.IDS[0].downloadInfo
	}
	else {
		Write-ExitError "`nCould not find a driver for your GPU."
	}
}

function Compare-Files {
	param (
		[string] $FilePathA,
		[string] $FilePathB
	)

	if ((Test-Path $FilePathA) -and (Test-Path $FilePathB)) {
		if ((Get-FileHash $FilePathA).hash -eq (Get-FileHash $FilePathB).hash) {
			return $true
		}
	}
}


# Registering scheduled task if the $Schedule parameter is set
if ($Schedule) {
	$taskName = "nvidia-update $($Parms.Version)"
	$description = "NVIDIA Driver Update"
	$scheduleDay = "Sunday"
	$scheduleTime = "12pm"

	$thisFileName = $MyInvocation.MyCommand.Name
	$taskDirectory = "$env:USERPROFILE\nvidia-update"
	$taskScriptPath = "$taskDirectory\$thisFileName"

	$action = New-ScheduledTaskAction -Execute $taskScriptPath
	$settings = New-ScheduledTaskSettingsSet -DontStopIfGoingOnBatteries -RunOnlyIfIdle -IdleDuration 00:10:00 -IdleWaitTimeout 02:00:00
	$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $scheduleDay -At $scheduleTime

	# Copying script and optional driver components file to user profile folder if they aren't present or a different version
	if (!(Test-Path $taskDirectory)) {
		New-Item $taskDirectory -type directory 2>&1 | Out-Null
	}
	
	if (!(Compare-Files ".\$thisFileName" $taskScriptPath)) {
		Copy-Item ".\$thisFileName" -Destination $taskDirectory 2>&1 | Out-Null
	}

	if (Test-Path ".\optional-components.cfg") {
		if (!(Compare-Files ".\optional-components.cfg" "$taskDirectory\optional-components.cfg")) {
			Copy-Item ".\optional-components.cfg" -Destination $taskDirectory 2>&1 | Out-Null
		}
	}
	elseif (Test-Path "$taskDirectory\optional-components.cfg") {
		# Deleting optional-components.cfg from task directory because not present in running directory
		Remove-Item "$taskDirectory\optional-components.cfg"
	}

	# Registering task if it doesnt already exist or if it references a different script version
	$existingTask = Get-ScheduledTask | Where-Object { $_.TaskName -like "nvidia-update*" }
	
	if ($existingTask.TaskName -notlike "*$($Parms.Version)") {
		if ($existingTask) {
			# Removing outdated task(s)
			foreach ($task in $existingTask) {
				Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false
			}
		}

		Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings -Trigger $trigger -Description $description | Out-Null
	}

	Write-Host "This script is scheduled to run every $scheduleDay at $scheduleTime.`n"
}


# Checking internet connection
if (!(Get-NetRoute | ? DestinationPrefix -eq "0.0.0.0/0" | Get-NetIPInterface | where ConnectionState -eq "Connected")) {
	Write-ExitError "No internet connection. After resolving connectivity issues, please try running this script again."
}


# Checking if 7-Zip or WinRAR are installed
$7zInstalled = $false

if (Test-Path "HKLM:\SOFTWARE\7-Zip") {
	$7zpath = Get-ItemProperty -path  HKLM:\SOFTWARE\7-Zip\ -Name Path
	$7zpath = $7zpath.Path
	$7zpathexe = $7zpath + "7z.exe"

	if ((Test-Path $7zpathexe) -eq $true) {
		$archiverProgram = $7zpathexe
		$7zInstalled = $true 
	}
}
else {
    if (Test-Path "HKLM:\SOFTWARE\WinRAR") {
		$winrarpath = Get-ItemProperty -Path HKLM:\SOFTWARE\WinRAR -Name exe64 
		$winrarpath = $winrarpath.exe64

		if ((Test-Path $winrarpath) -eq $true) {
			$archiverProgram = $winrarpath
		}
    }
    else {
		Write-Host "Sorry, but it looks like you don't have a supported archiver.`n"

		$decision = $Host.UI.PromptForChoice("", "Would you like to install 7-Zip now?", ("&Yes", "&No"), 0)

		if ($decision -eq 0) {
			# Download and silently install 7-Zip
			$7zip = "https://www.7-zip.org/a/7z1900-x64.exe"
			$output = "$PSScriptRoot\7Zip.exe"

			(New-Object System.Net.WebClient).DownloadFile($7zip, $output)
			Start-Process "7Zip.exe" -Wait -ArgumentList "/S"

			# Delete the installer once it completes
			Remove-Item "$PSScriptRoot\7Zip.exe"

			# Writing a line to separate the next phase of the script
			Write-Host
		}
		else {
			Write-ExitError "`nA supported archiver is required to use this script."
		}
    }
}


# Getting and displaying GPU and driver information
Write-Host "Detecting GPU and currently installed driver version..."

$gpuName, $gpuType, $driverVersion = Get-GpuData

Write-Host "`n`tDetected GPU`t`t$gpuName"
Write-Host "`tInstalled version`t$driverVersion"

$gpuId, $osId, $dch = Get-DriverLookupParameters $gpuName $gpuType
$downloadInfo = Get-DownloadInfo $gpuId $osId $dch

$latestDriverVersion = $downloadInfo.Version

Write-Host "`tLatest version`t`t$latestDriverVersion"


# Comparing installed driver version to latest driver version
if (!$Clean -and ($latestDriverVersion -eq $driverVersion)) {
	Write-ExitError "`nThe latest driver (version $driverVersion) is already installed."
}


# Creating a temporary folder and downloading the installer
$tempFolder = "$Folder\NVIDIA"
$dlFile = "$tempFolder\$latestDriverVersion.exe"

Write-Host "`nReady to download the latest version to $dlFile...`n"

$decision = $Host.UI.PromptForChoice("", "Are you sure you want to proceed?", ("&Yes", "&No"), 0)

if ($decision -eq 0) {
	if ([System.IO.Directory]::Exists($tempFolder)) {
		Remove-Item $tempFolder -Recurse -Force
	}

	[System.IO.Directory]::CreateDirectory($tempFolder) | Out-Null

	try {
		Start-BitsTransfer -Source $downloadInfo.DownloadURL -Destination $dlFile
	}
	catch {
		Write-ExitError "`nDownload failed. Please try running this script again." -Remove-Temp $tempFolder
	}
}
else {
	Write-ExitError "Download cancelled." -Remove-Temp $tempFolder
}


# Extracting setup files
$extractFolder = "$tempFolder\$latestVersion"

Write-Host "`nDownload finished, extracting driver files now..."

$filesToExtract = "Display.Driver NVI2 EULA.txt ListDevices.txt setup.cfg setup.exe"

if (Test-Path ".\optional-components.cfg") {
	Get-Content ".\optional-components.cfg" | Where-Object {$_ -match "^[^\/]+"} | ForEach-Object {
		$filesToExtract += " " + $_
	}
}

if ($7zInstalled) {
	Start-Process -FilePath $archiverProgram -NoNewWindow -ArgumentList "x -bso0 -bsp1 -bse1 -aoa $dlFile $filesToExtract -o""$extractFolder""" -Wait
}
elseif ($archiverProgram -eq $winrarpath) {
	Start-Process -FilePath $archiverProgram -NoNewWindow -ArgumentList "x $dlFile $extractFolder -IBCK $filesToExtract" -Wait
}
else {
	Write-ExitError "`nNo archive program detected. This should not happen." -Remove-Temp $tempFolder
}


# Removing unnecessary dependencies from setup.cfg
try {
	Set-Content -Path "$extractFolder\setup.cfg" -Value (Get-Content -Path "$extractFolder\setup.cfg" | Select-String -Pattern 'name="\${{(EulaHtmlFile|FunctionalConsentFile|PrivacyPolicyFile)}}' -notmatch)}
}
catch {
	Write-ExitError "`nUnable to remove unnecessary dependencies from setup.cfg because it is being used by another process.`nPlease close any conflicting program and try again." -Remove-Temp $tempFolder
}


# Installing driver
$installArgs = "-passive -noreboot -noeula -nofinish -s"

if ($clean) {
	$installArgs = $installArgs + " -clean"
}

do {
    try {
        $uacAccepted = $true;

        Write-Host -ForegroundColor Cyan "`nInstalling Nvidia driver now..."

        Start-Process -FilePath "$extractFolder\setup.exe" -ArgumentList $installArgs -Wait
    }
    catch {
        $uacAccepted = $false;
    
        Write-Host -ForegroundColor Yellow "`nUAC prompt declined. Please accept the prompt."
        Write-Host "Press any key to try again..."

        $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
} while (!$uacAccepted)


# Removing temporary (downloaded) files
Write-Host "`nRemoving temporary files..."

Remove-Temp $tempFolder


# Driver installed, offering a reboot
Write-Host -ForegroundColor Green "`nDriver installed. You may need to reboot to finish installation.`n"

$decision = $Host.UI.PromptForChoice("", "Would you like to reboot now?", ("&Yes", "&No"), 1)

if ($decision -eq 0) {
	Write-host "`nRebooting now..."; Start-Sleep -s 2; Restart-Computer
}
else {
	Write-Host "`nExiting script in 5 seconds..."; Start-Sleep -s 5
}


# End of script
exit
