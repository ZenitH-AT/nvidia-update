# nvidia-update (ZenitH-AT fork)

Checks for a new version of the NVIDIA Driver, downloads and installs it. Windows 10 only.

## Usage

- Download the [latest release](https://github.com/ZenitH-AT/nvidia-update/releases/latest) or pull `nvidia-update.ps1` and `optional-components.cfg` (optional; allows the user to specify what optional components to include, such as PhysX)
- If `optional-components.cfg` was downloaded, edit the file based on your preferences (similar to NVSlimmer; by default most components are commented out).
- Right click `nvidia-update.ps1` and select `Run with PowerShell` (or run with optional parameters)
- If the script finds a newer version of the NVIDIA driver, it will download and install a slimmed version of it.

### Optional parameters

- `-Clean` - Delete the existing driver and install the latest one
- `-Schedule` - Register a scheduled task to periodically run this script
- `-Desktop` - Override the desktop/notebook check and download the desktop driver; useful when using an external GPU or unable to find a driver
- `-Notebook` - Override the desktop/notebook check and download the notebook driver
- `-Directory <string>` - The directory where the script will download and extract the driver

### How to pass optional parameters

- While holding `shift` press `right click` in the folder with the script
- Select `Open PowerShell window here`
- Enter `.\nvidia-update.ps1 <parameters>` (ex: `.\nvidia-update.ps1 -Clean -Directory "C:\NVIDIA"`)

## Running the script regularly and automatically

You can run the following PowerShell command to download and run the script weekly:

```ps
Invoke-Expression (Invoke-WebRequest -Uri "https://github.com/ZenitH-AT/nvidia-update/raw/master/schedule.ps1").Content
```

## Requirements / Dependencies

A supported archiver (7-Zip or WinRAR) is needed to extract the drivers.

## FAQ

Q. How does the script check for the latest driver version?

> It uses the NVIDIA [AjaxDriverService](https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php).
>
> Example:
>
> ```https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&pfid=877&osID=57&dch=1```
> - **pfid**: Product Family (GPU) ID (e.g. _GeForce RTX 3070_: 933)
> - **osID**: Operating System ID (e.g. _Windows 10 64-bit_: 57)
> - **dch**: Windows Driver Type (_Standard_: 0; _DCH_: 1)
>
> The pfid and osID are determined by reading files in the [ZenitH-AT/nvidia-data](https://github.com/ZenitH-AT/nvidia-data) repository, which queries the NVIDIA Download API ([lookupValueSearch](https://www.nvidia.com/Download/API/lookupValueSearch.aspx)).

## ZenitH-AT's changes

- The script can now self-update.
- Getting the download link now uses NVIDIA's AjaxDriverService. DCH drivers are now supported and there is no risk of the script not working if NVIDIA changes the download URL format. RP packages are not supported.
- The GPU's product family ID (pfid) and operating system ID (osID) are now determined by reading files in the [ZenitH-AT/nvidia-data](https://github.com/ZenitH-AT/nvidia-data) repository, rather than using static values, as older GPUs may use different drivers.
- The user can now choose what optional driver components to include in the installation using the optional-components.cfg file.
- Simplified and improved the archiver program check, download and installation.
- Simplified the OS version and architecture (osBits) check and driver version comparison.
- Simplified the GPU name and driver version retrieval (Get-GpuData).
- Simplified and improved the scheduled task creation.
- The script now checks for an internet connection before proceeding.
- Implemented a function for downloading files (Get-WebFile).
- Driver downloading now uses a custom Get-WebFile function (instead of Start-BitsTransfer, which occasionally caused issues).
- Greatly improved error handling (script is now hopefully idiot-proof).
- Loading animations are shown where applicable (e.g. "Installing driver... /").
- Refactored and reorganised a ton of the code.

## ZenitH-AT's planned changes

- 7-Zip download should get the URL of the latest version instead of using a predefined URL.
- An optional parameter to enable MSI mode should be added.
- Optional components should be selected from within the script and handle dependencies, like NVCleanstall.