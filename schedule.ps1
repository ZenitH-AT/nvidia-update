<#PSScriptInfo
.VERSION 1.7.1
.GUID 544ddf4b-d7df-44b2-abcf-f452793c0fa7
.AUTHOR ZenitH-AT
.LICENSEURI https://raw.githubusercontent.com/ZenitH-AT/nvidia-update/main/LICENSE
.PROJECTURI https://github.com/ZenitH-AT/nvidia-update
.DESCRIPTION Downloads the latest version of nvidia-update and registers a scheduled task. 
#>

## Constant variables and functions
New-Variable -Name "defaultScriptFileName" -Value "nvidia-update.ps1" -Option Constant
New-Variable -Name "defaultConfigFileName" -Value "optional-components.cfg" -Option Constant

function Write-ExitError {
	param (
		[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ErrorMessage
	)

	Write-Host -ForegroundColor Yellow $ErrorMessage
	Write-Host "Press any key to exit..."

	$host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

	exit
}

## Get PowerShell executable
$powershellExe = if ($PSVersionTable.PSVersion.Major -lt 6) { "powershell" } else { "pwsh" }

## Check internet connection
if (-not (Get-NetRoute | Where-Object DestinationPrefix -eq "0.0.0.0/0" | Get-NetIPInterface | Where-Object ConnectionState -eq "Connected")) {
	Write-ExitError "No internet connection. After resolving connectivity issues, please try running this script again."
}

## Register scheduled task
$taskDir = "$($env:USERPROFILE)\nvidia-update"
$taskPath = "$($taskDir)\$($defaultScriptFileName)"

if (-not (Test-Path $taskDir)) {
	New-Item -Path $taskDir -ItemType "directory" | Out-Null
}

# Get latest release version
try {
	$latestReleaseUrl = [System.Net.WebRequest]::Create("https://github.com/ZenitH-AT/nvidia-update/releases/latest").GetResponse().ResponseUri.OriginalString
	$latestReleaseVersion = $latestReleaseUrl.Split("/")[-1]
}
catch {
	Write-ExitError "Unable to determine latest script version. Please try running this script again."
}

$taskName = "nvidia-update $($latestReleaseVersion)"
$description = "NVIDIA Driver Update"
$scheduleDay = "Sunday"
$scheduleTime = "12pm"

$action = New-ScheduledTaskAction -Execute $powershellExe -Argument "-File `"$($taskPath)`" $($MyInvocation.UnboundArguments)"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -RunOnlyIfIdle -IdleDuration 00:10:00 -IdleWaitTimeout 04:00:00
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $scheduleDay -At $scheduleTime

# Register task if it doesn't already exist or if it references a different script version (and delete outdated tasks)
$registerTask = $true
$existingTasks = Get-ScheduledTask | Where-Object TaskName -match "^nvidia-update."

foreach ($existingTask in $existingTasks) {
	$registerTask = $false

	if ($existingTask.TaskName -notlike "*$($latestReleaseVersion)") {
		Unregister-ScheduledTask -TaskName $existingTask.TaskName -Confirm:$false

		$registerTask = $true
	}
}

if ($registerTask) {
	# Download latest release files
	try {
		Invoke-WebRequest -Uri "$($latestReleaseUrl.Replace("tag", "download"))/$($defaultScriptFileName)" -OutFile $taskPath
		Invoke-WebRequest -Uri "$($latestReleaseUrl.Replace("tag", "download"))/$($defaultConfigFileName)" -OutFile "$($taskDir)\$($defaultConfigFileName)"
	}
	catch {
		Write-ExitError "Downloading script files failed. Please try running this script again."
	}

	Write-Host "Downloaded the latest script to `"$($taskPath)`".`n"
	Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings -Trigger $trigger -Description $description | Out-Null
	Write-Host -ForegroundColor Green "Scheduled task registered."
}
else {
	Write-Host -ForegroundColor Gray "Scheduled task for the latest script version is already registered."
}

$decision = $Host.UI.PromptForChoice("", "`nWould you like to run nvidia-update?", ("&Yes", "&No"), 0)

if ($decision -eq 0) {
	Start-Process -FilePath "powershell" -ArgumentList "-File `"$($taskPath)`""
}

Write-Host "`nExiting script in 5 seconds..."
Start-Sleep -Milliseconds 5000