# nvidia-update (ZenitH-AT fork)

Checks for a new version of the Nvidia driver, downloads and installs it.

## Usage

* Download `nvidia-update.ps1` and `optional-components.txt` (optional)
* Right click and select `Run with PowerShell`
* If the script finds a newer version of the nvidia driver online it will download and install it.

### Optional parameters

* `-clean` - deletes the old driver and installs the newest one
* `-schedule` - creates a scheduled task after the driver has been installed, to periodically check for new drivers
* `-folder <path_to_folder>` - the directory where the script will download and extract the new driver

### How to pass the optional parameters

* While holding `shift` press `right click` in the folder with the script
* Select `Open PowerShell window here`
* Enter `.\nvidia-update.ps1 <parameters>` (ex: `.\nvidia-update.ps1 -clean -folder C:\NVIDIA`)

## Running the script regularly and automatically

You can use `SchTasks` to run the script automatically with:

```ps
$path = "C:"
New-Item -ItemType Directory -Force -Path $path | Out-Null
Invoke-WebRequest -Uri "https://github.com/ZenitH-AT/nvidia-update/raw/master/nvidia.ps1" -OutFile "$path\nvidia.ps1" -UseBasicParsing
SchTasks /Create /SC DAILY /TN "Nvidia-Updater" /TR "powershell -NoProfile -ExecutionPolicy Bypass -File $path\nvidia.ps1" /ST 10:00
schtasks /run /tn "Nvidia-Updater"
```

## Requirements / Dependencies

7-Zip or WinRar are needed to extract the drivers.

## FAQ

Q. How do we check for the latest driver version from Nvidia website?

> We use the NVIDIA [AjaxDriverService](https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php).
>
> Example:
> ```https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&pfid=877&osID=57&dch=1```
>
> * **pfid**: Product Family (GPU) ID (e.g. _GeForce GTX 2080 Ti_: 877)
> * **osID**: Operating System ID (e.g. _Windows 10 64-bit_: 57)
> * **dch**: Windows Driver Type (_Standard_: 0, _DCH_: 1)

Q. The "NVIDIA Control Panel" is missing after installing the DCH driver! How can I fix this?

> We use the NVIDIA [AjaxDriverService](https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php).
> This is a very frustrating issue that a minority of users face when using this script for the first time.
> 
> Some solutions include:
> 
> * Restarting your computer (sometimes two restarts are required)
> * Running the script again with the `-clean` parameter (this seems to fix the issue for most but you will need to reconfigure any control panel and/or driver settings)

## ZenitH-AT's changes

* Getting the download link now uses Nvidia's AjaxDriverService. **DCH drivers are now supported** and there is no risk of the script not working if Nvidia changes the download URL format. RP packages are not supported (yet).
* The user can now choose what optional driver components to include in the installation using the optional-components.txt file.
* The GPU's product family ID (pfid) is now checked and passed to AjaxDriverService (e.g. RTX 2060 ID is 888), as older GPUs may use different drivers.
* Simplified the archiver program check.
* Simplified the OS version and architecture check and driver version comparison.
* Simplified and improved the scheduled task creation.
* The script now checks for an internet connection before proceeding.
* Refactored and reorganised a lot of the code.

## ZenitH-AT's planned changes
* Series data should not be restricted to GeForce cards (at the moment the script cannot update TITAN GPUs, Quadro GPUs, etc.).
* 7-Zip download should get the URL of the latest version instead of using a predefined URL.
