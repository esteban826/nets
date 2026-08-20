#Requires -Version 5.1
<#
.SYNOPSIS
    Punto de entrada unico para instalar, consultar o desinstalar el tunel
    WireGuard en una PC Windows. Baja instalar-wg-windows.ps1 del repo y lo
    ejecuta pasandole todos los argumentos.

.DESCRIPTION
    Pensado para que el cliente pegue UNA sola linea en PowerShell. Todo lo que
    va despues de -Repo y -Rama se le pasa tal cual a instalar-wg-windows.ps1,
    asi que este script no necesita conocer sus parametros ni mantenerse
    sincronizado con ellos.

    Uso tipico, una sola linea como Administrador:

      & ([scriptblock]::Create((irm https://raw.githubusercontent.com/esteban826/nets/main/bootstrap-wg-windows.ps1))) -IpOverlay 10.255.0.20/32 -HubPubkey 'CLAVE=' -HubEndpoint 1.2.3.4:51820 -RedesReco 10.20.1.0/24 -RoutersReco 10.255.1.1

.PARAMETER Repo
    Repositorio GitHub en formato usuario/proyecto. Por defecto esteban826/nets.

.PARAMETER Rama
    Rama del repositorio. Por defecto main.

.PARAMETER Argumentos
    Todo el resto. Se le entrega sin tocar a instalar-wg-windows.ps1.

.EXAMPLE
    # instalar
    .\bootstrap-wg-windows.ps1 -IpOverlay 10.255.0.20/32 -HubPubkey 'xxx=' -HubEndpoint 1.2.3.4:51820 -RedesReco 10.20.1.0/24

.EXAMPLE
    # ver estado
    .\bootstrap-wg-windows.ps1 -Estado

.EXAMPLE
    # desinstalar dejando la PC limpia
    .\bootstrap-wg-windows.ps1 -Desinstalar -BorrarClaves -QuitarWireGuard
#>

[CmdletBinding()]
param(
    [string]$Repo = 'esteban826/nets',
    [string]$Rama = 'main',

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Argumentos
)

$ErrorActionPreference = 'Stop'

function Info  ([string]$m) { Write-Host "[+] $m" -ForegroundColor Cyan }
function Morir ([string]$m) { Write-Host "[X] $m" -ForegroundColor Red; exit 1 }

# Splatear un ARRAY pasa todo como posicional: '-IpOverlay' termina siendo el
# valor del primer parametro y el resto se corre uno. Para que lleguen como
# argumentos nombrados hay que armar una tabla hash y splatear eso.
function ConvertTo-TablaArgumentos {
    param([string[]]$Tokens)

    $tabla = @{}
    $i = 0
    while ($i -lt $Tokens.Count) {
        if ($Tokens[$i] -notmatch '^-{1,2}([A-Za-z]\w*)$') {
            Morir "No entiendo el argumento '$($Tokens[$i])'. Se esperaba -Parametro [valor]."
        }
        $nombre = $Matches[1]
        $i++

        # Todo lo que sigue hasta el proximo '-Algo' son valores de este
        # parametro. Ninguno de los valores que maneja el instalador (IPs,
        # prefijos, claves base64, endpoints) empieza con guion.
        $valores = @()
        while ($i -lt $Tokens.Count -and $Tokens[$i] -notmatch '^-{1,2}[A-Za-z]') {
            $valores += $Tokens[$i]
            $i++
        }

        if     ($valores.Count -eq 0) { $tabla[$nombre] = $true }
        elseif ($valores.Count -eq 1) { $tabla[$nombre] = $valores[0] }
        else                          { $tabla[$nombre] = $valores }
    }
    return $tabla
}

# --- que sea Administrador -----------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ''
    Write-Host '[X] Esto necesita PowerShell abierto como Administrador.' -ForegroundColor Red
    Write-Host '    Boton derecho sobre el icono de PowerShell -> Ejecutar como administrador,' -ForegroundColor Yellow
    Write-Host '    y volve a pegar la misma linea.' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

# --- descargar el instalador ---------------------------------------------
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$archivo = 'instalar-wg-windows.ps1'
$url     = "https://raw.githubusercontent.com/$Repo/$Rama/$archivo"
$destino = Join-Path $env:TEMP "wg-$([guid]::NewGuid().ToString('N'))-$archivo"

Info "Descargando $archivo desde $Repo ($Rama)."
try {
    # El no-cache importa: raw.githubusercontent cachea unos minutos y una
    # correccion recien subida puede no verse todavia.
    Invoke-WebRequest -Uri $url -OutFile $destino -UseBasicParsing `
        -Headers @{ 'Cache-Control' = 'no-cache'; 'Pragma' = 'no-cache' }
}
catch {
    Morir "No se pudo descargar $url`n    $($_.Exception.Message)"
}

if (-not (Test-Path $destino)) { Morir "La descarga no dejo ningun archivo en $destino" }

# Un repo renombrado o privado devuelve una pagina HTML con codigo 200. Sin
# esta verificacion se ejecutaria basura y el error saldria mucho mas adelante,
# ya con cosas a medio hacer.
$contenido = Get-Content $destino -Raw
if ($contenido -notmatch 'instalar-wg-windows|Instalador desatendido de WireGuard') {
    Remove-Item $destino -Force -ErrorAction SilentlyContinue
    Morir "Lo que bajo de $url no es el instalador. Revisa que el repo y la rama existan."
}

Unblock-File -Path $destino

# --- ejecutarlo -----------------------------------------------------------
# Bypass solo para este proceso: no se cambia la politica del equipo.
try { Set-ExecutionPolicy Bypass -Scope Process -Force -ErrorAction SilentlyContinue } catch { }

$version = ''
if ($contenido -match "(?m)^\s*\`$VERSION\s*=\s*'([^']+)'") { $version = " v$($Matches[1])" }
Info "Ejecutando instalar-wg-windows.ps1$version"
Write-Host ''

$codigo = 0
try {
    if ($Argumentos) {
        $tabla = ConvertTo-TablaArgumentos -Tokens $Argumentos
        & $destino @tabla
    }
    else { & $destino }
    if ($null -ne $LASTEXITCODE) { $codigo = $LASTEXITCODE }
}
catch {
    Write-Host ''
    Write-Host "[X] $($_.Exception.Message)" -ForegroundColor Red
    $codigo = 1
}
finally {
    Remove-Item $destino -Force -ErrorAction SilentlyContinue
}

exit $codigo
