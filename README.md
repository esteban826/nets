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
