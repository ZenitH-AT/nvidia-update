# nvidia-update

Checks for a new version of the NVIDIA Driver, downloads and installs it. Windows 10+ only and PowerShell 6+ recommended.

Fork of [lord-carlos/nvidia-update](https://github.com/lord-carlos/nvidia-update).

## Usage

- Download the [latest release](https://github.com/ZenitH-AT/nvidia-update/releases/latest); `optional-components.cfg` is optional
- If downloaded, modify `optional-components.cfg` to specify what optional components to include (e.g., PhysX; works like [NVSlimmer](https://forums.guru3d.com/threads/nvslimmer-nvidia-driver-slimming-utility.423072))
	- If this file isn't present in the same directory as the script, only essential driver components (not listed in this file) will be installed
- Right click `nvidia-update.ps1` and select `Run with PowerShell` (or run with optional parameters via a terminal; see below)
- If the script finds a newer version of the NVIDIA driver, it will download and install it

### Optional parameters

- `-Force` - Install the driver even if the latest driver is already installed
- `-Clean` - Remove any existing driver and its configuration data
- `-Msi` - Enable message-signalled interrupts (MSI) after driver installation (must be enabled every time); requires elevation
- `-Schedule` - Register a scheduled task to run this script weekly; arguments passed alongside this will be appended to the scheduled task action
- `-GpuId <string/int>` - Manually specify product family (GPU) ID rather than determine automatically
- `-OsId <string/int>` - Manually specify operating system ID rather than determine automatically
- `-Desktop` - Override the desktop/notebook check and download the desktop driver; useful when using an external GPU or unable to find a driver
- `-Notebook` - Override the desktop/notebook check and download the notebook driver
- `-DownloadDirectory <string>` - Override the directory where the script will download and extract the driver package
- `-KeepDownload` - Don't delete the downloaded driver package after installation (or if an error occurred)
- `-GpuDataFileUrl <string>` - Override the GPU data JSON file URL/path for determining product family (GPU) ID
- `-OsDataFileUrl <string>` - Override the OS data JSON file URL/path for determining operating system ID
- `-AjaxDriverServiceUrl <string>` - Override the AjaxDriverService URL; e.g., replace ".com" in the default value ("https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php") with ".cn" to solve connectivity issues

### How to pass optional parameters

- While holding `⇧ Shift`, right-click in the folder with the script
- Select `Open PowerShell window here`
- Enter `.\nvidia-update.ps1 <parameters>` (e.g., `.\nvidia-update.ps1 -Clean -DownloadDirectory "C:\NVIDIA"`)

## Automatically running the script periodically

Run the following PowerShell command to download the latest release files and create a scheduled task to run the script weekly with no optional parameters:

```ps1
Invoke-Expression (Invoke-WebRequest -Uri "https://github.com/ZenitH-AT/nvidia-update/raw/main/schedule.ps1")
```

To specify optional parameters for the scheduled task action, run a command similar to the following example, instead:

```ps1
Invoke-Command ([ScriptBlock]::Create(".{$(Invoke-WebRequest -Uri "https://github.com/ZenitH-AT/nvidia-update/raw/main/schedule.ps1")} -Force -DownloadDir `"'C:\Users\user\NVIDIA download'`""))
```

Surrounding an argument with `` `"' `` and `` '`" `` is required if it has spaces.

## Requirements / Dependencies

A supported archiver (7-Zip or WinRAR) is required to extract driver files.

## How does the script check for the latest driver version?

It uses the NVIDIA [AjaxDriverService](https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php).

Example:

`https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&pfid=877&osID=57&dch=1`

- **pfid**: Product Family (GPU) ID (e.g., _GeForce RTX 3070_: 933)
- **osID**: Operating System ID (e.g., _Windows 10 64-bit_: 57)
- **dch**: Windows Driver Type (_Standard_: 0; _DCH_: 1)

The pfid and osID are determined by reading files in the [ZenitH-AT/nvidia-data](https://github.com/ZenitH-AT/nvidia-data) repository, which queries the NVIDIA Download API ([lookupValueSearch](https://www.nvidia.com/Download/API/lookupValueSearch.aspx)).

## How does this differ from lord-carlos/nvidia-update?

- The script can now self-update.
- Getting the download link now uses NVIDIA's AjaxDriverService. DCH drivers are now supported and there is no risk of the script not working if NVIDIA changes the download URL format. RP packages are not supported.
- The GPU's product family ID (pfid) and operating system ID (osID) can now be determined by reading files in the [ZenitH-AT/nvidia-data](https://github.com/ZenitH-AT/nvidia-data) repository, rather than using static values, as older GPUs may use different drivers.
- The user can now choose what optional driver components to include in the installation using the optional-components.cfg file.
- The user can now enable message-signalled interrupts after driver installation by setting the `-Msi` optional parameter.
- Simplified and improved checking whether to use the desktop or notebook driver and implemented parameters to override the check.
- Simplified and improved the archiver program check, download and installation.
- Simplified the OS version and architecture (`$osBits`) check and driver version comparison.
- Simplified the GPU name and driver version retrieval (`Get-GpuData`).
- Simplified and improved the scheduled task creation; now supports PowerShell 6+.
- The script now checks for an internet connection before proceeding.
- Implemented a function for downloading files (`Get-WebFile`).
	- Driver downloading now uses this function, rather than `Start-BitsTransfer`, which occasionally [caused issues](https://i.imgur.com/TcCenpo.png).
- Greatly improved error handling (script is now hopefully idiot-proof).
- Loading animations are shown where applicable (e.g., "Installing driver... /").
- Refactored and reorganised a ton of the code.
- Implemented a few changes and fixes from the [BearGrylls](https://github.com/BearGrylls/nvidia-update) and [fl4pj4ck](https://github.com/fl4pj4ck/nvidia-update) forks, as well as [TinyNvidiaUpdateChecker](https://github.com/ElPumpo/TinyNvidiaUpdateChecker)

## Planned changes

- Optional components should be selected from within the script and handle dependencies, like [NVCleanstall](https://www.techpowerup.com/nvcleanstall/).
	- Dependencies can be determined by recursively reading `.nvi` files
	- Will require implementing a simple TUI