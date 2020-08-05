# Script options and information
param (
	[switch] $clean = $false, # Will delete old drivers and install the new ones
	[switch] $schedule = $false, # Creates a scheduled task to run to check for driver updates
	[string] $folder = "$env:TEMP" # Downloads and extracts the driver here
)

$Parms = @{
    Version = "1.1"
    Author = "ZenitH-AT"
    Description = "Checks for a new version of the Nvidia driver, downloads and installs it."
}


# Getter functions
function Get-GpuData {
    $gpus = @(Get-WmiObject Win32_VideoController)

    foreach ($gpu in $gpus) {
        $gpuName = $gpu.Name

        if ($gpuName -match "^NVIDIA") {
            $gpuName = $gpuName.Replace("NVIDIA", "").Trim()
        
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
        Write-Host -ForegroundColor Yellow "`nUnable to detect a compatible Nvidia device."
        Write-Host "Press any key to exit..."

        $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit
    }

    return $gpuName, $gpuType, $driverVersion
}

function Get-GpuLookupData ([string] $typeId, [string] $parentId) {
  # typeId - 2: product series; 3: product family (GPU); 4: operating system

  $request = "http://www.nvidia.com/Download/API/lookupValueSearch.aspx?"
  $request += "TypeID=$typeId&ParentID=$parentId"

  $payload = Invoke-RestMethod $request -UseBasicParsing

  return $payload.LookupValueSearch.LookupValues.LookupValue
}

function Get-DriverLookupParameters ([string] $gpuName, [string] $gpuType) {
    # Determining product series ID
    $seriesData = Get-GpuLookupData 2 1

    foreach ($series in $seriesData) {
        # Limit to desktop/notebook
        if ($gpuType -eq "Notebook") {
            if ($series.Name -notlike "*Notebook*") { continue }
        } else {
            if ($series.Name -like "*Notebook*") { continue }
        }

        $seriesId = $series.Value

        # Determining product family (GPU) ID
        $familyData = Get-GpuLookupData 3 $seriesId

        foreach ($gpu in $familyData) {
            $searchGpuName = $gpu.Name.Replace("NVIDIA", "").Trim()

            if ($searchGpuName -eq $gpuName) {
                $gpuId = $gpu.Value
                break
            }
            elseif ($searchGpuName -like "*/*") {
                if ((($searchGpuName -replace "(\/|nForce).*$","").Trim() -eq $gpuName) -or 
                   (($searchGpuName -replace "(?:[^\s]+\/|(?:[^\s]+\s+){2}\/|.*?(nForce))", "" -replace "\s+", " ").Trim() -eq $gpuName)) {
          
                    $gpuId = $gpu.Value
                    break
                }
            }
        }

        # Current product series ID correct, stop searching
        if ($gpuId) { break }
    }

    if (!$gpuId) {
        Write-Host -ForegroundColor Yellow "`nUnable to determine GPU product family ID. This should not happen."
        Write-Host "Press any key to exit..."

        $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit
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
        Write-Host -ForegroundColor Yellow "`nCould not find a driver supported by your operating system."
        Write-Host "Press any key to exit..."

        $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit
    }

    # Checking if using DCH driver
    $dch = 0

    if ($osVersion -eq 10.0) {
        if (Get-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm -Name 'DCHUVen' -ErrorAction Ignore) {
            $dch = 1
        }
    }

    return $gpuId, $osId, $dch
}

function Get-DownloadInfo ([string] $gpuId, [string] $osId, [string] $dch) {
    $request = "https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?"
    $request += "func=DriverManualLookup&pfid=$gpuId&osID=$osId&dch=$dch"

    $payload = Invoke-RestMethod $request -UseBasicParsing

    if ($payload.Success -eq 1) {
        return $payload.IDS[0].downloadInfo
    }
    else {
        Write-Host -ForegroundColor Yellow "`nCould not find a driver for your GPU."
        Write-Host "Press any key to exit..."

        $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit
    }
}


# Registering scheduled task if the $schedule parameter is set
if ($schedule) {
    $taskName = "nvidia-update $($Parms.Version)"
    $description = "NVIDIA Driver Update"
    $scheduleDay = "Sunday"
    $scheduleTime = "12pm"

    $taskDirectory = "$env:USERPROFILE"
    $thisFileName = $MyInvocation.MyCommand.Name
	$thisScriptPath = "$(Split-Path -parent $PSCommandPath)\$thisFileName"
    $taskScriptPath = "$taskDirectory\$thisFileName"

	$action = New-ScheduledTaskAction -Execute $taskScriptPath
	$settings = New-ScheduledTaskSettingsSet -DontStopIfGoingOnBatteries -RunOnlyIfIdle -IdleDuration 00:10:00 -IdleWaitTimeout 02:00:00
	$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $scheduleDay -At $scheduleTime

	# Copying script to user profile folder if it isn't present
	if ((Get-FileHash $thisScriptPath).hash -ne (Get-FileHash $taskScriptPath).hash) {
		New-Item $taskDirectory -type directory 2>&1 | Out-Null
		Copy-Item .\$thisFileName -Destination $taskDirectory 2>&1 | Out-Null
	}
	
	# Registering task if it doesnt already exist or if it references a different script version
	$existingTask = Get-ScheduledTask | Where-Object {$_.TaskName -like "nvidia-update*" }
	
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
if (!(Get-NetRoute | ? DestinationPrefix -eq '0.0.0.0/0' | Get-NetIPInterface | where ConnectionState -eq 'Connected')) {
	Write-Host -ForegroundColor Yellow "No internet connection. After resolving connectivity issues, please try running this script again."
	Write-Host "Press any key to exit..."

	$host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
	exit
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
			Write-Host -ForegroundColor Yellow "`nA supported archiver is required to use this script."
            Write-Host "Press any key to exit..."

            $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            exit
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
if (!$clean -and ($latestDriverVersion -eq $driverVersion)) {
    Write-Host -ForegroundColor Yellow "`nThe latest driver (version $driverVersion) is already installed."
    Write-Host "Press any key to exit..."
    
    $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit
}


# Creating a temporary folder and downloading the installer
$tempFolder = "$folder\NVIDIA"
$dlFile = "$tempFolder\$latestVersion.exe"

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
		Write-Host -ForegroundColor Yellow "`nDownload failed. Please try running this script again."
		Write-Host "Press any key to exit..."

		$host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
		exit
	}
}
else {
    Write-Host -ForegroundColor Yellow "`nDownload cancelled."
    Write-Host "Press any key to exit..."

    $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit
}


# Extracting setup files
$extractFolder = "$tempFolder\$latestVersion"

Write-Host "`nDownload finished, extracting driver files now..."

$filesToExtract = "Display.Driver NVI2 EULA.txt ListDevices.txt setup.cfg setup.exe"

if (Test-Path .\filesToExtract.txt) {
	Get-Content .\filesToExtract.txt | Where-Object {$_ -match "^[^#]+.*?"} | ForEach-Object {
		$filesToExtract += " " + $_
	}
}

if ($7zInstalled) {
    Start-Process -FilePath $archiverProgram -NoNewWindow -ArgumentList "x -bso0 -bsp1 -bse1 -aoa $dlFile $filesToExtract -o""$extractFolder""" -wait
}
elseif ($archiverProgram -eq $winrarpath) {
    Start-Process -FilePath $archiverProgram -NoNewWindow -ArgumentList 'x $dlFile $extractFolder -IBCK $filesToExtract' -wait
}
else {
    Write-Host -ForegroundColor Yellow "`nNo archive program detected. This should not happen."
    Write-Host "Press any key to exit..."

    $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit
}


# Removing unnecessary dependencies from setup.cfg
(Get-Content "$extractFolder\setup.cfg") | Where-Object { $_ -notmatch 'name="\${{(EulaHtmlFile|FunctionalConsentFile|PrivacyPolicyFile)}}' } | Set-Content "$extractFolder\setup.cfg" -Encoding UTF8 -Force


# Installing driver
Write-Host -ForegroundColor Cyan "`nInstalling Nvidia driver now..."

$installArgs = "-passive -noreboot -noeula -nofinish -s"

if ($clean) {
    $installArgs = $installArgs + " -clean"
}

Start-Process -FilePath "$extractFolder\setup.exe" -ArgumentList $installArgs -wait


# Cleaning up downloaded files
Write-Host "`nDeleting downloaded files..."
Remove-Item $tempFolder -Recurse -Force


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
