# nets

Herramientas de red.

## chequeo-rangos.sh

Busca colisiones entre los rangos que pensás usar en una VPN y lo que el host ya
tiene ocupado. Está pensado para correr **antes** de instalar un cliente
WireGuard, cuando todavía se está a tiempo de elegir otro direccionamiento.

```bash
sudo ./chequeo-rangos.sh                          # 10.255.0.0/16 y 10.20.0.0/16
sudo ./chequeo-rangos.sh 10.8.0.0/16 192.168.50.0/24
```

Admite máscaras `/8`, `/16`, `/24` y `/32`. Devuelve `0` si no hay colisiones y
`1` si encontró al menos una, así que sirve como paso previo en un script de
instalación.

### Qué revisa

| | |
|---|---|
| 1 | Direcciones de las interfaces |
| 2 | Tabla de rutas completa, no solo la principal |
| 3 | Reglas de policy routing |
| 4 | Redes de Docker, incluidas las creadas pero paradas |
| 5 | Redes de libvirt y LXD |
| 6 | Reglas de nftables e iptables que mencionen los rangos |
| 7 | Configuración de red persistente |
| 8 | Interfaces WireGuard existentes |

### Por qué el chequeo de Docker importa

Docker asigna las redes de usuario tomando bloques `/16` de `172.16.0.0/12`.
Cualquier rango entre `172.16` y `172.31` puede estar ocupado por un contenedor,
y una red creada pero detenida **no aparece en la tabla de rutas**. Es la
colisión más común y la más difícil de ver a simple vista.

Si aparece una, se resuelve fijando el pool en `/etc/docker/daemon.json` y
recreando la red:

```json
{ "default-address-pools": [ { "base": "172.28.0.0/14", "size": 24 } ] }
```

### Privilegios

Conviene correrlo como root. Sin privilegios, `nftables` e `iptables` no se
pueden listar: el script lo marca como `[ n/d ]` y lo informa al final en lugar
de dar un resultado limpio que no cubrió todo.

## chequeo-so-wireguard.sh

El complemento del anterior. `chequeo-rangos.sh` responde *¿el direccionamiento
está libre?*; éste responde *¿este sistema puede sostener el túnel?*.

```bash
sudo ./chequeo-so-wireguard.sh
sudo ./chequeo-so-wireguard.sh --hub-endpoint 203.0.113.10:51820
```

Es de **solo lectura**. Lo único que escribe algo en el sistema es `modprobe`, y
sólo si se pide con `--probar-modulo`.

### Qué revisa

| | |
|---|---|
| 1 | Distribución, kernel y systemd |
| 2 | Soporte de WireGuard: módulo, kernel integrado, virtualización, `/dev/net/tun` |
| 3 | Herramientas presentes y si los repos resuelven los paquetes |
| 4 | Interfaz de salida y si el MTU alcanza para el túnel |
| 5 | `ip_forward`, `rp_filter` y conntrack |
| 6 | Firewall existente, backend de iptables, ufw/firewalld |
| 7 | Docker: redes, subredes y contenedores en ejecución |
| 8 | Gestión de red que pueda disputar la interfaz del túnel |
| 9 | Sincronización horaria |
| 10 | Espacio en disco y permisos de `/etc/wireguard` |
| 11 | Alcance del concentrador, con `--hub-endpoint` |
| 12 | Rangos del proyecto |

Devuelve `0` si el sistema es apto, `1` si hay advertencias y `2` si encontró al
menos un bloqueante.

### El bloqueante que más aparece

La virtualización. En un VPS OpenVZ o LXC el kernel es del anfitrión y no se
pueden cargar módulos, así que WireGuard nativo no está disponible: hay que ir a
una implementación en espacio de usuario. Con KVM o metal desnudo no hay
problema. Es lo primero que conviene descartar, porque condiciona todo lo demás.

### Sobre los resultados `[ n/d ]`

Una comprobación que no se pudo hacer **no** es una comprobación superada. Si
falta el privilegio o la herramienta, el script lo marca `[ n/d ]` y lo repite en
el resumen final, en vez de contarlo como correcto. Un OK falso en un chequeo
previo es peor que no haberlo corrido.

## instalar-wg-windows.ps1

Instalador desatendido del cliente WireGuard para una PC Windows contra el hub.
Equivalente del instalador de Linux: instala el cliente si falta, genera o
reutiliza las claves, escribe el `.conf`, registra el túnel como servicio y lo
deja arrancando solo.

Necesita PowerShell 5.1 o superior, **abierto como Administrador**.

```powershell
.\instalar-wg-windows.ps1 -IpOverlay 10.255.0.20/32 -HubPubkey 'CLAVE_DEL_HUB=' -HubEndpoint 1.2.3.4:51820 -RedesReco 10.20.1.0/24 -RoutersReco 10.255.1.1 -PermitirIcmp
.\instalar-wg-windows.ps1 -Estado
.\instalar-wg-windows.ps1 -Desinstalar -BorrarClaves -QuitarWireGuard
```

Al terminar imprime el bloque del peer listo para pegar en el RouterOS del hub.
Con `-Breve` imprime sólo la clave pública y la PSK, para copiar de una pasada.

### Política de ruteo

Prefijos estrictos: nada de `0.0.0.0/0`, nada más ancho que `/24`. En Windows
**cada entrada de `AllowedIPs` es una ruta** que el cliente instala sola; no se
ejecuta ningún `route add`. Por eso un prefijo ancho no "abre" nada en el hub
pero sí secuestra el ruteo de la PC, y un `0.0.0.0/0` dejaría al operador sin
internet y sin RDP. El script se niega a ambos.

El resto del tráfico —internet, LAN local, impresoras— queda intacto.

### Persistencia

En Linux el túnel vive en el kernel: una vez levantada la interfaz no hay
proceso que se pueda morir. En Windows el túnel **es** un servicio de usuario, y
hay tres fallas distintas que cubrir:

| Falla | Qué la cubre |
|---|---|
| Reboot | `StartType Automatic`, verificado después de instalar |
| El servicio se cae | `sc.exe failure`: reintenta a los 5 s, 15 s y 60 s |
| Corriendo pero mudo | Watchdog como tarea programada, cada 5 min |

El tercero es el que no cubre ningún mecanismo nativo: el servicio puede seguir
en `Running` con el túnel muerto —típico al suspender la PC o cambiar de red— y
para Windows eso es un servicio sano. El watchdog mira la antigüedad del último
handshake, no el estado del servicio.

Detalle que hace la diferencia: el `sc.exe failureflag 1`. Sin él Windows sólo
dispara la recuperación cuando el servicio *crashea*, y el túnel de WireGuard
normalmente termina con salida limpia y código de error.

El watchdog no hace nada si la PC no tiene ninguna red conectada. Sin
conectividad el handshake va a fallar igual, y reciclar el servicio en bucle
sólo tira el adaptador abajo.

### -PermitirIcmp

Windows descarta el echo request entrante por defecto en perfil Público, y el
adaptador del túnel casi siempre cae en Público. Por eso el hub puede tener todo
bien configurado y el ping a la PC igual dar timeout.

Con `-PermitirIcmp` se crea una regla de entrada acotada por partida doble: sólo
por el adaptador del túnel y sólo desde los prefijos de `AllowedIPs`. Es lo
único que el script toca del Firewall de Windows, y sólo si se lo pide
explícitamente. `-Desinstalar` la remueve.

## bootstrap-wg-windows.ps1

Punto de entrada para que el cliente pegue **una sola línea**. Baja
`instalar-wg-windows.ps1` del repositorio y le pasa todos los argumentos tal
cual, así que no necesita mantenerse sincronizado con sus parámetros.

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/esteban826/nets/main/bootstrap-wg-windows.ps1))) -IpOverlay 10.255.0.20/32 -HubPubkey 'CLAVE_DEL_HUB=' -HubEndpoint 1.2.3.4:51820 -RedesReco 10.20.1.0/24 -RoutersReco 10.255.1.1 -PermitirIcmp
```

Verifica que sea Administrador antes de bajar nada, comprueba que lo descargado
sea realmente el instalador —un repositorio renombrado o privado devuelve una
página HTML con código 200— y borra el temporal al terminar.

Una línea sola no es capricho: en PowerShell el pegado de varias líneas se
ejecuta fuera de orden con más frecuencia de la que uno esperaría.

## ajustar-allowed-ips.sh

Agrega o quita entradas de `AllowedIPs` en un cliente wg-quick **sin reiniciar
el túnel**.

```bash
sudo bash ajustar-allowed-ips.sh --listar
sudo bash ajustar-allowed-ips.sh --agregar 10.255.0.20/32
sudo bash ajustar-allowed-ips.sh --agregar 10.20.2.0/24,10.255.2.1 --dry-run
sudo bash ajustar-allowed-ips.sh --quitar 10.20.2.0/24
```

Aplica el cambio en tres lugares, que es donde suele romperse la cosa a mano:

| | |
|---|---|
| En caliente | `wg set` sobre el peer. **Reemplaza la lista completa**, no agrega: el script lee la actual y manda la nueva entera |
| Las rutas | `wg set` no las toca. Al levantar, wg-quick las deriva de `AllowedIPs`; en caliente hay que reconciliarlas aparte |
| En disco | Reescribe el `.conf` con backup previo, para que sobreviva al reinicio |

Al final compara memoria contra disco. Los dos modos de quedar a medias
—aplicado sin persistir, o persistido sin aplicar— se ven idénticos desde afuera
hasta que reiniciás el servidor o hasta que probás el tráfico.

Misma política de prefijos que el instalador de Windows: rechaza `0.0.0.0/0` y
todo lo más ancho que `/24`. Una IP sin máscara se toma como `/32`.
