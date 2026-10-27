# nvidia-update

Comprueba si hay una versión nueva del driver de NVIDIA y te avisa, o la descarga e instala **solo con el driver gráfico**, sin GeForce Experience, NVIDIA App ni telemetría. Solo Windows 10/11; se recomienda PowerShell 7 o superior.

Fork de [ZenitH-AT/nvidia-update](https://github.com/ZenitH-AT/nvidia-update) (abandonado desde 2023), que a su vez es un fork de [lord-carlos/nvidia-update](https://github.com/lord-carlos/nvidia-update).

## Cambios respecto a ZenitH-AT/nvidia-update

### Seguridad
- **Sin autoactualización.** El original descargaba y ejecutaba versiones nuevas del script sin verificar nada. Ahora se actualiza a mano (`git pull`).
- **Verificación de la firma del driver.** Antes de extraer o ejecutar nada, se comprueba que el instalador descargado y el `setup.exe` extraído tienen una firma Authenticode válida de **NVIDIA Corporation**. Si no, no se instala.
- **Solo descarga de servidores de NVIDIA** (`*.nvidia.com`), y siempre por HTTPS.
- **7-Zip se instala con winget**, que verifica el hash del instalador, en lugar de descargar la versión 22.01 de 2022 sin comprobar nada.
- Eliminado `schedule.ps1`, que descargaba y ejecutaba el script del repo original. Ahora se usa `-Schedule`.

### Funcionalidad
- **Modo solo aviso (`-NotifyOnly`).** Comprueba si hay driver nuevo y muestra una notificación de Windows, sin descargar ni instalar nada.
- **Funciona con GPUs nuevas.** La lista de GPUs de ZenitH-AT/nvidia-data no se actualiza desde abril de 2025 (no incluye, por ejemplo, la RTX 5060 o la RTX 5050). Si tu GPU no está, o la consulta a NVIDIA falla, se usa como reserva la base de datos de NVCleanstall (`gpu.me`), que busca la GPU por su ID PCI. Es la misma reserva que usa TinyNvidiaUpdateChecker.
- **Solo el driver gráfico por defecto.** `optional-components.cfg` ya no incluye el audio HD, PhysX ni el driver USB-C. Descomenta lo que necesites.
- **Tarea programada al iniciar sesión y una vez al día**, en una ventana oculta y sin esperar respuesta. Antes era semanal, solo si el PC estaba inactivo, y en una ventana que se quedaba esperando a que pulsaras algo.
- La comparación de versiones es numérica: ya no ofrece "actualizar" a un driver más antiguo que el instalado.

### Errores corregidos del original
- `-Silent` relanzaba el script sin el propio `-Silent`, así que se quedaba esperando respuesta en una ventana oculta.
- `-Schedule` no pasaba a la tarea los parámetros indicados (`$MyInvocation.UnboundArguments` siempre estaba vacío).
- En modo silencioso, si rechazabas el aviso de UAC, lo volvía a pedir sin parar.
- La opción "Yes (upgrade to DCH driver)" no se aplicaba nunca (usaba una variable `$decision` que no existía).
- Los datos de sistema operativo se cargaban comprobando la URL de los datos de GPU.
- Ya no necesita 7-Zip si no hay nada que instalar.

## Uso

1. Descarga o clona este repositorio (por ejemplo en `C:\Tools\nvidia-update`).
2. Si lo necesitas, edita `optional-components.cfg` para añadir componentes (por ejemplo `HDAudio` si sacas el sonido por HDMI o DisplayPort).
   - Si este archivo no está junto al script, solo se instalan los componentes esenciales.
3. Abre PowerShell en esa carpeta y ejecuta:

```ps1
# Comprobar e instalar si hay versión nueva (te pregunta antes de instalar)
.\nvidia-update.ps1

# Solo comprobar y avisar con una notificación
.\nvidia-update.ps1 -NotifyOnly
```

Si Windows no te deja ejecutar scripts, ejecútalo así: `powershell -ExecutionPolicy Bypass -File .\nvidia-update.ps1`.

### Comprobación automática

```ps1
# Avisar con una notificación al iniciar sesión y cada día a las 12:00 (recomendado)
.\nvidia-update.ps1 -Schedule -NotifyOnly

# O bien instalar automáticamente (aparecerá el aviso de UAC al instalar)
.\nvidia-update.ps1 -Schedule
```

La tarea se llama `nvidia-update 1.16.0` y la puedes ver o borrar en el Programador de tareas. Ejecuta el script desde la ruta donde esté cuando la registres, así que si lo mueves de carpeta, vuelve a ejecutar `-Schedule`. Si el registro falla, prueba a ejecutar PowerShell como administrador.

### Parámetros opcionales

- `-Silent` - No pregunta nada; usa la opción por defecto en todas las preguntas
- `-NotifyOnly` - Solo comprueba si hay driver nuevo y muestra una notificación de Windows; no descarga ni instala nada
- `-LogFilePath <string>` - Añade la salida a un archivo de texto
- `-Force` - Instala el driver aunque ya tengas la última versión
- `-Clean` - Borra el driver existente y su configuración (instalación limpia)
- `-Msi` - Activa las interrupciones MSI (message-signalled interrupts) tras instalar el driver (hay que activarlas en cada instalación); requiere ejecutar como administrador
- `-Schedule` - Registra una tarea programada que ejecuta el script en silencio al iniciar sesión y cada día; los demás parámetros que pongas se pasan a la tarea
- `-GpuId <string/int>` - Indica a mano el ID de familia de producto (GPU) en lugar de detectarlo
- `-OsId <string/int>` - Indica a mano el ID de sistema operativo en lugar de detectarlo
- `-Desktop` - Fuerza el driver de sobremesa; útil con una GPU externa o si no encuentra el driver
- `-Notebook` - Fuerza el driver de portátil
- `-DownloadDirectory <string>` - Cambia la carpeta donde se descarga y extrae el driver
- `-KeepDownload` - No borra el instalador descargado después de instalar (o si hay un error)
- `-GpuDataFileUrl <string>` - Cambia la URL o ruta del JSON de GPUs usado para obtener el ID de familia de producto
- `-OsDataFileUrl <string>` - Cambia la URL o ruta del JSON de sistemas operativos usado para obtener el ID de sistema operativo
- `-GpuMetadataUrl <string>` - Cambia la URL de la base de datos de reserva (por defecto `https://gpu.me/v1/index2.json`)
- `-AjaxDriverServiceUrl <string>` - Cambia la URL de AjaxDriverService; por ejemplo, cambia ".com" por ".cn" si tienes problemas de conexión

## Requisitos

- Un programa para extraer el driver: 7-Zip o WinRAR. Si no tienes ninguno, el script ofrece instalar 7-Zip con winget.

## ¿Cómo encuentra la última versión del driver?

1. Detecta tu GPU y la versión del driver instalado.
2. Busca el ID de familia de producto de tu GPU (pfid) y el ID de tu sistema operativo (osID) en [ZenitH-AT/nvidia-data](https://github.com/ZenitH-AT/nvidia-data) y consulta la API de NVIDIA [AjaxDriverService](https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php). Ejemplo:

   `https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&pfid=877&osID=57&dch=1`

   - **pfid**: ID de familia de producto (GPU) (por ejemplo, _GeForce RTX 3070_: 933)
   - **osID**: ID de sistema operativo (por ejemplo, _Windows 10 64-bit_: 57)
   - **dch**: tipo de driver de Windows (_Standard_: 0; _DCH_: 1)

3. Si tu GPU no está en esa lista o la consulta falla, busca tu GPU por su ID PCI en la base de datos de NVCleanstall (`gpu.me`) y construye la URL de descarga en `international.download.nvidia.com`.
4. En cualquier caso, el instalador descargado solo se ejecuta si tiene una firma válida de NVIDIA Corporation.
