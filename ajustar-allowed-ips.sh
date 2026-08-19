#!/usr/bin/env bash
# ============================================================================
# ajustar-allowed-ips.sh - v1.0
#
# Agrega o quita destinos en la lista AllowedIPs del peer del hub, en un host
# cliente de WireGuard configurado con instalar-wg-scada.sh.
#
# Por que existe:
#   AllowedIPs cumple dos funciones a la vez en un cliente de un solo peer:
#     1. Es el filtro criptografico. Un paquete que llega por el tunel con un
#        origen que no esta en la lista se descarta en la recepcion, antes de
#        cualquier regla de firewall, sin log y sin ICMP de vuelta.
#     2. Es la fuente de las rutas. wg-quick instala exactamente una ruta por
#        cada entrada al levantar la interfaz.
#   Por eso, cuando se suma un equipo nuevo a la overlay (por ejemplo una PC
#   Windows), hay que declararlo aca o el trafico muere en silencio.
#
# Que hace distinto a editar el .conf a mano:
#   - Aplica el cambio EN CALIENTE con 'wg set' y reconcilia las rutas, asi que
#     no hace falta 'systemctl restart wg-quick@<iface>' y el tunel no se corta.
#     En un SCADA en produccion ese restart cuesta un ciclo de polling.
#   - Persiste el cambio en el .conf, para que sobreviva al reinicio.
#   - Valida la politica de prefijos estrictos antes de tocar nada.
#   - Verifica al final que lo que quedo en memoria y lo que quedo en disco
#     coincidan. Un cambio aplicado a medias es peor que uno no aplicado.
#
# Uso:
#   ./ajustar-allowed-ips.sh --agregar 10.255.0.20/32
#   ./ajustar-allowed-ips.sh --agregar 10.255.0.20,10.20.2.0/24
#   ./ajustar-allowed-ips.sh --quitar 10.20.2.0/24
#   ./ajustar-allowed-ips.sh --listar
#   ./ajustar-allowed-ips.sh --agregar 10.255.0.20/32 --dry-run
# ============================================================================

set -euo pipefail

VERSION="1.0"
IFACE="wg0"
WG_DIR="/etc/wireguard"
AGREGAR=""
QUITAR=""
LISTAR=0
DRY_RUN=0
SOLO_DISCO=0

rojo=$'\033[0;31m'; verde=$'\033[0;32m'; amar=$'\033[0;33m'; cyan=$'\033[0;36m'; fin=$'\033[0m'
info()  { printf '%s[+]%s %s\n' "$cyan"  "$fin" "$*"; }
ok()    { printf '%s[OK]%s %s\n' "$verde" "$fin" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$amar"  "$fin" "$*"; }
die()   { printf '%s[X]%s %s\n' "$rojo"  "$fin" "$*" >&2; exit 1; }

ayuda() {
  cat <<'FIN'
ajustar-allowed-ips.sh - ajusta AllowedIPs del peer del hub sin cortar el tunel

  --agregar LISTA    Destinos a agregar, separados por coma. Una IP sin mascara
                     se toma como /32. Ej: 10.255.0.20 o 10.20.2.0/24
  --quitar LISTA     Destinos a quitar, mismo formato.
  --listar           Muestra la lista actual (disco y memoria) y termina.
  --iface NOMBRE     Interfaz WireGuard. Por defecto wg0.
  --solo-disco       Solo persiste en el .conf, no aplica en caliente.
                     El cambio recien toma efecto al reiniciar el servicio.
  --dry-run          Muestra que haria sin tocar nada.
  -h, --help         Esta ayuda.

Politica de prefijos: no se admite 0.0.0.0/0 ni nada mas ancho que /24.
FIN
}

while [ $# -gt 0 ]; do
  case "$1" in
    --agregar)    AGREGAR="${2:-}"; shift 2 ;;
    --quitar)     QUITAR="${2:-}";  shift 2 ;;
    --listar)     LISTAR=1; shift ;;
    --iface)      IFACE="${2:-}";   shift 2 ;;
    --solo-disco) SOLO_DISCO=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)    ayuda; exit 0 ;;
    *)            die "Opcion desconocida: $1 (usa --help)" ;;
  esac
done

CONF="${WG_DIR}/${IFACE}.conf"

# ------------------------------------------------------------- validaciones

validar_ip() {
  local ip="$1" o
  [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a o <<< "$ip"
  for n in "${o[@]}"; do [ "$n" -le 255 ] || return 1; done
  return 0
}

# Normaliza una entrada a CIDR y aplica la politica de prefijos estrictos.
# Una IP suelta se interpreta como host /32, que es el caso de los equipos
# de la overlay.
normalizar() {
  local e="$1" ip masc
  if [[ "$e" == */* ]]; then
    ip="${e%%/*}"; masc="${e##*/}"
  else
    ip="$e"; masc="32"
  fi
  validar_ip "$ip" || die "Direccion invalida: $e"
  [[ "$masc" =~ ^[0-9]+$ ]] && [ "$masc" -le 32 ] || die "Mascara invalida: $e"
  [ "$e" != "0.0.0.0/0" ] || die "0.0.0.0/0 esta prohibido: convertiria a este host en cliente de tunel total."
  if [ "$masc" -lt 24 ]; then
    die "Prefijo demasiado ancho: ${ip}/${masc}. La politica no admite nada mas ancho que /24."
  fi
  printf '%s/%s' "$ip" "$masc"
}

[ "$(id -u)" -eq 0 ] || die "Hay que ejecutarlo como root."
[ -f "$CONF" ] || die "No existe ${CONF}. Revisa --iface."
command -v wg >/dev/null 2>&1 || die "No se encuentra el comando wg."

# Este script asume el modelo del instalador: un solo peer, el hub. Con mas de
# uno no hay forma de saber a cual aplicar el cambio sin adivinar.
N_PEERS="$(grep -c '^\[Peer\]' "$CONF" || true)"
[ "$N_PEERS" -eq 1 ] || die "${CONF} tiene ${N_PEERS} peers. Este script solo maneja configuraciones de un peer."

PUB_HUB="$(awk -F'=' '/^[[:space:]]*PublicKey/{sub(/^[[:space:]]+/,"",$0); sub(/^PublicKey[[:space:]]*=[[:space:]]*/,"",$0); print $0; exit}' "$CONF")"
PUB_HUB="$(printf '%s' "$PUB_HUB" | tr -d ' \t\r')"
[ -n "$PUB_HUB" ] || die "No se pudo leer PublicKey del peer en ${CONF}."

ACTUAL_RAW="$(awk '/^[[:space:]]*AllowedIPs/{sub(/^[[:space:]]*AllowedIPs[[:space:]]*=[[:space:]]*/,"",$0); print; exit}' "$CONF")"
[ -n "$ACTUAL_RAW" ] || die "No se encontro la linea AllowedIPs en ${CONF}."

# ------------------------------------------------------- lista actual

declare -a LISTA=()
IFS=',' read -r -a _tmp <<< "$ACTUAL_RAW"
for e in "${_tmp[@]}"; do
  e="$(printf '%s' "$e" | tr -d ' \t\r')"
  [ -n "$e" ] && LISTA+=("$e")
done

en_lista() {
  local buscar="$1" x
  for x in "${LISTA[@]}"; do [ "$x" = "$buscar" ] && return 0; done
  return 1
}

if [ "$LISTAR" -eq 1 ]; then
  info "Interfaz: ${IFACE}   Peer del hub: ${PUB_HUB}"
  echo
  info "AllowedIPs en disco (${CONF}):"
  for e in "${LISTA[@]}"; do echo "      $e"; done
  echo
  if ip link show "$IFACE" >/dev/null 2>&1; then
    info "AllowedIPs en memoria (wg show):"
    wg show "$IFACE" allowed-ips | awk '{for(i=2;i<=NF;i++) print "      "$i}'
    echo
    info "Rutas por ${IFACE}:"
    ip route show dev "$IFACE" | sed 's/^/      /'
  else
    warn "La interfaz ${IFACE} no esta levantada."
  fi
  exit 0
fi

[ -n "$AGREGAR" ] || [ -n "$QUITAR" ] || die "Nada que hacer. Usa --agregar, --quitar o --listar."

# ------------------------------------------------------- calcular cambios

declare -a NUEVOS=() SACADOS=()

if [ -n "$AGREGAR" ]; then
  IFS=',' read -r -a _add <<< "$AGREGAR"
  for e in "${_add[@]}"; do
    e="$(printf '%s' "$e" | tr -d ' \t\r')"
    [ -n "$e" ] || continue
    n="$(normalizar "$e")"
    if en_lista "$n"; then
      warn "Ya estaba en la lista, se ignora: $n"
    else
      LISTA+=("$n"); NUEVOS+=("$n")
    fi
  done
fi

if [ -n "$QUITAR" ]; then
  IFS=',' read -r -a _del <<< "$QUITAR"
  for e in "${_del[@]}"; do
    e="$(printf '%s' "$e" | tr -d ' \t\r')"
    [ -n "$e" ] || continue
    n="$(normalizar "$e")"
    if en_lista "$n"; then
      declare -a _keep=()
      for x in "${LISTA[@]}"; do [ "$x" = "$n" ] || _keep+=("$x"); done
      LISTA=("${_keep[@]}")
      SACADOS+=("$n")
    else
      warn "No estaba en la lista, se ignora: $n"
    fi
  done
fi

if [ "${#NUEVOS[@]}" -eq 0 ] && [ "${#SACADOS[@]}" -eq 0 ]; then
  ok "La lista ya estaba como se pidio. No se toca nada."
  exit 0
fi

[ "${#LISTA[@]}" -gt 0 ] || die "El cambio dejaria AllowedIPs vacio. El tunel quedaria inutilizable."

# Quitar el endpoint overlay del hub deja el tunel sin diagnostico posible y
# suele ser un error de tipeo, no una decision.
for s in "${SACADOS[@]:-}"; do
  case "$s" in
    10.255.0.1/32) warn "Estas quitando la IP overlay del hub. Vas a perder el ping de diagnostico al concentrador." ;;
  esac
done

LISTA_ORD="$(printf '%s\n' "${LISTA[@]}" | sort -u -V)"
LISTA_CSV="$(printf '%s' "$LISTA_ORD" | paste -sd',' -)"
# Ojo: 'paste -sd", "' NO usa ", " como separador, alterna coma y espacio uno
# por vez. Hay que unir con coma y espaciar despues.
LISTA_FMT="$(printf '%s' "$LISTA_ORD" | paste -sd',' - | sed 's/,/, /g')"

echo
info "Peer del hub: ${PUB_HUB}"
for e in "${NUEVOS[@]:-}";  do [ -n "$e" ] && printf '      %s+ %s%s\n' "$verde" "$e" "$fin"; done
for e in "${SACADOS[@]:-}"; do [ -n "$e" ] && printf '      %s- %s%s\n' "$rojo"  "$e" "$fin"; done
echo
info "Lista resultante (${#LISTA[@]} entradas):"
printf '%s\n' "$LISTA_ORD" | sed 's/^/      /'
echo

if [ "$DRY_RUN" -eq 1 ]; then
  warn "dry-run: no se modifico nada."
  echo "      wg set ${IFACE} peer ${PUB_HUB} allowed-ips ${LISTA_CSV}"
  echo "      AllowedIPs   = ${LISTA_FMT}   -> ${CONF}"
  exit 0
fi

# ------------------------------------------------------- aplicar en caliente

if [ "$SOLO_DISCO" -eq 1 ]; then
  warn "--solo-disco: el cambio no toma efecto hasta reiniciar wg-quick@${IFACE}."
elif ! ip link show "$IFACE" >/dev/null 2>&1; then
  warn "La interfaz ${IFACE} no esta levantada: solo se persiste en disco."
else
  # 'wg set allowed-ips' REEMPLAZA la lista completa del peer, no agrega. Por
  # eso se manda siempre la lista entera ya calculada.
  wg set "$IFACE" peer "$PUB_HUB" allowed-ips "$LISTA_CSV"
  ok "Aplicado en caliente sobre ${IFACE} (sin cortar el tunel)."

  # wg-quick instala las rutas al levantar la interfaz, pero 'wg set' no toca
  # la tabla de ruteo. Hay que reconciliarla a mano o el trafico de vuelta no
  # encuentra salida.
  for e in "${NUEVOS[@]:-}"; do
    [ -n "$e" ] || continue
    if ip route replace "$e" dev "$IFACE" 2>/dev/null; then
      ok "Ruta instalada: ${e} dev ${IFACE}"
    else
      warn "No se pudo instalar la ruta ${e} dev ${IFACE}. Revisala a mano."
    fi
  done
  for e in "${SACADOS[@]:-}"; do
    [ -n "$e" ] || continue
    if ip route show dev "$IFACE" | grep -qE "(^| )${e%/32}( |/)"; then
      ip route del "$e" dev "$IFACE" 2>/dev/null && ok "Ruta eliminada: ${e}" || warn "No se pudo eliminar la ruta ${e}."
    fi
  done
fi

# ------------------------------------------------------------- persistir

BACKUP="${CONF}.bak.$(date +%Y%m%d-%H%M%S)"
cp -p "$CONF" "$BACKUP"
chmod 600 "$BACKUP"
info "Copia de seguridad: ${BACKUP}"

tmp="$(mktemp)"
chmod 600 "$tmp"
awk -v nueva="AllowedIPs   = ${LISTA_FMT}" '
  /^[[:space:]]*AllowedIPs/ && !hecho { print nueva; hecho=1; next }
  { print }
  END { if (!hecho) exit 3 }
' "$CONF" > "$tmp" || die "No se pudo reescribir AllowedIPs en ${CONF}. El archivo original quedo intacto."

mv "$tmp" "$CONF"
chmod 600 "$CONF"
ok "Persistido en ${CONF}."

# ------------------------------------------------------------ verificacion

# Un cambio aplicado solo en memoria se pierde al reiniciar; uno aplicado solo
# en disco no tiene efecto hasta el reinicio. Los dos casos se ven igual desde
# afuera hasta que es tarde, asi que se comparan explicitamente.
echo
DISCO="$(awk '/^[[:space:]]*AllowedIPs/{sub(/^[[:space:]]*AllowedIPs[[:space:]]*=[[:space:]]*/,"",$0); gsub(/[ \t\r]/,"",$0); print; exit}' "$CONF" | tr ',' '\n' | sort -u -V | paste -sd',' -)"

if [ "$DISCO" != "$LISTA_CSV" ]; then
  die "La linea escrita en disco no coincide con la calculada. Restaura con: cp ${BACKUP} ${CONF}"
fi
ok "Disco verificado."

if [ "$SOLO_DISCO" -eq 0 ] && ip link show "$IFACE" >/dev/null 2>&1; then
  MEM="$(wg show "$IFACE" allowed-ips | awk '{for(i=2;i<=NF;i++) print $i}' | sort -u -V | paste -sd',' -)"
  if [ "$MEM" != "$LISTA_CSV" ]; then
    warn "Lo que hay en memoria no coincide con el disco."
    warn "  memoria: ${MEM}"
    warn "  disco:   ${LISTA_CSV}"
    warn "Reinicia el servicio para alinearlos: systemctl restart wg-quick@${IFACE}"
  else
    ok "Memoria verificada. Disco y memoria coinciden."
  fi

  echo
  info "Rutas por ${IFACE}:"
  ip route show dev "$IFACE" | sed 's/^/      /'
fi

echo
ok "Listo. No hace falta reiniciar el servicio."
