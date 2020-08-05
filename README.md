# nvidia-update (ZenitH-AT fork)

Checks for a new version of the Nvidia Driver, downloads and installs it.

## ZenitH-AT's changes

* Getting the download link now uses Nvidia's AjaxDriverService. **DCH drivers are now supported** and there is no risk of the script not working if Nvidia changes the download URL format. RP packages are not supported (yet).
* The user can easy choose what optional driver components to install using the .txt file.
* The GPU's product family ID (pfid) is now checked and passed to AjaxDriverService (e.g. RTX 2060 ID is 888), as older GPUs may use different drivers.
* Simplified the archiver program check.
* Simplified the OS version and architecture check and driver version comparison.
* Simplified and improved the scheduled task creation.
* The script now checks for an internet connection before proceeding.
* Refactored and reorganised a lot of the code.

## ZenitH-AT's planned changes
* 7-Zip download should get the URL of the latest version instead of using a predefined URL.

## Usage

* Download `nvidia.ps1`
* Right click and select `Run with PowerShell`
* If the script finds a newer version of the nvidia driver online it will download and install it.

### Optional parameters

* `-clean` - deletes the old driver and installs the newest one
* `-schedule` - creates a scheduled task after the driver has been installed, to periodically check for new drivers
* `-folder <path_to_folder>` - the directory where the script will download and extract the new driver

### How to pass the optional parameters

* While holding `shift` press `right click` in the folder with the script
* Select `Open PowerShell window here`
* Enter `.\nvidia.ps1 <parameters>` (ex: `.\nvidia.ps1 -clean -folder C:\NVIDIA`)

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

Q. How do we check for the latest driver version from Nvidia website ?

> We use the NVIDIA [Advanced Driver Search](https://www.nvidia.com/Download/Find.aspx).
>
> Example:
> ```https://www.nvidia.com/Download/processFind.aspx?psid=101&pfid=845&osid=57&lid=1&whql=1&ctk=0&dtcid=0```
>
> * **psid**: Product Series ID (_GeForce 10 Series_: 101)
> * **pfid**: Product ID (e.g. _GeForce GTX 1080 Ti_: 845)
> * **osid**: Operating System ID (e.g. _Windows 10 64-bit_: 57)
> * **lid**: Language ID (e.g. _English (US)_: 1)
> * **whql**: Driver channel (_Certified_: 0, Beta: 1)
> * **dtcid**: Windows Driver Type (_Standard_: 0, DCH: 1)

Q. Why DCH drivers are not supported ?

> While the DCH driver is exactly the same as the Standard one, the way DCH drivers are packaged differs.
>
> * Standard: To upgrade, you have either to download/install manually new drivers, or let GeForce Experience doing it.
> * DCH: Windows Update will download and install the NVIDIA DCH Display Driver.
>
> For more informations, you can read the [NVIDIA Display Drivers for Windows 10 FAQ](https://nvidia.custhelp.com/app/answers/detail/a_id/4777/~/nvidia-dch%2Fstandard-display-drivers-for-windows-10-faq)
