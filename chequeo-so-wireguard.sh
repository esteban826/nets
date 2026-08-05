#!/usr/bin/env bash
# =============================================================================
#  chequeo-so-wireguard.sh
#
#  Verificacion de aptitud del sistema operativo para instalar el cliente
#  WireGuard del proyecto VPN hub-and-spoke SCADA / RECO.
#
#  Complementa a chequeo-rangos.sh:
#    chequeo-rangos.sh      responde "el direccionamiento esta libre?"
#    chequeo-so-wireguard.sh responde "este sistema puede sostener el tunel?"
#
#  SOLO LECTURA. No instala, no modifica configuracion, no toca el firewall
#  ni levanta interfaces. La unica accion que escribe algo en el sistema es
#  cargar el modulo del kernel, y solo si se pide con --probar-modulo.
#
#  Uso:
#    sudo ./chequeo-so-wireguard.sh
#    sudo ./chequeo-so-wireguard.sh --hub-endpoint 203.0.113.10:51820
#    sudo ./chequeo-so-wireguard.sh --probar-modulo
#    ./chequeo-so-wireguard.sh --ayuda
#
#  Sin root funciona igual pero varias comprobaciones quedan como
#  INDETERMINADAS: leer el firewall y los modulos del kernel lo requiere.
#
#  CODIGOS DE SALIDA
#    0  apto
#    1  apto con advertencias, revisar antes de instalar
#    2  NO apto: hay al menos un bloqueante
# =============================================================================

# Sin -e a proposito. Este script vive de comandos que fallan de forma
# esperada (un grep sin match, un binario ausente): con -e, la primera
# comprobacion negativa abortaria el chequeo entero y perderias el resto
# del diagnostico, que es justamente lo que se vino a buscar.
set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

VERSION="1.0"

# Valores del diseno. Cambiarlos aqui si cambia el proyecto.
MTU_TUNEL=1420
ENCAP_WG=60                 # cabecera WireGuard sobre IPv4
RANGO_OVERLAY="10.255.0.0/16"
RANGO_LAN="10.20.0.0/16"
KERNEL_MIN_MAYOR=5
KERNEL_MIN_MENOR=6          # WireGuard esta en el kernel desde 5.6

HUB_ENDPOINT=""
PROBAR_MODULO=0

# ----------------------------------------------------------------------------
# Salida
# ----------------------------------------------------------------------------
if [ -t 1 ]; then
  C_RED=$'\033[0;31m'; C_YEL=$'\033[0;33m'; C_GRN=$'\033[0;32m'
  C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m';    C_OFF=$'\033[0m'
else
  C_RED=""; C_YEL=""; C_GRN=""; C_BLU=""; C_BLD=""; C_OFF=""
fi

N_OK=0; N_AVISO=0; N_BLOQUEA=0; N_INDET=0
RESUMEN=""

ok()      { printf '  %s[  OK  ]%s %s\n' "$C_GRN" "$C_OFF" "$*"; N_OK=$((N_OK+1)); }
aviso()   { printf '  %s[ AVISO]%s %s\n' "$C_YEL" "$C_OFF" "$*"; N_AVISO=$((N_AVISO+1))
            RESUMEN="${RESUMEN}  [AVISO]   $*\n"; }
bloquea() { printf '  %s[BLOQUEA]%s %s\n' "$C_RED" "$C_OFF" "$*"; N_BLOQUEA=$((N_BLOQUEA+1))
            RESUMEN="${RESUMEN}  [BLOQUEA] $*\n"; }
# [ n/d ] = no determinado. Mismo marcador que usa chequeo-rangos.sh en este
# repo: una comprobacion que no se pudo hacer no es una comprobacion superada.
indet()   { printf '  %s[ n/d ]%s %s\n' "$C_BLU" "$C_OFF" "$*"; N_INDET=$((N_INDET+1))
            RESUMEN="${RESUMEN}  [n/d]     $*\n"; }
dato()    { printf '           %s\n' "$*"; }
titulo()  { printf '\n%s=== %s ===%s\n' "$C_BLD" "$*" "$C_OFF"; }
nota()    { printf '           %s%s%s\n' "$C_BLU" "$*" "$C_OFF"; }

es_root() { [ "$(id -u)" -eq 0 ]; }
hay()     { command -v "$1" >/dev/null 2>&1; }

ayuda() {
  printf '%schequeo-so-wireguard.sh v%s%s\n' "$C_BLD" "$VERSION" "$C_OFF"
  sed -n '2,/^# ==*$/p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'FIN'

OPCIONES
  --hub-endpoint IP:PTO   Concentrador RB5009. Habilita las pruebas de
                          alcance y de MTU contra el destino real
  --probar-modulo         Ejecuta modprobe wireguard. Es la unica accion que
                          modifica algo del sistema, y es reversible
  --ayuda                 Esta ayuda
FIN
}

while [ $# -gt 0 ]; do
  case "$1" in
    --hub-endpoint)  HUB_ENDPOINT="${2:-}"; shift 2 ;;
    --probar-modulo) PROBAR_MODULO=1; shift ;;
    --ayuda|-h|--help) ayuda; exit 0 ;;
    *) printf 'Opcion desconocida: %s (usar --ayuda)\n' "$1" >&2; exit 1 ;;
  esac
done

printf '%schequeo-so-wireguard.sh v%s%s\n' "$C_BLD" "$VERSION" "$C_OFF"
printf 'Objetivo: cliente WireGuard hacia concentrador RB5009\n'
printf 'Overlay %s   LAN de sitio %s   MTU %s\n' "$RANGO_OVERLAY" "$RANGO_LAN" "$MTU_TUNEL"
es_root || printf '\n%s[ AVISO]%s Sin root. Varias comprobaciones quedaran indeterminadas.\n' "$C_YEL" "$C_OFF"

# ============================================================================
titulo "1. Sistema base"
# ============================================================================
if [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  dato "Distribucion : ${PRETTY_NAME:-desconocida}"
  case "${ID:-}${ID_LIKE:-}" in
    *debian*) ok "Debian o derivado. El instalador esta escrito para apt." ;;
    *) aviso "No es Debian ni derivado (${ID:-?}). instalar-wg-scada.sh usa apt-get." ;;
  esac
else
  aviso "No existe /etc/os-release. No puedo identificar la distribucion."
fi

dato "Arquitectura : $(uname -m)"
dato "Kernel       : $(uname -r)"

KVER="$(uname -r)"
KMAY="${KVER%%.*}"
KRESTO="${KVER#*.}"
KMEN="${KRESTO%%.*}"
if printf '%s' "$KMAY$KMEN" | grep -Eq '^[0-9]+$'; then
  if [ "$KMAY" -gt "$KERNEL_MIN_MAYOR" ] || \
     { [ "$KMAY" -eq "$KERNEL_MIN_MAYOR" ] && [ "$KMEN" -ge "$KERNEL_MIN_MENOR" ]; }; then
    ok "Kernel ${KMAY}.${KMEN} >= ${KERNEL_MIN_MAYOR}.${KERNEL_MIN_MENOR}: WireGuard viene integrado."
  else
    aviso "Kernel ${KMAY}.${KMEN} anterior a ${KERNEL_MIN_MAYOR}.${KERNEL_MIN_MENOR}. Puede necesitar wireguard-dkms o userspace."
  fi
else
  indet "No pude interpretar la version del kernel: ${KVER}"
fi

if hay systemctl && [ -d /run/systemd/system ]; then
  ok "systemd activo. wg-quick@.service es utilizable."
else
  bloquea "systemd no esta activo. El instalador depende de wg-quick@<iface>.service."
fi

# ============================================================================
titulo "2. Soporte de WireGuard en el kernel"
# ============================================================================
# Es el unico bloqueante duro posible. Se comprueba en varios niveles porque
# WireGuard puede estar integrado en el kernel, disponible como modulo, o
# no estar en absoluto.
VIRT="desconocida"
hay systemd-detect-virt && VIRT="$(systemd-detect-virt 2>/dev/null || echo ninguna)"
dato "Virtualizacion: ${VIRT}"

case "$VIRT" in
  openvz|lxc|lxc-libvirt|docker|podman|wsl)
    bloquea "Virtualizacion ${VIRT}: el contenedor comparte el kernel del anfitrion y no puede cargar modulos."
    nota "Salida posible: WireGuard en userspace (wireguard-go o boringtun)."
    nota "Requiere /dev/net/tun expuesto y el proveedor tiene que permitirlo."
    ;;
  kvm|qemu|vmware|microsoft|xen|amazon|oracle|bochs|parallels|none|ninguna)
    ok "Virtualizacion ${VIRT}: admite modulos de kernel propios."
    ;;
  *) indet "Virtualizacion no reconocida: ${VIRT}" ;;
esac

MODULO_OK=0
if [ -d /sys/module/wireguard ]; then
  ok "El modulo wireguard YA esta cargado."
  MODULO_OK=1
elif grep -q '^wireguard ' /proc/modules 2>/dev/null; then
  ok "wireguard presente en /proc/modules."
  MODULO_OK=1
elif [ -f "/boot/config-${KVER}" ] && grep -q '^CONFIG_WIREGUARD=y' "/boot/config-${KVER}" 2>/dev/null; then
  ok "WireGuard compilado dentro del kernel (CONFIG_WIREGUARD=y). No hace falta modulo."
  MODULO_OK=1
elif hay modinfo && modinfo wireguard >/dev/null 2>&1; then
  ok "Modulo wireguard disponible para cargar: $(modinfo -n wireguard 2>/dev/null || echo presente)"
  MODULO_OK=1
else
  if es_root; then
    if [ "$PROBAR_MODULO" -eq 1 ]; then
      if modprobe wireguard 2>/dev/null; then
        ok "modprobe wireguard cargo el modulo correctamente."
        MODULO_OK=1
      else
        bloquea "modprobe wireguard fallo. Este kernel no puede ofrecer WireGuard nativo."
      fi
    else
      indet "No encuentro el modulo por inspeccion. Reejecutar con --probar-modulo para la prueba definitiva."
    fi
  else
    indet "Sin root no puedo inspeccionar los modulos del kernel."
  fi
fi

if [ -c /dev/net/tun ]; then
  ok "/dev/net/tun presente. Habilita la alternativa userspace si hiciera falta."
else
  if [ "$MODULO_OK" -eq 1 ]; then
    dato "/dev/net/tun ausente, pero no hace falta: WireGuard nativo no lo usa."
  else
    aviso "/dev/net/tun ausente y sin modulo nativo: no queda ninguna via para el tunel."
  fi
fi

# ============================================================================
titulo "3. Herramientas y paquetes"
# ============================================================================
for h in ip wg wg-quick nft iptables systemctl ping; do
  if hay "$h"; then
    ok "${h} disponible: $(command -v "$h")"
  else
    case "$h" in
      wg|wg-quick) aviso "${h} ausente. Lo instala el instalador (paquete wireguard-tools)." ;;
      nft)         aviso "nft ausente. Lo instala el instalador (paquete nftables)." ;;
      iptables)    dato "iptables ausente. No es requisito." ;;
      *)           bloquea "${h} ausente y es imprescindible." ;;
    esac
  fi
done

if hay apt-get; then
  ok "apt-get disponible."
  if es_root; then
    if apt-get -s install wireguard-tools nftables >/dev/null 2>&1; then
      ok "Los paquetes wireguard-tools y nftables son instalables desde los repos actuales."
    else
      aviso "apt-get no puede resolver wireguard-tools o nftables. Revisar sources.list y conectividad."
    fi
  else
    indet "Sin root no puedo simular la instalacion de paquetes."
  fi
else
  aviso "Sin apt-get. El instalador no va a poder instalar dependencias por si solo."
fi

# ============================================================================
titulo "4. Interfaz de salida y MTU"
# ============================================================================
IFACE_DEF="$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')"
IP_DEF="$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')"
if [ -n "${IFACE_DEF:-}" ]; then
  ok "Interfaz de salida: ${IFACE_DEF} (gateway ${IP_DEF:-?})"
  ip -brief address show "$IFACE_DEF" 2>/dev/null | sed 's/^/           /'
  MTU_WAN="$(cat "/sys/class/net/${IFACE_DEF}/mtu" 2>/dev/null || echo 0)"
  dato "MTU de ${IFACE_DEF}: ${MTU_WAN}"
  NECESARIO=$((MTU_TUNEL + ENCAP_WG))
  if [ "$MTU_WAN" -ge "$NECESARIO" ] 2>/dev/null; then
    ok "MTU suficiente: ${MTU_WAN} >= ${MTU_TUNEL}+${ENCAP_WG}=${NECESARIO}."
  elif [ "$MTU_WAN" -gt 0 ]; then
    aviso "MTU ${MTU_WAN} menor que ${NECESARIO}. Bajar el MTU del tunel: --mtu $((MTU_WAN - ENCAP_WG))"
  fi
else
  bloquea "No hay ruta por defecto. El host no tiene salida y el tunel no puede iniciar."
fi

if ip route show default 2>/dev/null | grep -q 'dev wg'; then
  aviso "Ya existe una ruta por defecto por una interfaz WireGuard. Este diseno lo prohibe."
fi

# ============================================================================
titulo "5. Parametros de red del kernel"
# ============================================================================
leer_sysctl() { cat "/proc/sys/$1" 2>/dev/null || echo "?"; }

FWD="$(leer_sysctl net/ipv4/ip_forward)"
case "$FWD" in
  1)
    aviso "ip_forward=1. Normal con Docker. El instalador NO lo cambia y bloquea el reenvio solo en el tunel."
    nota "Si el colector SCADA corre en un contenedor, ese bloqueo le impide llegar a los RECO."
    ;;
  0) ok "ip_forward=0. Este host no reenvia trafico." ;;
  # Nunca dar por bueno lo que no se pudo leer: en un preflight, un OK falso
  # es peor que un indeterminado.
  *) indet "No pude leer ip_forward. Verificar a mano: sysctl net.ipv4.ip_forward" ;;
esac

RPF="$(leer_sysctl net/ipv4/conf/all/rp_filter)"
dato "rp_filter (all): ${RPF}"
case "$RPF" in
  2) ok "rp_filter en modo loose. Es lo mas seguro con rutas asimetricas." ;;
  1) dato "rp_filter estricto. Correcto con una sola salida y rutas especificas como las de este diseno." ;;
  0) dato "rp_filter desactivado." ;;
  *) indet "No pude leer rp_filter." ;;
esac

if [ -d /proc/sys/net/netfilter ] || lsmod 2>/dev/null | grep -q nf_conntrack; then
  ok "conntrack disponible. Las reglas 'ct state' de la tabla del tunel van a funcionar."
  CTMAX="$(leer_sysctl net/netfilter/nf_conntrack_max)"
  CTCUR="$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo '?')"
  dato "conntrack en uso: ${CTCUR} de ${CTMAX}"
else
  indet "No pude confirmar conntrack. Las reglas de estado dependen de el."
fi

IPV6_OFF="$(leer_sysctl net/ipv6/conf/all/disable_ipv6)"
dato "IPv6 deshabilitado: ${IPV6_OFF} (0 = IPv6 activo)"

# ============================================================================
titulo "6. Firewall existente"
# ============================================================================
if hay iptables; then
  BACKEND="$(iptables -V 2>/dev/null)"
  dato "iptables: ${BACKEND}"
  case "$BACKEND" in
    *nf_tables*) ok "iptables usa el backend nf_tables. Convive de forma natural con la tabla nftables del tunel." ;;
    *legacy*)    aviso "iptables en modo legacy junto a nftables. Conviven, pero el orden de evaluacion es menos evidente." ;;
  esac
fi

if es_root && hay iptables; then
  for cadena in INPUT OUTPUT FORWARD; do
    POL="$(iptables -S "$cadena" 2>/dev/null | awk -v c="$cadena" '$1=="-P" && $2==c {print $3; exit}')"
    case "${POL:-?}" in
      ACCEPT) dato "Politica ${cadena}: ACCEPT" ;;
      DROP|REJECT)
        if [ "$cadena" = "OUTPUT" ]; then
          aviso "Politica OUTPUT=${POL}. Verificar que el UDP saliente hacia el concentrador este permitido."
        else
          dato "Politica ${cadena}: ${POL}"
        fi ;;
      *) indet "No pude leer la politica de ${cadena}." ;;
    esac
  done
  N_REGLAS="$(iptables -S 2>/dev/null | grep -c '^-A' || true)"
  dato "Reglas iptables activas: ${N_REGLAS:-0}"
else
  indet "Sin root no puedo leer las reglas de iptables."
fi

if hay systemctl; then
  if systemctl is-enabled nftables >/dev/null 2>&1; then
    aviso "nftables.service esta habilitado: al arrancar carga /etc/nftables.conf."
    nota "El instalador usa su propia tabla via PostUp. Revisar que ese archivo no la pise."
  else
    ok "nftables.service no habilitado. La tabla del tunel la gestiona wg-quick."
  fi
  for s in ufw firewalld; do
    if systemctl is-active --quiet "$s" 2>/dev/null; then
      aviso "${s} activo. El instalador no lo toca, pero puede filtrar el trafico del tunel."
    fi
  done
fi

if es_root && hay nft; then
  if nft list tables 2>/dev/null | grep -q 'scada_'; then
    aviso "Ya existe una tabla scada_* de una instalacion previa:"
    nft list tables 2>/dev/null | grep 'scada_' | sed 's/^/           /'
  fi
fi

# ============================================================================
titulo "7. Docker y contenedores"
# ============================================================================
# Determina si el colector SCADA corre en un contenedor, que es lo que decide
# si hace falta una excepcion de reenvio en la tabla nftables del tunel.
if hay docker; then
  if docker info >/dev/null 2>&1; then
    ok "Docker operativo."
    printf '           Redes:\n'
    docker network ls --format '  {{.Name}}' 2>/dev/null | sed 's/^/           /'
    printf '           Contenedores en ejecucion:\n'
    if [ -n "$(docker ps -q 2>/dev/null)" ]; then
      docker ps --format '  {{.Names}}  {{.Image}}  {{.Ports}}' 2>/dev/null | sed 's/^/           /'
      aviso "Hay contenedores corriendo. Si alguno es el colector SCADA, necesita una excepcion de reenvio."
      nota "La cadena 'reenvio' del instalador descarta TODO lo que entra o sale por el tunel."
      nota "Un contenedor que hable con los RECO queda bloqueado por esa regla."
    else
      dato "Ninguno en ejecucion."
    fi
    # Subredes declaradas, para cruzar con los rangos del proyecto
    printf '           Subredes docker:\n'
    for red in $(docker network ls --format '{{.Name}}' 2>/dev/null); do
      SUB="$(docker network inspect "$red" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null)"
      [ -n "${SUB// /}" ] && printf '           %-22s %s\n' "$red" "$SUB"
    done
    if [ -f /etc/docker/daemon.json ] && grep -q 'default-address-pools' /etc/docker/daemon.json 2>/dev/null; then
      ok "daemon.json define default-address-pools. Docker no se autoasigna rangos libremente."
    else
      aviso "Sin default-address-pools en daemon.json. Docker se autoasigna /16 dentro de 172.17.0.0/12."
      nota "Por eso las LAN de sitio son 10.20.S.0/24 y no 172.20.S.0/24."
    fi
  else
    indet "Docker instalado pero no puedo consultarlo. Se necesita root o pertenecer al grupo docker."
  fi
else
  ok "Docker no instalado. Sin contenedores que compliquen el reenvio."
fi

# ============================================================================
titulo "8. Gestion de red y arranque"
# ============================================================================
for s in systemd-networkd NetworkManager networking; do
  if hay systemctl && systemctl is-active --quiet "$s" 2>/dev/null; then
    dato "Activo: ${s}"
  fi
done
if hay systemctl && systemctl is-active --quiet NetworkManager 2>/dev/null; then
  aviso "NetworkManager activo. Puede intentar gestionar la interfaz del tunel."
  nota "Si ocurre, excluirla: agregar 'unmanaged-devices=interface-name:wg*' en NetworkManager.conf"
fi

if [ -f /lib/systemd/system/wg-quick@.service ] || [ -f /usr/lib/systemd/system/wg-quick@.service ]; then
  ok "La unit wg-quick@.service esta presente."
else
  dato "wg-quick@.service todavia no existe. Llega con el paquete wireguard-tools."
fi

# ============================================================================
titulo "9. Reloj del sistema"
# ============================================================================
# WireGuard incorpora una marca de tiempo en el handshake como proteccion
# contra repeticion. Un reloj que salta hacia atras produce handshakes
# rechazados por el otro extremo, con un sintoma que no menciona la hora.
if hay timedatectl; then
  SYNC="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo '?')"
  dato "Hora: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  case "$SYNC" in
    yes) ok "Reloj sincronizado por NTP." ;;
    no)  aviso "Reloj NO sincronizado. Un salto de reloj hace que el hub rechace el handshake." ;;
    *)   indet "No pude determinar el estado de sincronizacion." ;;
  esac
else
  indet "Sin timedatectl. Verificar la sincronizacion horaria a mano."
fi

# ============================================================================
titulo "10. Almacenamiento y permisos"
# ============================================================================
for d in /etc /var/backups; do
  [ -d "$d" ] || continue
  LIBRE="$(df -Pk "$d" 2>/dev/null | awk 'NR==2{print int($4/1024)}')"
  if [ -n "${LIBRE:-}" ] && [ "$LIBRE" -lt 50 ] 2>/dev/null; then
    aviso "Solo ${LIBRE} MB libres en ${d}. El instalador escribe config y respaldos."
  else
    dato "${d}: ${LIBRE:-?} MB libres"
  fi
done

if [ -d /etc/wireguard ]; then
  PERM="$(stat -c '%a' /etc/wireguard 2>/dev/null || echo '?')"
  if [ "$PERM" = "700" ]; then
    ok "/etc/wireguard existe con permisos 700."
  else
    aviso "/etc/wireguard tiene permisos ${PERM}, se esperan 700. Contiene claves privadas."
  fi
  N_CONF="$(ls -1 /etc/wireguard/*.conf 2>/dev/null | wc -l | tr -d ' ')"
  [ "${N_CONF:-0}" -gt 0 ] && aviso "Ya hay ${N_CONF} configuracion(es) en /etc/wireguard. Revisar antes de instalar."
else
  ok "/etc/wireguard no existe todavia. Instalacion limpia."
fi

# ============================================================================
titulo "11. Alcance del concentrador"
# ============================================================================
if [ -n "$HUB_ENDPOINT" ]; then
  HUB_IP="${HUB_ENDPOINT%%:*}"
  HUB_PUERTO="${HUB_ENDPOINT##*:}"
  dato "Concentrador declarado: ${HUB_IP} puerto UDP ${HUB_PUERTO}"

  if ip route get "$HUB_IP" >/dev/null 2>&1; then
    ok "Hay ruta hacia ${HUB_IP}: $(ip route get "$HUB_IP" 2>/dev/null | head -1)"
  else
    bloquea "No hay ruta hacia ${HUB_IP}."
  fi

  if ping -c 2 -W 3 -n "$HUB_IP" >/dev/null 2>&1; then
    ok "${HUB_IP} responde ICMP."
  else
    dato "${HUB_IP} no responde ICMP. No es concluyente: muchos routers lo filtran."
  fi

  # El UDP no confirma entrega. Enviar un datagrama solo prueba que el envio
  # local no fue rechazado, no que haya llegado al otro extremo.
  if (echo -n "" >"/dev/udp/${HUB_IP}/${HUB_PUERTO}") 2>/dev/null; then
    ok "El envio UDP hacia ${HUB_IP}:${HUB_PUERTO} no fue rechazado localmente."
  else
    aviso "No se pudo emitir UDP hacia ${HUB_IP}:${HUB_PUERTO}. Revisar filtrado de egreso."
  fi
  nota "La unica prueba concluyente del camino UDP es el handshake real."
  nota "Se confirma con: wg show wg0 latest-handshakes"
else
  indet "Sin --hub-endpoint no puedo evaluar el alcance del concentrador."
fi

# ============================================================================
titulo "12. Rangos del proyecto"
# ============================================================================
# Chequeo minimo para que este script sea autosuficiente. El analisis
# completo de solapamientos lo hace chequeo-rangos.sh.
if ! hay ip; then
  # Sin 'ip' no hay tabla de rutas que leer. Declarar el rango libre aqui
  # seria afirmar algo que no se comprobo.
  indet "Sin el comando 'ip' no puedo verificar si los rangos estan en uso."
else
  for rango in "$RANGO_OVERLAY" "$RANGO_LAN"; do
    BASE="$(printf '%s' "$rango" | cut -d/ -f1)"
    O1="$(printf '%s' "$BASE" | cut -d. -f1)"
    O2="$(printf '%s' "$BASE" | cut -d. -f2)"
    if ip route show 2>/dev/null | grep -Eq "^${O1}\.${O2}\." || \
       ip -4 address show 2>/dev/null | grep -Eq "inet ${O1}\.${O2}\."; then
      bloquea "El rango ${rango} ya esta en uso en este host."
      ip route show 2>/dev/null | grep -E "^${O1}\.${O2}\." | sed 's/^/           /'
      ip -4 address show 2>/dev/null | grep -E "inet ${O1}\.${O2}\." | sed 's/^/           /'
    else
      ok "Rango ${rango} libre."
    fi
  done
fi
nota "Para el analisis completo de solapamientos: ./chequeo-rangos.sh ${RANGO_OVERLAY} ${RANGO_LAN}"

# ============================================================================
titulo "Resultado"
# ============================================================================
printf '  %s OK   %s aviso(s)   %s bloqueante(s)   %s no determinado(s)\n\n' \
  "$N_OK" "$N_AVISO" "$N_BLOQUEA" "$N_INDET"

if [ -n "$RESUMEN" ]; then
  printf 'Puntos a revisar:\n'
  printf '%b' "$RESUMEN"
  printf '\n'
fi

if [ "$N_BLOQUEA" -gt 0 ]; then
  printf '%s[BLOQUEA]%s Sistema NO apto. Resolver los bloqueantes antes de instalar.\n' "$C_RED" "$C_OFF"
  exit 2
elif [ "$N_AVISO" -gt 0 ] || [ "$N_INDET" -gt 0 ]; then
  printf '%s[ AVISO]%s Apto con reservas. Revisar los puntos de arriba antes de instalar.\n' "$C_YEL" "$C_OFF"
  exit 1
else
  printf '%s[  OK  ]%s Sistema apto para instalar el cliente WireGuard.\n' "$C_GRN" "$C_OFF"
  exit 0
fi
