#!/usr/bin/env bash
# =============================================================================
#  chequeo-rangos.sh
#
#  Busca colisiones entre los rangos que pensas usar en una VPN y lo que el
#  host ya tiene ocupado. Pensado para correr ANTES de instalar un cliente
#  WireGuard, cuando todavia se esta a tiempo de elegir otro direccionamiento.
#
#  Revisa, en este orden:
#    1. Direcciones de las interfaces
#    2. Tabla de rutas completa, no solo la principal
#    3. Reglas de policy routing
#    4. Redes de Docker, incluidas las que estan creadas pero paradas
#    5. Redes de libvirt y LXD
#    6. Reglas de nftables e iptables que mencionen los rangos
#    7. Configuracion de red persistente
#    8. Restos de una instalacion previa de WireGuard
#
#  Por que el punto 4 importa: Docker asigna las redes de usuario tomando
#  bloques /16 de 172.16.0.0/12. Cualquier rango entre 172.16 y 172.31 puede
#  estar ocupado por un contenedor, y una red creada pero detenida no aparece
#  en la tabla de rutas. Es la colision mas comun y la mas dificil de ver.
#
#  Uso:
#    ./chequeo-rangos.sh                          usa los rangos por defecto
#    ./chequeo-rangos.sh 10.8.0.0/16 192.168.50.0/24
#
#  Admite mascaras /8, /16, /24 y /32. Conviene correrlo como root: sin
#  privilegios, nftables e iptables no se pueden listar y esos dos chequeos
#  quedan sin cubrir.
#
#  Codigo de salida: 0 si no hay colisiones, 1 si hay al menos una.
# =============================================================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

RANGOS_POR_DEFECTO="10.255.0.0/16 10.20.0.0/16"

if [ -t 1 ]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'
  C_BLD=$'\033[1m';    C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLD=""; C_OFF=""
fi

HALLAZGOS=0
SIN_COBERTURA=0

seccion() { printf '\n%s=== %s ===%s\n' "$C_BLD" "$*" "$C_OFF"; }
sangria() { sed 's/^/      /'; }

# revisar <descripcion> <salida>
# Una salida no vacia significa que algo hizo match con alguno de los rangos.
revisar() {
  if [ -n "$2" ]; then
    printf '  %s[COLISION]%s %s\n' "$C_RED" "$C_OFF" "$1"
    printf '%s\n' "$2" | sangria
    HALLAZGOS=$((HALLAZGOS + 1))
  else
    printf '  %s[ libre ]%s %s\n' "$C_GRN" "$C_OFF" "$1"
  fi
}

omitido() {
  printf '  %s[ n/d  ]%s %s\n' "$C_YEL" "$C_OFF" "$1"
  SIN_COBERTURA=$((SIN_COBERTURA + 1))
}

# Convierte un CIDR en la parte fija de su regex: los octetos que la mascara
# deja completos. Con /16, 172.20.0.0/16 se vuelve 172\.20\.
prefijo_regex() {
  local cidr="$1" base masc n pref
  base="${cidr%%/*}"
  masc="${cidr##*/}"
  case "$masc" in
    8)  n=1 ;;
    16) n=2 ;;
    24) n=3 ;;
    32) n=4 ;;
    *)  printf 'Mascara no admitida en %s. Usar /8, /16, /24 o /32.\n' "$cidr" >&2
        exit 2 ;;
  esac
  # La sustitucion se hace con expansion de bash y no con un pipe: cut deja
  # un salto de linea al final que terminaria en medio del patron.
  pref="$(printf '%s' "$base" | cut -d. -f1-"$n")"
  pref="${pref//./\\.}"
  printf '%s' "$pref"
  # Con menos de cuatro octetos hace falta el punto de cierre, para que
  # 172\.20\. no haga match dentro de 172\.200\.
  [ "$n" -lt 4 ] && printf '\\.'
  return 0
}

RANGOS="${*:-$RANGOS_POR_DEFECTO}"
PATRON=""
for r in $RANGOS; do
  printf '%s' "$r" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' \
    || { printf 'CIDR invalido: %s\n' "$r" >&2; exit 2; }
  # La mascara se valida aqui y no dentro de prefijo_regex: esa funcion corre
  # en una sustitucion de comando, donde un exit solo mata la subshell y el
  # script seguiria adelante con un patron incompleto.
  case "${r##*/}" in
    8|16|24|32) : ;;
    *) printf 'Mascara no admitida en %s. Usar /8, /16, /24 o /32.\n' "$r" >&2
       exit 2 ;;
  esac
  PATRON="${PATRON}${PATRON:+|}$(prefijo_regex "$r")"
done
# El prefijo negativo evita que 10.255. haga match dentro de 110.255.
PATRON="(^|[^0-9.])(${PATRON})"

printf '%schequeo-rangos.sh%s\n' "$C_BLD" "$C_OFF"
printf 'Rangos a verificar: %s\n' "$RANGOS"
[ "$(id -u)" -eq 0 ] || printf '%sSin root: los chequeos de firewall van a quedar incompletos.%s\n' "$C_YEL" "$C_OFF"

seccion "1. Direcciones de las interfaces"
ip -4 -brief addr show | sangria
revisar "direcciones configuradas" "$(ip -4 -brief addr show | grep -E "$PATRON")"

seccion "2. Rutas, todas las tablas"
revisar "tabla de rutas" "$(ip route show table all 2>/dev/null | grep -E "$PATRON")"

seccion "3. Policy routing"
ip rule show 2>/dev/null | sangria
revisar "reglas de policy routing" "$(ip rule show 2>/dev/null | grep -E "$PATRON")"

seccion "4. Docker"
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    REDES="$(docker network ls -q 2>/dev/null | xargs -r docker network inspect \
             --format '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null)"
    printf '%s\n' "$REDES" | sangria
    revisar "redes docker" "$(printf '%s\n' "$REDES" | grep -E "$PATRON")"
  else
    omitido "docker instalado pero el daemon no responde"
  fi
  revisar "pool en /etc/docker/daemon.json" "$(grep -E "$PATRON" /etc/docker/daemon.json 2>/dev/null)"
else
  printf '  docker no instalado\n'
fi

seccion "5. libvirt y LXD"
if command -v virsh >/dev/null 2>&1; then
  virsh net-list --all 2>/dev/null | sangria
  revisar "redes libvirt" "$(virsh net-dumpxml default 2>/dev/null | grep -E "$PATRON")"
else
  printf '  libvirt no instalado\n'
fi
if command -v lxc >/dev/null 2>&1; then
  revisar "redes lxd" "$(lxc network list 2>/dev/null | grep -E "$PATRON")"
else
  printf '  lxd no instalado\n'
fi

seccion "6. Firewall y NAT"
if command -v nft >/dev/null 2>&1; then
  if nft list ruleset >/dev/null 2>&1; then
    revisar "nftables" "$(nft list ruleset 2>/dev/null | grep -E "$PATRON")"
  else
    omitido "nftables no se pudo listar, hacen falta privilegios"
  fi
else
  printf '  nftables no instalado\n'
fi
if command -v iptables-save >/dev/null 2>&1; then
  if iptables-save >/dev/null 2>&1; then
    revisar "iptables" "$(iptables-save 2>/dev/null | grep -E "$PATRON")"
  else
    omitido "iptables no se pudo listar, hacen falta privilegios"
  fi
else
  printf '  iptables no instalado\n'
fi

seccion "7. Configuracion persistente"
revisar "archivos de red" "$(grep -rE "$PATRON" \
    /etc/network/ /etc/netplan/ /etc/systemd/network/ /etc/dhcp/ 2>/dev/null)"

seccion "8. Interfaces WireGuard existentes"
if command -v wg >/dev/null 2>&1 && wg show interfaces >/dev/null 2>&1; then
  IFACES="$(wg show interfaces 2>/dev/null)"
  if [ -n "$IFACES" ]; then
    printf '  interfaces activas: %s\n' "$IFACES"
    printf '  %sNo son colisiones si son las que vas a reemplazar.%s\n' "$C_YEL" "$C_OFF"
  else
    printf '  ninguna interfaz WireGuard activa\n'
  fi
else
  printf '  wireguard-tools no instalado o sin privilegios\n'
fi
printf '  configuraciones en /etc/wireguard: %s\n' \
    "$(ls /etc/wireguard 2>/dev/null | tr '\n' ' ')"

seccion "Resultado"
if [ "$HALLAZGOS" -eq 0 ]; then
  printf '  %sSin colisiones para: %s%s\n' "$C_GRN" "$RANGOS" "$C_OFF"
else
  printf '  %s%s hallazgo(s). Revisar antes de instalar.%s\n' "$C_RED" "$HALLAZGOS" "$C_OFF"
fi
if [ "$SIN_COBERTURA" -gt 0 ]; then
  printf '  %s%s chequeo(s) sin cubrir. Reejecutar como root para un resultado completo.%s\n' \
      "$C_YEL" "$SIN_COBERTURA" "$C_OFF"
fi

[ "$HALLAZGOS" -eq 0 ]
