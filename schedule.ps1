<#PSScriptInfo
.VERSION 1.0
.GUID 544ddf4b-d7df-44b2-abcf-f452793c0fa7
.AUTHOR ZenitH-AT
.LICENSEURI https://raw.githubusercontent.com/ZenitH-AT/nvidia-update/master/LICENSE
.PROJECTURI https://github.com/ZenitH-AT/nvidia-update
.DESCRIPTION Downloads the latest version of nvidia-update and registers a scheduled task. 
#>


## Constant variables and functions
New-Variable -Name "rawRepo" -Value "https://raw.githubusercontent.com/ZenitH-AT/nvidia-update/master" -Option Constant

function Write-ExitError {
    param (
        [string] $ErrorMessage
    )
    
    Write-Host -ForegroundColor Yellow $ErrorMessage
    Write-Host "Press any key to exit..."

    $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

    exit
}


## Check internet connection
if (!(Get-NetRoute | Where-Object DestinationPrefix -eq "0.0.0.0/0" | Get-NetIPInterface | Where-Object ConnectionState -eq "Connected")) {
    Write-ExitError "No internet connection. After resolving connectivity issues, please try running this script again."
}


## Register scheduled task
$taskDir = "$($env:USERPROFILE)\nvidia-update"
$taskPath = "$($taskDir)\nvidia-update.ps1"

if (!(Test-Path $taskDir)) {
    New-Item -Path $taskDir -ItemType "directory" | Out-Null
}

# Get latest script version from repository
try {
    $latestScriptVersion = Invoke-WebRequest -Uri "$($rawRepo)/current-version.txt"
}
catch {
    Write-ExitError "Unable to determine latest script version. Please try running this script again."
}

$taskName = "nvidia-update $($latestScriptVersion)"
$description = "NVIDIA Driver Update"
$scheduleDay = "Sunday"
$scheduleTime = "12pm"

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $taskPath
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -RunOnlyIfIdle -IdleDuration 00:10:00 -IdleWaitTimeout 04:00:00
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $scheduleDay -At $scheduleTime

# Register task if it doesn't already exist or if it references a different script version (and delete outdated tasks)
$registerTask = $true

$existingTasks = Get-ScheduledTask | Where-Object { $_.TaskName -match "^nvidia-update." }

foreach ($existingTask in $existingTasks) {
    $registerTask = $false

    if ($existingTask.TaskName -notlike "*$($latestScriptVersion)") {
        Unregister-ScheduledTask -TaskName $existingTask.TaskName -Confirm:$false

        $registerTask = $true
    }
}

if ($registerTask) {
    # Download lastest script files
    try {
        Invoke-WebRequest -Uri "$($rawRepo)/nvidia-update.ps1" -OutFile $taskPath
        Invoke-WebRequest -Uri "$($rawRepo)/optional-components.cfg" -OutFile "$($taskDir)\optional-components.cfg"
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

$decision = $Host.UI.PromptForChoice("", "Would you like to run nvidia-update?", ("&Yes", "&No"), 0)

if ($decision -eq 0) {
    Start-Process PowerShell $taskPath
}

Write-Host "`nExiting script in 5 seconds..."

Start-Sleep -s 5

## End of script
exit