# nets

Herramientas de red.

## chequeo-rangos.sh

Busca colisiones entre los rangos que pensás usar en una VPN y lo que el host ya
tiene ocupado. Está pensado para correr **antes** de instalar un cliente
WireGuard, cuando todavía se está a tiempo de elegir otro direccionamiento.

```bash
sudo ./chequeo-rangos.sh                          # 10.255.0.0/16 y 172.20.0.0/16
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
