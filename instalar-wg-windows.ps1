#Requires -Version 5.1
<#
.SYNOPSIS
    Instalador desatendido de WireGuard para PC Windows contra el hub RB5009.

.DESCRIPTION
    Equivalente Windows de instalar-wg-scada.sh. Instala el cliente oficial de
    WireGuard si falta, genera (o reutiliza) el par de claves y la PSK, escribe
    el .conf, registra el tunel como servicio de Windows y lo deja arrancando
    solo.

    Politica de ruteo: prefijos estrictos. Nada de 0.0.0.0/0, nada mas ancho que
    /24. Cada entrada de AllowedIPs es una ruta especifica que WireGuard instala
    sola en la tabla de ruteo de Windows; no se ejecuta ningun 'route add'.
    El resto del trafico de la PC (internet, LAN local, impresoras) queda intacto.

    No toca el Firewall de Windows ni ninguna otra regla del equipo. Todo el
    filtrado se hace en el RB5009.

.PARAMETER IpOverlay
    Direccion de la PC dentro de la overlay, con mascara /32. Ej: 10.255.0.20/32

.PARAMETER HubPubkey
    Clave publica del hub RB5009.

.PARAMETER HubEndpoint
    IP publica y puerto del hub. Ej: 200.0.0.1:51820

.PARAMETER RedesReco
    Lista de redes LAN de los sitios RECO a alcanzar. Nada mas ancho que /24.
    Ej: 10.20.1.0/24,10.20.2.0/24

.PARAMETER RoutersReco
    Lista de IPs overlay de los routers de sitio, sin mascara (se usan como /32).
    Ej: 10.255.1.1,10.255.2.1

.PARAMETER HostsExtra
    IPs sueltas adicionales de la overlay a alcanzar, sin mascara. Sirve para
    llegar al propio SCADA. Ej: 10.255.0.10

.PARAMETER Nombre
    Nombre del tunel, del adaptador y del servicio. Por defecto wg-scada.

.PARAMETER Breve
    Imprime unicamente PUBLIC-KEY= y PRESHARED-KEY= y termina.

.PARAMETER Desinstalar
    Da de baja el servicio del tunel y borra el adaptador. Conserva las claves
    salvo que se pase -BorrarClaves.

.PARAMETER BorrarClaves
    Junto con -Desinstalar, elimina tambien el directorio de claves. Ojo: si las
    borras, una reinstalacion genera identidad nueva y hay que actualizar el peer
    en el RB5009.

.PARAMETER Estado
    Muestra el estado del tunel y las rutas que instalo, y termina.

.PARAMETER MsiPath
    Ruta a un MSI de WireGuard ya descargado, para equipos sin salida a internet.

.PARAMETER SinWatchdog
    No instala la tarea programada de vigilancia. El servicio igual queda en
    arranque automatico y con acciones de recuperacion.

.PARAMETER WatchdogMinutos
    Cada cuantos minutos corre el watchdog. Por defecto 5.

.PARAMETER DryRun
    Muestra lo que haria sin tocar nada.

.EXAMPLE
    .\instalar-wg-windows.ps1 -IpOverlay 10.255.0.20/32 `
        -HubPubkey 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=' `
        -HubEndpoint 200.0.0.1:51820 `
        -RedesReco 10.20.1.0/24 -RoutersReco 10.255.1.1 -Breve
#>

[CmdletBinding(DefaultParameterSetName = 'Instalar')]
param(
    [Parameter(ParameterSetName = 'Instalar', Mandatory = $true)]
    [string]$IpOverlay,

    [Parameter(ParameterSetName = 'Instalar', Mandatory = $true)]
    [string]$HubPubkey,

    [Parameter(ParameterSetName = 'Instalar', Mandatory = $true)]
    [string]$HubEndpoint,

    [Parameter(ParameterSetName = 'Instalar')]
    [string[]]$RedesReco = @(),

    [Parameter(ParameterSetName = 'Instalar')]
    [string[]]$RoutersReco = @(),

    [Parameter(ParameterSetName = 'Instalar')]
    [string[]]$HostsExtra = @(),

    [Parameter(ParameterSetName = 'Instalar')]
    [string]$HubOverlay = '10.255.0.1',

    [Parameter(ParameterSetName = 'Instalar')]
    [int]$Mtu = 1420,

    [Parameter(ParameterSetName = 'Instalar')]
    [int]$Keepalive = 25,

    [Parameter(ParameterSetName = 'Instalar')]
    [string]$MsiPath,

    [Parameter(ParameterSetName = 'Instalar')]
    [switch]$Breve,

    [Parameter(ParameterSetName = 'Instalar')]
    [switch]$SinWatchdog,

    [Parameter(ParameterSetName = 'Instalar')]
    [ValidateRange(1, 60)]
    [int]$WatchdogMinutos = 5,

    [Parameter(ParameterSetName = 'Desinstalar', Mandatory = $true)]
    [switch]$Desinstalar,

    [Parameter(ParameterSetName = 'Desinstalar')]
    [switch]$BorrarClaves,

    [Parameter(ParameterSetName = 'Estado', Mandatory = $true)]
    [switch]$Estado,

    [Parameter(ParameterSetName = 'Instalar')]
    [Parameter(ParameterSetName = 'Desinstalar')]
    [string]$Nombre = 'wg-scada',

    [Parameter(ParameterSetName = 'Instalar')]
    [Parameter(ParameterSetName = 'Desinstalar')]
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$VERSION      = '1.1'
$WG_HOME      = Join-Path $env:ProgramFiles 'WireGuard'
$WG_EXE       = Join-Path $WG_HOME 'wireguard.exe'
$WG_CLI       = Join-Path $WG_HOME 'wg.exe'
$DATA_DIR     = Join-Path $env:ProgramData 'wg-scada'
$INSTALLER_URL = 'https://download.wireguard.com/windows-client/wireguard-installer.exe'

# ---------------------------------------------------------------- utilidades

function Info  ([string]$m) { Write-Host "[+] $m" -ForegroundColor Cyan }
function Ok    ([string]$m) { Write-Host "[OK] $m" -ForegroundColor Green }
function Aviso ([string]$m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Morir ([string]$m) { Write-Host "[X] $m" -ForegroundColor Red; exit 1 }

function Ejecutar {
    param([string]$Descripcion, [scriptblock]$Bloque)
    if ($DryRun) { Write-Host "[dry-run] $Descripcion" -ForegroundColor DarkGray; return $null }
    & $Bloque
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-Ipv4 {
    param([string]$Ip)
    if ($Ip -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return $false }
    foreach ($o in $Ip.Split('.')) { if ([int]$o -gt 255) { return $false } }
    return $true
}

function Test-Cidr {
    param([string]$Cidr)
    if ($Cidr -notmatch '^(.+)/(\d{1,2})$') { return $false }
    $ip     = $Matches[1]
    $prefix = [int]$Matches[2]
    if (-not (Test-Ipv4 $ip)) { return $false }
    if ($prefix -lt 0 -or $prefix -gt 32) { return $false }
    return $true
}

# Politica de prefijos estrictos: nada mas ancho que /24. Un prefijo ancho aca
# no "abre" nada en el hub, pero si secuestra rutas de la PC hacia esa red y
# ademas amplia lo que el equipo acepta como origen valido desde el tunel.
function Assert-PrefijoEstricto {
    param([string]$Cidr)
    if (-not (Test-Cidr $Cidr)) { Morir "Prefijo invalido: $Cidr (formato esperado A.B.C.D/M)" }
    $prefix = [int]($Cidr -replace '^.+/', '')
    if ($prefix -lt 24) {
        Morir "Prefijo demasiado ancho: $Cidr. La politica no admite nada mas ancho que /24."
    }
    if ($Cidr -eq '0.0.0.0/0') {
        Morir "0.0.0.0/0 esta prohibido: mandaria todo el trafico de la PC por el tunel."
    }
}

function Test-ClaveWg {
    param([string]$K)
    return ($K -match '^[A-Za-z0-9+/]{42}[A-Za-z0-9+/=]=$')
}

function Restringir-Acl {
    param([string]$Ruta)
    # Equivalente al 0600 de Linux: solo SYSTEM y Administradores. Se corta la
    # herencia para que no reaparezcan los grupos heredados de ProgramData.
    $acl = Get-Acl $Ruta
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($r in @($acl.Access)) { [void]$acl.RemoveAccessRule($r) }
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $cuenta = (New-Object Security.Principal.SecurityIdentifier($sid)).Translate([Security.Principal.NTAccount])
        $regla  = New-Object Security.AccessControl.FileSystemAccessRule(
            $cuenta, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($regla)
    }
    Set-Acl -Path $Ruta -AclObject $acl
}

# ------------------------------------------------------- instalar WireGuard

function Instalar-WireGuard {
    if (Test-Path $WG_EXE) {
        Ok "WireGuard ya esta instalado en $WG_HOME"
        return
    }

    Info 'WireGuard no esta instalado. Instalando el cliente oficial.'

    if ($DryRun) { Write-Host '[dry-run] instalaria WireGuard' -ForegroundColor DarkGray; return }

    if ($MsiPath) {
        if (-not (Test-Path $MsiPath)) { Morir "No existe el MSI indicado: $MsiPath" }
        Info "Instalando desde $MsiPath"
        $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$MsiPath`"", '/qn', '/norestart') -Wait -PassThru
        if ($p.ExitCode -ne 0) { Morir "msiexec devolvio $($p.ExitCode)" }
    }
    elseif (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        Info 'Instalando por winget.'
        & winget.exe install --id WireGuard.WireGuard -e --silent `
            --accept-package-agreements --accept-source-agreements | Out-Null
    }
    else {
        Info "Descargando $INSTALLER_URL"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $tmp = Join-Path $env:TEMP 'wireguard-installer.exe'
        Invoke-WebRequest -Uri $INSTALLER_URL -OutFile $tmp -UseBasicParsing
        Info 'Ejecutando el instalador.'
        Start-Process $tmp -Wait
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path $WG_EXE)) {
        Morir "La instalacion no dejo $WG_EXE. Instalalo a mano desde https://www.wireguard.com/install/ y volve a correr el script."
    }
    Ok 'WireGuard instalado.'
}

# ------------------------------------------------------------------ claves

function Obtener-Claves {
    $dirClaves = Join-Path $DATA_DIR 'claves'
    if (-not (Test-Path $dirClaves)) {
        New-Item -ItemType Directory -Path $dirClaves -Force | Out-Null
        Restringir-Acl $DATA_DIR
    }

    $fPriv = Join-Path $dirClaves "$Nombre-privada.key"
    $fPub  = Join-Path $dirClaves "$Nombre-publica.key"
    $fPsk  = Join-Path $dirClaves "$Nombre-psk.key"

    if (Test-Path $fPriv) {
        Info 'Reutilizando el par de claves existente (no se regenera para no invalidar el peer del hub).'
        # La publica se puede volver a derivar de la privada, la PSK no. Si falta
        # la PSK hay que regenerarla y actualizar el peer del hub, porque un
        # handshake con PSK distinta falla igual que con clave equivocada.
        if (-not (Test-Path $fPub)) {
            (Get-Content $fPriv -Raw).Trim() | & $WG_CLI pubkey | Set-Content -Path $fPub -Encoding ASCII -NoNewline
        }
        if (-not (Test-Path $fPsk)) {
            Aviso 'Falta la PSK. Se genera una nueva: hay que actualizar el peer en el RB5009.'
            (& $WG_CLI genpsk).Trim() | Set-Content -Path $fPsk -Encoding ASCII -NoNewline
        }
    }
    else {
        Info 'Generando par de claves nuevo.'
        (& $WG_CLI genkey).Trim() | Set-Content -Path $fPriv -Encoding ASCII -NoNewline
        (Get-Content $fPriv -Raw).Trim() | & $WG_CLI pubkey | Set-Content -Path $fPub -Encoding ASCII -NoNewline
        Info 'Generando PSK nueva.'
        (& $WG_CLI genpsk).Trim() | Set-Content -Path $fPsk -Encoding ASCII -NoNewline
    }

    Restringir-Acl $DATA_DIR

    return [pscustomobject]@{
        Privada = (Get-Content $fPriv -Raw).Trim()
        Publica = (Get-Content $fPub  -Raw).Trim()
        Psk     = (Get-Content $fPsk  -Raw).Trim()
        Dir     = $dirClaves
    }
}

# ------------------------------------------------------------ persistencia

# En Linux el tunel vive en el kernel: una vez levantada la interfaz no hay
# proceso que se pueda morir. En Windows el tunel ES un servicio de usuario,
# asi que hay tres cosas distintas que asegurar:
#   1. que arranque solo despues de un reboot   -> StartType Automatic
#   2. que se levante solo si se cae            -> acciones de recuperacion
#   3. que se recicle si queda "corriendo pero mudo" -> watchdog
# El caso 3 es el que no cubre ningun mecanismo nativo: el servicio puede
# seguir en Running con el tunel muerto (tipico despues de suspender la PC o
# de cambiar de red), y para Windows eso es un servicio sano.

function Escribir-Watchdog {
    param([string]$Ruta, [string]$Tunel)

    $cuerpo = @'
# Watchdog del tunel WireGuard. Lo instala instalar-wg-windows.ps1.
$ErrorActionPreference = 'SilentlyContinue'

$tunel = '__NOMBRE__'
$svc   = "WireGuardTunnel`$$tunel"
$wg    = Join-Path $env:ProgramFiles 'WireGuard\wg.exe'
$log   = Join-Path $env:ProgramData 'wg-scada\watchdog.log'

function Registrar([string]$m) {
    Add-Content -Path $log -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
    if ((Test-Path $log) -and (Get-Item $log).Length -gt 512KB) {
        $cola = Get-Content $log -Tail 500
        Set-Content -Path $log -Value $cola
    }
}

$s = Get-Service -Name $svc -ErrorAction SilentlyContinue
if (-not $s) { exit 0 }

if ($s.Status -ne 'Running') {
    Registrar "servicio en estado $($s.Status): se arranca"
    Start-Service -Name $svc
    exit 0
}

# Con PersistentKeepalive el handshake se renueva cada ~2 minutos. Si hace mas
# de 3 no hubo ninguno, el tunel esta muerto aunque el servicio siga en Running.
if (-not (Test-Path $wg)) { exit 0 }
$salida = & $wg show $tunel latest-handshakes 2>$null
if (-not $salida) { exit 0 }
$campos = (@($salida)[0] -split "`t")
if ($campos.Count -lt 2) { exit 0 }
try { $ultimo = [int64]$campos[1].Trim() } catch { exit 0 }

$edad = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $ultimo
if ($ultimo -ne 0 -and $edad -le 180) { exit 0 }

# Si la PC no tiene ninguna red conectada, reciclar el tunel no arregla nada:
# el handshake va a fallar igual y solo se estaria tirando el adaptador abajo
# en loop. Se espera a que vuelva la conectividad.
$hayRed = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceAlias -ne $tunel }).Count -gt 0
if (-not $hayRed) { exit 0 }

Registrar "sin handshake hace $edad s: se reinicia $svc"
Restart-Service -Name $svc -Force
'@

    $cuerpo.Replace('__NOMBRE__', $Tunel) | Set-Content -Path $Ruta -Encoding ASCII
}

function Configurar-Persistencia {
    $svcName = "WireGuardTunnel`$$Nombre"
    $tarea   = "wg-watchdog-$Nombre"

    if ($DryRun) {
        Write-Host "[dry-run] configuraria arranque automatico, recuperacion y tarea $tarea" -ForegroundColor DarkGray
        return
    }

    # 1. arranque automatico
    Set-Service -Name $svcName -StartupType Automatic
    $st = (Get-Service -Name $svcName).StartType
    if ($st -ne 'Automatic') { Aviso "El servicio quedo con arranque $st, no Automatic. Revisalo a mano." }
    else { Ok "Servicio $svcName con arranque automatico." }

    # 2. acciones de recuperacion. El 'failureflag 1' es imprescindible: sin el,
    # Windows solo dispara la recuperacion cuando el servicio crashea, y el
    # tunel de WireGuard normalmente termina con salida limpia y codigo de error.
    & sc.exe failure $svcName reset= 0 actions= restart/5000/restart/15000/restart/60000 | Out-Null
    & sc.exe failureflag $svcName 1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Ok 'Recuperacion automatica configurada (reintenta a los 5s, 15s y 60s).' }
    else { Aviso "sc.exe failure devolvio $LASTEXITCODE. El servicio no reintentara solo." }

    # 3. watchdog
    if ($SinWatchdog) {
        Aviso 'Watchdog omitido por -SinWatchdog. Si el tunel queda mudo sin caerse el servicio, nadie lo va a reciclar.'
        return
    }

    $fWatch = Join-Path $DATA_DIR 'watchdog.ps1'
    Escribir-Watchdog -Ruta $fWatch -Tunel $Nombre

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $accion = New-ScheduledTaskAction -Execute $psExe `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$fWatch`""

    $trArranque = New-ScheduledTaskTrigger -AtStartup
    try { $trArranque.Delay = 'PT1M' } catch { }

    # Sin -RepetitionDuration la repeticion queda indefinida, que es lo que se
    # busca: el watchdog tiene que seguir corriendo para siempre.
    $trCiclo = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes $WatchdogMinutos)

    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    # En una notebook los defaults de tarea programada la suspenden al pasar a
    # bateria. Para un tunel de supervision eso es justo lo que no se quiere.
    $opciones = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

    Register-ScheduledTask -TaskName $tarea -Action $accion `
        -Trigger @($trArranque, $trCiclo) -Principal $principal `
        -Settings $opciones -Force | Out-Null

    Restringir-Acl $DATA_DIR
    Ok "Watchdog instalado: tarea '$tarea' cada $WatchdogMinutos min y en cada arranque."
}

# ------------------------------------------------------------------ estado

function Mostrar-Estado {
    if (-not (Test-Path $WG_CLI)) { Morir 'WireGuard no esta instalado en este equipo.' }

    Write-Host ''
    Write-Host '--- wg show ---' -ForegroundColor Cyan
    & $WG_CLI show

    Write-Host ''
    Write-Host '--- adaptador ---' -ForegroundColor Cyan
    Get-NetAdapter -Name $Nombre -ErrorAction SilentlyContinue |
        Format-Table Name, InterfaceDescription, Status, LinkSpeed -AutoSize

    Write-Host '--- rutas por el tunel ---' -ForegroundColor Cyan
    $ifx = (Get-NetAdapter -Name $Nombre -ErrorAction SilentlyContinue).ifIndex
    if ($ifx) {
        Get-NetRoute -InterfaceIndex $ifx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Sort-Object DestinationPrefix |
            Format-Table DestinationPrefix, NextHop, RouteMetric -AutoSize
    } else {
        Aviso "No existe el adaptador $Nombre."
    }

    Write-Host '--- servicio ---' -ForegroundColor Cyan
    $svcName = "WireGuardTunnel`$$Nombre"
    Get-Service -Name $svcName -ErrorAction SilentlyContinue |
        Format-Table Name, Status, StartType -AutoSize

    Write-Host '--- recuperacion automatica ---' -ForegroundColor Cyan
    & sc.exe qfailure $svcName 2>&1 | Select-Object -Skip 1

    Write-Host ''
    Write-Host '--- watchdog ---' -ForegroundColor Cyan
    $tarea = Get-ScheduledTask -TaskName "wg-watchdog-$Nombre" -ErrorAction SilentlyContinue
    if ($tarea) {
        $info = Get-ScheduledTaskInfo -TaskName "wg-watchdog-$Nombre" -ErrorAction SilentlyContinue
        Write-Host ("  tarea      : wg-watchdog-{0} ({1})" -f $Nombre, $tarea.State)
        if ($info) {
            Write-Host ("  ultima vez : {0} (resultado {1})" -f $info.LastRunTime, $info.LastTaskResult)
            Write-Host ("  proxima    : {0}" -f $info.NextRunTime)
        }
        $logW = Join-Path $DATA_DIR 'watchdog.log'
        if (Test-Path $logW) {
            Write-Host '  ultimas intervenciones:'
            Get-Content $logW -Tail 5 | ForEach-Object { Write-Host "    $_" }
        }
        else { Write-Host '  sin intervenciones registradas (el tunel nunca necesito ayuda).' }
    }
    else {
        Aviso "No hay watchdog instalado para $Nombre."
    }
    exit 0
}

# ------------------------------------------------------------- desinstalar

function Desinstalar-Tunel {
    Info "Desinstalando el tunel $Nombre."

    # El watchdog se saca primero. Si se baja el servicio con la tarea todavia
    # viva, el watchdog lo vuelve a levantar y la desinstalacion se pelea sola.
    $tarea = "wg-watchdog-$Nombre"
    if (Get-ScheduledTask -TaskName $tarea -ErrorAction SilentlyContinue) {
        Ejecutar "borrar la tarea programada $tarea" {
            Unregister-ScheduledTask -TaskName $tarea -Confirm:$false
        }
        Ok "Watchdog $tarea eliminado."
    }
    $fWatch = Join-Path $DATA_DIR 'watchdog.ps1'
    if (Test-Path $fWatch) { Ejecutar "borrar $fWatch" { Remove-Item $fWatch -Force } }

    if (-not (Test-Path $WG_EXE)) {
        Aviso 'WireGuard no esta instalado; no hay servicio de tunel que dar de baja.'
    }
    else {
        Ejecutar "wireguard.exe /uninstalltunnelservice $Nombre" {
            & $WG_EXE /uninstalltunnelservice $Nombre 2>&1 | Out-Null
            Start-Sleep -Seconds 3
        }
    }

    # Verificacion real. El /uninstalltunnelservice devuelve 0 aunque el servicio
    # no existiera, asi que el unico testigo confiable de que el tunel bajo es
    # que el adaptador ya no este.
    if (-not $DryRun) {
        $ad = Get-NetAdapter -Name $Nombre -ErrorAction SilentlyContinue
        if ($ad) {
            Start-Sleep -Seconds 3
            $ad = Get-NetAdapter -Name $Nombre -ErrorAction SilentlyContinue
        }
        if ($ad) {
            Morir "El adaptador $Nombre sigue existiendo. Bajalo desde la GUI de WireGuard o con: sc.exe delete `"WireGuardTunnel`$$Nombre`""
        }
    }

    $conf = Join-Path $DATA_DIR "$Nombre.conf"
    if (Test-Path $conf) { Ejecutar "borrar $conf" { Remove-Item $conf -Force } }

    if ($BorrarClaves) {
        Aviso 'Se borran las claves. Una reinstalacion generara identidad nueva.'
        $dirClaves = Join-Path $DATA_DIR 'claves'
        if (Test-Path $dirClaves) { Ejecutar "borrar $dirClaves" { Remove-Item $dirClaves -Recurse -Force } }
    }
    else {
        Info "Las claves se conservan en $(Join-Path $DATA_DIR 'claves')"
    }

    Ok "Tunel $Nombre desinstalado."
    exit 0
}

# ==================================================================== main

if (-not (Test-Admin)) {
    Morir 'Hay que ejecutar este script en una PowerShell abierta como Administrador.'
}

if ($Estado)      { Mostrar-Estado }
if ($Desinstalar) { Desinstalar-Tunel }

# --- validacion de parametros -------------------------------------------

if (-not (Test-Cidr $IpOverlay)) { Morir "IP overlay invalida: $IpOverlay (se espera A.B.C.D/32)" }
if (($IpOverlay -replace '^.+/', '') -ne '32') {
    Morir "La IP overlay debe declararse /32, no $IpOverlay. Un prefijo mas ancho hace que la PC crea que toda esa red esta directamente conectada al tunel."
}

if (-not (Test-ClaveWg $HubPubkey)) { Morir "Clave publica del hub invalida: $HubPubkey" }

if ($HubEndpoint -notmatch '^([A-Za-z0-9\.\-]+):(\d{1,5})$') { Morir "Endpoint del hub invalido: $HubEndpoint (se espera host:puerto)" }
if ([int]$Matches[2] -lt 1 -or [int]$Matches[2] -gt 65535) { Morir "Puerto del hub fuera de rango en $HubEndpoint" }

if (-not (Test-Ipv4 $HubOverlay)) { Morir "IP overlay del hub invalida: $HubOverlay" }

foreach ($r in $RedesReco)   { Assert-PrefijoEstricto $r }
foreach ($r in $RoutersReco) { if (-not (Test-Ipv4 $r)) { Morir "IP de router RECO invalida: $r (se declara sin mascara, se usa como /32)" } }
foreach ($h in $HostsExtra)  { if (-not (Test-Ipv4 $h)) { Morir "IP extra invalida: $h (se declara sin mascara, se usa como /32)" } }

if ($RedesReco.Count -eq 0 -and $RoutersReco.Count -eq 0 -and $HostsExtra.Count -eq 0) {
    Morir 'No se declaro ningun destino. Usa -RedesReco, -RoutersReco o -HostsExtra.'
}

# --- armado de AllowedIPs -----------------------------------------------
# Cada entrada de esta lista es, a la vez, el filtro criptografico de WireGuard
# y una ruta que el cliente instala en Windows. Una sola entrada = una sola ruta.

$allowed = New-Object System.Collections.Generic.List[string]
$allowed.Add("$HubOverlay/32")
foreach ($r in $RoutersReco) { $allowed.Add("$r/32") }
foreach ($h in $HostsExtra)  { $allowed.Add("$h/32") }
foreach ($r in $RedesReco)   { $allowed.Add($r) }
$allowedStr = ($allowed | Select-Object -Unique) -join ', '

Instalar-WireGuard

if (-not (Test-Path $WG_CLI)) { Morir "No se encuentra $WG_CLI" }
if (-not (Test-Path $DATA_DIR)) { New-Item -ItemType Directory -Path $DATA_DIR -Force | Out-Null }

$claves = Obtener-Claves

# --- escribir el .conf ---------------------------------------------------

$conf = Join-Path $DATA_DIR "$Nombre.conf"

$texto = @"
# Generado por instalar-wg-windows.ps1 v$VERSION
# Politica de ruteo: prefijos estrictos. Cada AllowedIPs es una ruta y nada mas.
# El trafico que no cae en esos prefijos sigue saliendo por la interfaz normal.

[Interface]
PrivateKey = $($claves.Privada)
Address = $IpOverlay
MTU = $Mtu

[Peer]
PublicKey = $HubPubkey
PresharedKey = $($claves.Psk)
Endpoint = $HubEndpoint
AllowedIPs = $allowedStr
PersistentKeepalive = $Keepalive
"@

if ($DryRun) {
    Write-Host '[dry-run] .conf que se escribiria:' -ForegroundColor DarkGray
    Write-Host $texto -ForegroundColor DarkGray
}
else {
    Set-Content -Path $conf -Value $texto -Encoding ASCII
    Restringir-Acl $DATA_DIR
}

Info "Se instalaran $($allowed.Count) rutas especificas por $Nombre :"
foreach ($a in ($allowed | Select-Object -Unique)) { Write-Host "      $a" }
Info 'El resto del trafico de la PC no se toca. No se modifica el Firewall de Windows.'

# --- registrar el servicio ----------------------------------------------

# Si ya existe una version previa del tunel hay que bajarla antes: el
# /installtunnelservice sobre un tunel vivo deja el adaptador en un estado raro.
if (-not $DryRun) {
    if (Get-Service -Name "WireGuardTunnel`$$Nombre" -ErrorAction SilentlyContinue) {
        Info "Ya existe el servicio del tunel $Nombre. Se da de baja antes de reinstalarlo."
        & $WG_EXE /uninstalltunnelservice $Nombre 2>&1 | Out-Null
        Start-Sleep -Seconds 3
    }
}

Ejecutar "wireguard.exe /installtunnelservice $conf" {
    & $WG_EXE /installtunnelservice $conf
    Start-Sleep -Seconds 3
}

if (-not $DryRun) {
    $svc = Get-Service -Name "WireGuardTunnel`$$Nombre" -ErrorAction SilentlyContinue
    if (-not $svc) { Morir "No se creo el servicio WireGuardTunnel`$$Nombre." }
    if ($svc.Status -ne 'Running') {
        Start-Sleep -Seconds 3
        $svc.Refresh()
    }
    if ($svc.Status -ne 'Running') {
        Morir "El servicio del tunel quedo en estado $($svc.Status). Revisa el log en $WG_HOME\Data\log.bin desde la GUI."
    }
    Ok "Servicio WireGuardTunnel`$$Nombre en ejecucion."
}

Configurar-Persistencia

# --- salida --------------------------------------------------------------

if ($Breve) {
    # Salida minima: dos lineas CLAVE=VALOR y nada mas, para copiar de una pasada.
    Write-Host ''
    Write-Host "PUBLIC-KEY=$($claves.Publica)"
    Write-Host "PRESHARED-KEY=$($claves.Psk)"
    exit 0
}

Write-Host ''
Write-Host '================ PEER PARA EL RB5009 ================' -ForegroundColor Cyan
Write-Host ''
Write-Host '/interface/wireguard/peers/add \'
Write-Host '    interface=<interfaz-wg-del-hub> \'
Write-Host "    public-key=`"$($claves.Publica)`" \"
Write-Host "    preshared-key=`"$($claves.Psk)`" \"
Write-Host "    allowed-address=$IpOverlay \"
Write-Host '    endpoint-address="" \'
Write-Host '    persistent-keepalive=25s \'
Write-Host "    comment=`"PC-WINDOWS $env:COMPUTERNAME`""
Write-Host ''
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host ''
Aviso "El endpoint se deja vacio a proposito: el hub lo aprende del handshake, asi la PC puede cambiar de red o de IP publica sin tocar el RB5009."
Write-Host ''
Info 'Verificacion desde esta PC:'
Write-Host "      .\instalar-wg-windows.ps1 -Estado"
Write-Host "      ping $HubOverlay"
foreach ($r in $RoutersReco) { Write-Host "      ping $r" }
Write-Host ''
