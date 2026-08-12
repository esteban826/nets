#!/usr/bin/env bash
# =============================================================================
#  instalar-wg-scada.sh
#
#  Instalador de cliente WireGuard para Debian.
#  Proyecto: VPN hub-and-spoke SCADA / RECO
#  Hub     : MikroTik RB5009 con RouterOS v7 (interfaz wg-hub)
#
#  Que hace:
#    1. Instala wireguard-tools y nftables.
#    2. Genera par de claves y clave pre-compartida (PSK) con permisos 0600.
#    3. Escribe /etc/wireguard/<iface>.conf con AllowedIPs estrictos.
#    4. Aplica un firewall nftables acotado A LA INTERFAZ DEL TUNEL.
#    5. Habilita y arranca wg-quick@<iface> via systemd.
#    6. Imprime el comando RouterOS listo para pegar en el RB5009.
#
#  Que NO hace (por diseno):
#    - No usa rutas genericas. Prohibe 0.0.0.0/0, 10.0.0.0/8, 172.16.0.0/12,
#      192.168.0.0/16 y cualquier prefijo mas amplio que /24. Aborta si las
#      detecta. Una entrada de AllowedIPs = una ruta especifica.
#    - No habilita ip_forward. Este host no es un router.
#    - No toca ni borra las reglas de firewall existentes del servidor.
#    - No modifica /etc/nftables.conf ni las reglas de ufw/firewalld.
#
#  Uso rapido (no interactivo):
#    sudo ./instalar-wg-scada.sh \
#         --ip-overlay 10.255.0.10/32 \
#         --hub-pubkey "CLAVE_PUBLICA_RB5009" \
#         --hub-endpoint 203.0.113.10:51820 \
#         --redes-reco 10.20.1.0/24,10.20.2.0/24,10.20.3.0/24 \
#         --routers-reco 10.255.1.1,10.255.2.1,10.255.3.1 \
#         --dispositivos 10.20.1.50,10.20.2.50,10.20.3.50
#
#  Otras acciones:
#    sudo ./instalar-wg-scada.sh --verificar
#    sudo ./instalar-wg-scada.sh --desinstalar
#    ./instalar-wg-scada.sh --ayuda
#
#  Sin argumentos entra en modo interactivo guiado.
# =============================================================================

set -euo pipefail

# PATH explicito. Sin esto, ejecutar el script tras un "su" sin guion deja
# /usr/sbin y /sbin fuera del PATH y herramientas como nft no se encuentran,
# aunque esten instaladas.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

VERSION="1.8"
# Historial:
#   1.8  --desinstalar podia informar exito con el tunel todavia arriba. El
#        'systemctl stop ... || true' se tragaba el fallo de wg-quick down,
#        que necesita leer el .conf: si el .conf ya no estaba, la interfaz
#        seguia levantada y cifrando, con el .conf y las claves ya borrados.
#        Ahora, si la interfaz sobrevive al stop, se elimina con ip link del
#        (no depende de ningun archivo) y al final se verifica que no exista
#        antes de dar el OK.
#   1.7  --breve pasa a imprimir dos lineas CLAVE=VALOR y nada mas. Sin
#        titulo, sin aviso, sin IP overlay: lo que se pide por telefono o por
#        chat entra en un solo mensaje y no hay que explicar que copiar.
#        El formato NOMBRE=valor ademas se puede pegar en un archivo y
#        leerlo con source, o filtrarlo con grep sin recortar prefijos.
#   1.6  Nuevo --breve: al terminar imprime solo los datos que hay que llevar
#        al concentrador (clave publica, PSK e IP overlay) y omite el bloque
#        RouterOS y el "Siguiente paso". Pensado para cuando lo ejecuta un
#        tercero que solo tiene que devolver esos dos valores: menos texto
#        que leer, menos posibilidad de que copie el bloque equivocado.
#        El bloque completo con /peers/add sirve para el alta inicial, pero
#        induce a error cuando el peer ya existe: ahi corresponde /peers/set.
#   1.5  Nuevo --sin-firewall: el cliente levanta el tunel sin politica local
#        y el filtrado queda a cargo del concentrador RB5009. Pensado para
#        servidores donde no se quiere ninguna regla local, o donde no hay
#        acceso fisico y conviene concentrar la politica en un solo lugar.
#        Retira la tabla de una instalacion previa si la encuentra, porque
#        seguiria cargada aunque el .conf ya no la mencione.
#        Sin esta opcion habia que borrar PostUp/PostDown a mano y se
#        regeneraban en la siguiente reejecucion.
#   1.4  Las LAN de sitio pasan de 172.20.S.0/24 a 10.20.S.0/24. El chequeo de
#        rangos en el servidor SCADA encontro que Docker ya tenia la red
#        on_off_default ocupando 172.20.0.0/16 entera sobre un bridge local,
#        con su ruta conectada, su MASQUERADE y un contenedor en 172.20.0.2.
#        Todo 172.16.0.0/12 es el pool que Docker se autoasigna, asi que
#        cualquier eleccion ahi dentro vuelve a chocar tarde o temprano.
#        172.20.0.0/16 pasa a estar rechazado de forma explicita.
#   1.3  Nuevo --dispositivos: la prueba de alcance apunta a la IP concreta
#        del RECO en lugar de a la primera direccion del prefijo, que con una
#        LAN /24 es la direccion de red y da falso negativo siempre.
#        Ejemplos y valores interactivos alineados a LAN /24, que es la
#        convencion que usan el generador de sitios y el concentrador.
#        La ayuda se corta en el cierre del encabezado y no en una linea fija.
#   1.2  El archivo nftables ahora declara y borra la tabla antes de crearla,
#        para que recargarlo con el tunel arriba no falle con "File exists".
#        La deteccion de solapamiento ignora las rutas del propio tunel, que
#        se reportaban como falso positivo al reejecutar el instalador.
#   1.1  PATH explicito (nft vive en /usr/sbin y no se encontraba tras "su"
#        sin guion). Verificacion real de herramientas despues de apt en
#        lugar de asumir exito. Prueba de alcance corregida para prefijos /32.
#        Correccion de salto de linea en el listado de rutas.
#   1.0  Version inicial.

# ----------------------------------------------------------------------------
# Valores por defecto
# ----------------------------------------------------------------------------
IFACE="wg0"
ROL="scada"                 # scada | admin
IP_OVERLAY=""               # ej 10.255.0.10/32
HUB_PUBKEY=""
HUB_ENDPOINT=""             # ej 203.0.113.10:51820
PSK_VALOR=""
REDES_RECO=""               # csv de prefijos LAN
ROUTERS_RECO=""             # csv de IP overlay de routers remotos
DISPOSITIVOS_RECO=""        # csv de IP concretas de los RECO, solo para pruebas
HUB_OVERLAY="10.255.0.1"    # IP overlay del concentrador, se usa siempre como /32
MASCARA_MINIMA=24           # rechaza cualquier prefijo mas amplio que un /24
TCP_PORTS=""                # csv, vacio = ningun puerto TCP permitido
UDP_PORTS=""                # csv, vacio = ningun puerto UDP permitido
MTU=1420
KEEPALIVE=25
DRY_RUN=0
ASUMIR_SI=0
SIN_FIREWALL=0              # 1 = no aplicar politica local, se hace en el hub
BREVE=0                     # 1 = al final, solo las claves y la IP overlay
ACCION="instalar"

WG_DIR="/etc/wireguard"
NFT_DIR="/etc/wireguard/nft"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/var/backups/wg-scada"

# ----------------------------------------------------------------------------
# Salida
# ----------------------------------------------------------------------------
if [ -t 1 ]; then
  C_RED=$'\033[0;31m'; C_YEL=$'\033[0;33m'; C_GRN=$'\033[0;32m'
  C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m';    C_OFF=$'\033[0m'
else
  C_RED=""; C_YEL=""; C_GRN=""; C_BLU=""; C_BLD=""; C_OFF=""
fi

info()  { printf '%s[ INFO ]%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()    { printf '%s[  OK  ]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn()  { printf '%s[ AVISO]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()   { printf '%s[ ERROR]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
titulo(){ printf '\n%s=== %s ===%s\n' "$C_BLD" "$*" "$C_OFF"; }
info_version(){ printf '%sinstalar-wg-scada.sh v%s%s\n' "$C_BLD" "$VERSION" "$C_OFF"; }

ejecutar() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  %s[dry-run]%s %s\n' "$C_YEL" "$C_OFF" "$*"
  else
    eval "$@"
  fi
}

ayuda() {
  info_version
  # Hasta la linea de cierre del encabezado, no un numero fijo: asi la ayuda
  # no se rompe ni filtra codigo cuando el encabezado cambia de largo.
  sed -n '2,/^# ==*$/p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'FIN'

OPCIONES
  --iface NOMBRE          Interfaz del tunel. Por defecto: wg0
  --rol scada|admin       Perfil de politica. Por defecto: scada
  --ip-overlay CIDR       IP de este host en la VPN, con mascara /32
  --hub-pubkey CLAVE      Clave publica del RB5009
  --hub-endpoint IP:PTO   IP publica y puerto UDP del RB5009
  --psk CLAVE             PSK existente. Si se omite, se genera una nueva
  --redes-reco CSV        LANs de sitio, ej 10.20.1.0/24,10.20.2.0/24
  --routers-reco CSV      IP overlay de routers remotos, ej 10.255.1.1
  --dispositivos CSV      IP concretas de los RECO, ej 10.20.1.50
                          No afecta rutas ni firewall: es el objetivo de la
                          prueba de alcance. Sin esto, --verificar haria ping
                          a la direccion de red (.0), que nunca responde.
  --hub-overlay IP        IP overlay del RB5009. Por defecto 10.255.0.1
  --mascara-minima N      Mascara mas amplia admitida. Por defecto 24
  --tcp CSV               Puertos TCP permitidos hacia las LAN RECO
  --udp CSV               Puertos UDP permitidos hacia las LAN RECO
  --mtu N                 MTU del tunel. Por defecto 1420
  --keepalive N           PersistentKeepalive en segundos. Por defecto 25
  --dry-run               Muestra lo que haria sin aplicar cambios
  --si                    No pide confirmaciones
  --sin-firewall          NO aplica politica local al tunel. La interfaz sube
                          sin PostUp/PostDown y sin tabla nftables propia.
                          Usar solo si el filtrado se hace en el concentrador
  --breve                 Al terminar imprime solo dos lineas:
                            PUBLIC-KEY=...
                            PRESHARED-KEY=...
                          Omite el bloque para pegar en el RB5009 y el resumen
                          de pasos siguientes. Util cuando lo ejecuta un
                          tercero que solo debe devolver esos dos valores, o
                          cuando el peer ya existe en el hub y hay que
                          actualizarlo con /peers/set en vez de /peers/add.
                          La PSK es secreta: tratarla como una contrasena
  --verificar             Solo ejecuta el diagnostico
  --desinstalar           Revierte la instalacion
  --ayuda                 Esta ayuda

POLITICA DE RUTAS - SOLO PREFIJOS ESPECIFICOS
  Este instalador NO admite rutas genericas. Cada destino se declara con su
  prefijo exacto, una entrada por red:

      10.255.0.1/32     concentrador RB5009
      10.255.1.1/32     router RECO001
      10.20.1.0/24      LAN RECO001
      10.255.2.1/32     router RECO002
      10.20.2.0/24      LAN RECO002
      ...

  Cada prefijo declarado aqui tiene que existir tambien como allowed-address
  del peer correspondiente en el RB5009, y como ruta hacia wg-hub. Si falta
  cualquiera de las tres cosas el destino no responde y no hay ningun mensaje
  de error: WireGuard descarta por cripto-routing antes del firewall.

  El script RECHAZA de forma automatica y sin aplicar cambios:
      0.0.0.0/0        10.0.0.0/8        172.16.0.0/12
      192.168.0.0/16   10.255.0.0/16     10.20.0.0/16
      172.20.0.0/16    (ocupada por Docker en el propio servidor SCADA)
  y en general cualquier prefijo mas amplio que --mascara-minima (24).

POR QUE LAS LAN DE SITIO SON 10.20.S.0/24 Y NO 172.20.S.0/24
  El pool que Docker usa por defecto para crear redes es 172.17.0.0/12 mas
  192.168.0.0/16. Cualquier LAN dentro de 172.16-172.31 compite con las redes
  que Docker se autoasigna en el servidor SCADA, y de hecho ya hay una red
  (on_off_default) ocupando 172.20.0.0/16 entera sobre un bridge local.
  Con 10.20.S.0/24 el diseno queda fuera de ese pool de forma permanente y
  todo el proyecto vive en 10.x:  10.255.x overlay,  10.20.x LAN de sitio.

  Consecuencia operativa asumida: dar de alta un sitio nuevo obliga a
  reejecutar este instalador en el servidor. Es intencional. A cambio,
  "ip route show dev wg0" documenta la topologia completa y no existe
  ninguna ruta que abarque destinos no autorizados.

PUERTOS INDUSTRIALES
  Por defecto NINGUN puerto TCP o UDP esta permitido hacia las LAN RECO.
  Solo se permite ICMP echo para supervision. Habilitar de forma explicita:
    --tcp 2404          IEC 60870-5-104
    --tcp 502           Modbus TCP
    --tcp 20000         DNP3 TCP
    --udp 20000         DNP3 UDP
    --udp 161           SNMP
    --tcp 443           HTTPS
    --tcp 22            SSH
FIN
}

# ----------------------------------------------------------------------------
# Parseo de argumentos
# ----------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --iface)          IFACE="$2"; shift 2 ;;
    --rol)            ROL="$2"; shift 2 ;;
    --ip-overlay)     IP_OVERLAY="$2"; shift 2 ;;
    --hub-pubkey)     HUB_PUBKEY="$2"; shift 2 ;;
    --hub-endpoint)   HUB_ENDPOINT="$2"; shift 2 ;;
    --psk)            PSK_VALOR="$2"; shift 2 ;;
    --redes-reco)     REDES_RECO="$2"; shift 2 ;;
    --routers-reco)   ROUTERS_RECO="$2"; shift 2 ;;
    --dispositivos)   DISPOSITIVOS_RECO="$2"; shift 2 ;;
    --hub-overlay)    HUB_OVERLAY="$2"; shift 2 ;;
    --mascara-minima) MASCARA_MINIMA="$2"; shift 2 ;;
    --tcp)            TCP_PORTS="$2"; shift 2 ;;
    --udp)            UDP_PORTS="$2"; shift 2 ;;
    --mtu)            MTU="$2"; shift 2 ;;
    --keepalive)      KEEPALIVE="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --si)             ASUMIR_SI=1; shift ;;
    --sin-firewall)   SIN_FIREWALL=1; shift ;;
    --breve)          BREVE=1; shift ;;
    --verificar)      ACCION="verificar"; shift ;;
    --desinstalar)    ACCION="desinstalar"; shift ;;
    --ayuda|-h|--help) ayuda; exit 0 ;;
    *) die "Opcion desconocida: $1 (usar --ayuda)" ;;
  esac
done

CONF="${WG_DIR}/${IFACE}.conf"
NFT_FILE="${NFT_DIR}/${IFACE}.nft"
NFT_TABLA="scada_${IFACE}"

# ----------------------------------------------------------------------------
# Comprobaciones previas
# ----------------------------------------------------------------------------
requiere_root() {
  [ "$(id -u)" -eq 0 ] || die "Este script debe ejecutarse como root (usar sudo)."
}

comprobar_sistema() {
  [ -f /etc/debian_version ] || warn "No parece Debian ni derivado. Continuo bajo tu responsabilidad."
  command -v systemctl >/dev/null 2>&1 || die "systemd no disponible. Este script depende de wg-quick@.service."
  if [ "$(uname -s)" != "Linux" ]; then
    die "Solo Linux. Si copiaste el archivo desde Windows, conviertelo antes: sed -i 's/\r$//' $0"
  fi
}

validar_cidr()   { printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'; }
validar_ip()     { printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }
validar_endpoint(){ printf '%s' "$1" | grep -Eq '^[A-Za-z0-9.:_-]+:[0-9]{1,5}$'; }

# Rechaza rutas genericas. Es una barrera dura: si un prefijo es mas amplio
# que --mascara-minima, el script aborta sin escribir nada.
validar_especifico() {
  local pref="$1" origen="${2:-parametro}"
  local masc="${pref##*/}"

  case "$pref" in
    0.0.0.0/0|::/0)
      die "RUTA GENERICA RECHAZADA en ${origen}: ${pref}. Este diseno prohibe la ruta por defecto en el tunel." ;;
    10.0.0.0/8|172.16.0.0/12|192.168.0.0/16|169.254.0.0/16)
      die "RUTA GENERICA RECHAZADA en ${origen}: ${pref}. Declara los prefijos exactos de cada sitio." ;;
    10.255.0.0/16|10.20.0.0/16)
      die "RUTA AGREGADA RECHAZADA en ${origen}: ${pref}. Usa 10.255.S.1/32 y 10.20.S.0/24 uno por uno." ;;
    # El servidor SCADA tiene Docker con la red on_off_default en 172.20.0.0/16.
    # Se rechaza el /16 y tambien cualquier prefijo de su interior: una /24 ahi
    # dentro chocaria igual contra la ruta conectada del bridge de Docker.
    172.20.*)
      die "RANGO OCUPADO EN ESTE HOST en ${origen}: ${pref}. Docker ya usa 172.20.0.0/16 (red on_off_default) sobre un bridge local. Las LAN de sitio son 10.20.S.0/24." ;;
  esac

  if ! printf '%s' "$masc" | grep -Eq '^[0-9]{1,2}$' || [ "$masc" -gt 32 ]; then
    die "Mascara invalida en ${origen}: ${pref}"
  fi
  if [ "$masc" -lt "$MASCARA_MINIMA" ]; then
    die "PREFIJO DEMASIADO AMPLIO en ${origen}: ${pref} (/${masc}). El maximo admitido es /${MASCARA_MINIMA}. Usa --mascara-minima solo si lo justificas por escrito."
  fi
  return 0
}

preguntar() {
  # preguntar <variable> <texto> <valor_por_defecto>
  local __var="$1" __txt="$2" __def="${3:-}" __resp=""
  local __actual="${!__var}"
  [ -n "$__actual" ] && return 0
  if [ -n "$__def" ]; then
    read -r -p "  ${__txt} [${__def}]: " __resp || true
    __resp="${__resp:-$__def}"
  else
    while [ -z "$__resp" ]; do
      read -r -p "  ${__txt}: " __resp || true
    done
  fi
  printf -v "$__var" '%s' "$__resp"
}

modo_interactivo() {
  titulo "Configuracion del cliente WireGuard"
  echo "  Deja vacio para aceptar el valor entre corchetes."
  echo
  preguntar IP_OVERLAY   "IP de este host en la VPN (con /32)" "10.255.0.10/32"
  preguntar HUB_PUBKEY   "Clave publica del RB5009" ""
  preguntar HUB_ENDPOINT "Endpoint del RB5009 (IP_PUBLICA:PUERTO)" ""
  preguntar REDES_RECO   "LANs RECO separadas por coma" "10.20.1.0/24,10.20.2.0/24,10.20.3.0/24"
  preguntar ROUTERS_RECO "IP overlay de routers RECO separadas por coma" "10.255.1.1,10.255.2.1,10.255.3.1"
  preguntar DISPOSITIVOS_RECO "IP de los dispositivos RECO separadas por coma" "10.20.1.50,10.20.2.50,10.20.3.50"
  echo
}

validar_parametros() {
  [ -n "$IP_OVERLAY" ]   || die "Falta --ip-overlay"
  [ -n "$HUB_PUBKEY" ]   || die "Falta --hub-pubkey"
  [ -n "$HUB_ENDPOINT" ] || die "Falta --hub-endpoint"
  [ -n "$REDES_RECO" ]   || die "Falta --redes-reco"

  validar_cidr "$IP_OVERLAY" || die "IP overlay invalida: $IP_OVERLAY (formato esperado 10.255.0.10/32)"
  case "$IP_OVERLAY" in
    */32) : ;;
    *) warn "La IP overlay no es /32. En este diseno cada peer debe usar /32 para evitar rutas conectadas amplias." ;;
  esac
  validar_endpoint "$HUB_ENDPOINT" || die "Endpoint invalido: $HUB_ENDPOINT (formato esperado IP:PUERTO)"
  printf '%s' "$HUB_PUBKEY" | grep -Eq '^[A-Za-z0-9+/]{42}[A-Za-z0-9+/=]{2}$' \
    || die "La clave publica del hub no tiene formato WireGuard valido (44 caracteres base64)."

  validar_ip "$HUB_OVERLAY" || die "IP overlay del hub invalida: $HUB_OVERLAY"
  validar_especifico "$IP_OVERLAY" "--ip-overlay"

  local r
  IFS=',' read -r -a _redes <<< "$REDES_RECO"
  for r in "${_redes[@]}"; do
    validar_cidr "$r"       || die "Red RECO invalida: $r (formato esperado 10.20.1.0/24)"
    validar_especifico "$r" "--redes-reco"
  done
  if [ -n "$ROUTERS_RECO" ]; then
    IFS=',' read -r -a _routers <<< "$ROUTERS_RECO"
    for r in "${_routers[@]}"; do
      validar_ip "$r" || die "IP de router RECO invalida: $r (se declara sin mascara, se usa como /32)"
    done
  fi
  if [ -n "$DISPOSITIVOS_RECO" ]; then
    IFS=',' read -r -a _disp <<< "$DISPOSITIVOS_RECO"
    for r in "${_disp[@]}"; do
      validar_ip "$r" || die "IP de dispositivo RECO invalida: $r (se declara sin mascara)"
    done
  fi
  case "$ROL" in scada|admin) : ;; *) die "--rol debe ser scada o admin" ;; esac
  ok "Todos los prefijos son especificos (ninguno mas amplio que /${MASCARA_MINIMA})."
}

detectar_conflictos() {
  titulo "Deteccion de solapamiento de redes"
  local pref conflicto=0
  local objetivo="${REDES_RECO},${HUB_OVERLAY}/32"
  IFS=',' read -r -a _objs <<< "$objetivo"
  for pref in "${_objs[@]}"; do
    local base="${pref%%/*}"
    local oct3 oct2 oct1
    oct1="$(printf '%s' "$base" | cut -d. -f1)"
    oct2="$(printf '%s' "$base" | cut -d. -f2)"
    # Se excluyen las rutas del propio tunel: son las que instalo este mismo
    # script en una ejecucion anterior, no un solapamiento real.
    if ip route show | grep -v " dev ${IFACE}\b" | grep -Eq "^${oct1}\.${oct2}\."; then
      warn "Ya existe una ruta local en ${oct1}.${oct2}.0.0/16 fuera del tunel. Posible solapamiento con ${pref}."
      ip route show | grep -v " dev ${IFACE}\b" | grep -E "^${oct1}\.${oct2}\." | sed 's/^/         /'
      conflicto=1
    fi
  done
  if [ "$conflicto" -eq 0 ]; then
    ok "Sin solapamientos evidentes con la tabla de rutas actual."
  else
    warn "Revisa los solapamientos antes de continuar. Un solape rompe el retorno del trafico de forma silenciosa."
    if [ "$ASUMIR_SI" -eq 0 ]; then
      read -r -p "  Continuar de todas formas? (s/N): " _c
      case "$_c" in s|S|si|SI) : ;; *) die "Instalacion cancelada por el operador." ;; esac
    fi
  fi
}

comprobar_forwarding() {
  local f
  f="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"
  if [ "$f" = "1" ]; then
    warn "net.ipv4.ip_forward=1 en este host (habitual si corre Docker o similar)."
    warn "NO se modifica para no romper otros servicios. El reenvio por ${IFACE} queda bloqueado por nftables."
  else
    ok "net.ipv4.ip_forward=0. Este host no reenvia trafico."
  fi
}

# ----------------------------------------------------------------------------
# Instalacion
# ----------------------------------------------------------------------------
instalar_paquetes() {
  titulo "Paquetes"
  local faltan=""
  command -v wg        >/dev/null 2>&1 || faltan="${faltan} wireguard-tools"
  command -v wg-quick  >/dev/null 2>&1 || faltan="${faltan} wireguard-tools"
  command -v nft       >/dev/null 2>&1 || faltan="${faltan} nftables"
  faltan="$(printf '%s' "$faltan" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
  if [ -n "${faltan// /}" ]; then
    info "Instalando:${faltan}"
    ejecutar "DEBIAN_FRONTEND=noninteractive apt-get update -qq"
    ejecutar "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ${faltan}"
  fi

  # Verificacion real posterior a la instalacion. No dar por hecho que apt
  # dejo las herramientas disponibles en el PATH.
  if [ "$DRY_RUN" -eq 0 ]; then
    local h ruta
    for h in wg wg-quick nft; do
      if ! command -v "$h" >/dev/null 2>&1; then
        ruta="$(ls /usr/sbin/$h /sbin/$h /usr/bin/$h 2>/dev/null | head -1 || true)"
        if [ -n "$ruta" ]; then
          die "'${h}' existe en ${ruta} pero no esta en el PATH. Reejecuta con: PATH=/usr/sbin:/sbin:\$PATH ${0} ..."
        fi
        die "Falta '${h}' tras la instalacion. Instalalo a mano y vuelve a ejecutar: apt-get install -y wireguard-tools nftables"
      fi
    done
  fi
  ok "wireguard-tools y nftables presentes y accesibles."
}

respaldar() {
  ejecutar "mkdir -p '${BACKUP_DIR}'"
  ejecutar "chmod 700 '${BACKUP_DIR}'"
  if [ -f "$CONF" ]; then
    info "Respaldando configuracion previa de ${IFACE}"
    ejecutar "cp -a '${CONF}' '${BACKUP_DIR}/${IFACE}.conf.${STAMP}'"
  fi
  if [ -f "$NFT_FILE" ]; then
    ejecutar "cp -a '${NFT_FILE}' '${BACKUP_DIR}/${IFACE}.nft.${STAMP}'"
  fi
  if [ "$DRY_RUN" -eq 0 ]; then
    nft list ruleset > "${BACKUP_DIR}/ruleset-completo.${STAMP}.nft" 2>/dev/null || true
    ip route show > "${BACKUP_DIR}/rutas.${STAMP}.txt" 2>/dev/null || true
  fi
  ok "Respaldos en ${BACKUP_DIR}"
}

generar_claves() {
  titulo "Claves"
  ejecutar "mkdir -p '${WG_DIR}'"
  ejecutar "chmod 700 '${WG_DIR}'"
  local priv="${WG_DIR}/${IFACE}-privada.key"
  local pub="${WG_DIR}/${IFACE}-publica.key"
  local pskf="${WG_DIR}/${IFACE}-psk.key"

  if [ -f "$priv" ]; then
    info "Reutilizando el par de claves existente (no se regenera para no invalidar el peer del hub)."
  else
    info "Generando par de claves nuevo."
    if [ "$DRY_RUN" -eq 0 ]; then
      ( umask 077; wg genkey > "$priv" )
      wg pubkey < "$priv" > "$pub"
      chmod 600 "$priv"; chmod 644 "$pub"
    fi
  fi

  if [ -n "$PSK_VALOR" ]; then
    if [ "$DRY_RUN" -eq 0 ]; then
      ( umask 077; printf '%s\n' "$PSK_VALOR" > "$pskf" )
      chmod 600 "$pskf"
    fi
    info "PSK tomada del parametro --psk."
  elif [ -f "$pskf" ]; then
    info "Reutilizando la PSK existente."
  else
    info "Generando PSK nueva."
    if [ "$DRY_RUN" -eq 0 ]; then
      ( umask 077; wg genpsk > "$pskf" )
      chmod 600 "$pskf"
    fi
  fi

  if [ "$DRY_RUN" -eq 0 ]; then
    MI_PUBKEY="$(cat "$pub")"
    MI_PSK="$(cat "$pskf")"
  else
    MI_PUBKEY="<CLAVE_PUBLICA_GENERADA>"
    MI_PSK="<PSK_GENERADA>"
  fi
  ok "Clave publica de este host: ${MI_PUBKEY}"
}

construir_allowed_ips() {
  # Una entrada por destino real. Sin agregacion, sin supernets.
  # Cada prefijo aqui se convierte en UNA ruta especifica creada por wg-quick.
  local lista="${HUB_OVERLAY}/32" r

  IFS=',' read -r -a _routers2 <<< "${ROUTERS_RECO:-}"
  for r in "${_routers2[@]:-}"; do
    [ -n "$r" ] && lista="${lista}, ${r}/32"
  done

  IFS=',' read -r -a _redes2 <<< "$REDES_RECO"
  for r in "${_redes2[@]}"; do
    lista="${lista}, ${r}"
  done

  # Barrera final: ningun prefijo generico puede llegar al archivo de config.
  IFS=',' read -r -a _todos <<< "$(printf '%s' "$lista" | tr -d ' ')"
  for r in "${_todos[@]}"; do
    validar_especifico "$r" "AllowedIPs"
  done

  ALLOWED_IPS="$lista"
  N_RUTAS="${#_todos[@]}"
}

escribir_conf() {
  titulo "Archivo ${CONF}"
  construir_allowed_ips
  local priv="${WG_DIR}/${IFACE}-privada.key"
  local pskf="${WG_DIR}/${IFACE}-psk.key"

  info "Se instalaran ${N_RUTAS} rutas especificas por ${IFACE}:"
  printf '%s\n' "$ALLOWED_IPS" | tr -d ' ' | tr ',' '\n' | sed 's/^/           /'

  if [ "$DRY_RUN" -eq 1 ]; then
    info "Se escribiria ${CONF} con las rutas de arriba. No se aplico nada."
    return 0
  fi

  # Con --sin-firewall el archivo no lleva PostUp/PostDown: la interfaz sube
  # sin politica local y el filtrado queda a cargo del concentrador.
  local bloque_firewall
  if [ "$SIN_FIREWALL" -eq 1 ]; then
    bloque_firewall="# SIN POLITICA LOCAL (--sin-firewall).
# El filtrado de este tunel se hace en el concentrador RB5009.
# Ver alli: WG-07 (acceso al propio router), WG-30 a WG-36 (aislamiento
# entre sitios) y WG-90 / WG-91 (deny por defecto del overlay)."
  else
    bloque_firewall="# Firewall del tunel: se aplica y se retira junto con la interfaz.
PostUp   = nft -f ${NFT_FILE}
PostDown = nft delete table inet ${NFT_TABLA} 2>/dev/null || true"
  fi

  umask 077
  cat > "$CONF" <<FIN
# ============================================================================
# ${IFACE}.conf - cliente WireGuard hacia el concentrador RB5009
# Rol: ${ROL}
# Generado por instalar-wg-scada.sh el ${STAMP}
#
# Este host NO es un router. AllowedIPs nunca incluye 0.0.0.0/0, por lo que
# el trafico general de Internet sigue saliendo por la interfaz por defecto.
# ============================================================================

[Interface]
# IP de este host dentro de la VPN. Debe coincidir con el allowed-address
# declarado para este peer en el RB5009.
Address    = ${IP_OVERLAY}
PrivateKey = $(cat "$priv")

# 1500 - 60 bytes de encapsulado WireGuard sobre IPv4.
MTU        = ${MTU}

${bloque_firewall}

[Peer]
# Concentrador RB5009. Este host siempre inicia el tunel: no hace falta
# abrir ningun puerto entrante en el firewall del proveedor de nube.
PublicKey    = ${HUB_PUBKEY}
PresharedKey = $(cat "$pskf")
Endpoint     = ${HUB_ENDPOINT}

# Destinos alcanzables por el tunel. SOLO PREFIJOS ESPECIFICOS: wg-quick
# instala exactamente una ruta por cada entrada de esta lista. No hay
# supernets, no hay 0.0.0.0/0, no hay 10.0.0.0/8 ni 172.16.0.0/12.
# Total de rutas instaladas: ${N_RUTAS}
AllowedIPs   = ${ALLOWED_IPS}

# Mantiene viva la sesion NAT del proveedor de nube y del hub.
PersistentKeepalive = ${KEEPALIVE}
FIN
  chmod 600 "$CONF"
  ok "Escrito ${CONF} (modo 0600) con ${N_RUTAS} rutas especificas."
}

lista_nft_set() {
  # lista_nft_set <csv> <sufijo>   -> imprime elementos para un set nftables
  local csv="$1" sufijo="${2:-}" out="" x
  IFS=',' read -r -a _e <<< "$csv"
  for x in "${_e[@]}"; do
    [ -z "$x" ] && continue
    [ -n "$out" ] && out="${out}, "
    out="${out}${x}${sufijo}"
  done
  printf '%s' "$out"
}

escribir_nft() {
  titulo "Firewall nftables"
  local set_reco set_routers set_tcp set_udp
  set_reco="$(lista_nft_set "$REDES_RECO")"
  set_routers="$(lista_nft_set "${ROUTERS_RECO:-}")"
  set_tcp="$(lista_nft_set "${TCP_PORTS:-}")"
  set_udp="$(lista_nft_set "${UDP_PORTS:-}")"

  local hub_ip="${HUB_OVERLAY}"

  if [ "$DRY_RUN" -eq 1 ]; then
    info "Se escribiria ${NFT_FILE} (tabla inet ${NFT_TABLA})"
    [ -z "$set_tcp" ] && info "Sin puertos TCP permitidos (solo ICMP)."
    [ -z "$set_udp" ] && info "Sin puertos UDP permitidos (solo ICMP)."
    return 0
  fi

  mkdir -p "$NFT_DIR"; chmod 700 "$NFT_DIR"

  {
    cat <<FIN
# ============================================================================
# ${NFT_FILE}
# Firewall del tunel WireGuard - tabla independiente inet ${NFT_TABLA}
#
# DISENO NO DESTRUCTIVO:
#   - Tabla propia, no toca filter, ufw, firewalld ni docker.
#   - Prioridad -10: se evalua antes que filter (0) pero despues de conntrack.
#   - El trafico que no pasa por ${IFACE} se acepta de inmediato en esta tabla
#     y sigue su curso normal por el resto del firewall del servidor.
#   - Por eso este archivo NO puede dejarte sin acceso SSH al servidor.
#
# Politica: denegar por defecto todo lo que entra o sale por ${IFACE}.
# ============================================================================

# Idempotencia: declarar la tabla la crea si no existe y no hace nada si ya
# existe; el delete posterior la vacia. Sin estas dos lineas, recargar el
# archivo con la tabla ya cargada falla con "File exists".
table inet ${NFT_TABLA}
delete table inet ${NFT_TABLA}

table inet ${NFT_TABLA} {

    set redes_reco {
        type ipv4_addr
        flags interval
        comment "LANs de los sitios RECO"
FIN
    if [ -n "$set_reco" ]; then
      printf '        elements = { %s }\n' "$set_reco"
    fi
    cat <<FIN
    }

    set routers_reco {
        type ipv4_addr
        flags interval
        comment "IP overlay de los routers remotos - solo para ICMP de supervision"
FIN
    if [ -n "$set_routers" ]; then
      printf '        elements = { %s }\n' "$set_routers"
    fi
    cat <<FIN
    }

    set puertos_tcp {
        type inet_service
        flags interval
        comment "Puertos TCP industriales habilitados de forma explicita"
FIN
    if [ -n "$set_tcp" ]; then
      printf '        elements = { %s }\n' "$set_tcp"
    fi
    cat <<FIN
    }

    set puertos_udp {
        type inet_service
        flags interval
        comment "Puertos UDP industriales habilitados de forma explicita"
FIN
    if [ -n "$set_udp" ]; then
      printf '        elements = { %s }\n' "$set_udp"
    fi
    cat <<FIN
    }

    # ------------------------------------------------------------------
    # ENTRADA: que se acepta desde el tunel
    # ------------------------------------------------------------------
    chain entrada {
        type filter hook input priority -10; policy accept;

        # Todo lo que no llega por el tunel no es asunto de esta tabla.
        iifname != "${IFACE}" accept

        ct state invalid counter drop comment "descartar invalidos del tunel"

        # Respuestas a sesiones que origino este servidor.
        ct state established,related counter accept comment "retorno SCADA"

        # Diagnostico: permitir que el hub y los routers hagan ping a este host.
        # Direccion exacta del concentrador, no un rango de infraestructura.
        icmp type echo-request ip saddr ${hub_ip} counter accept comment "ping desde el concentrador"
        icmp type echo-request ip saddr @routers_reco counter accept comment "ping desde routers RECO"

        # Nada mas entra por el tunel. Los RECO no inician sesiones hacia aqui.
        counter drop comment "DENY por defecto - entrada por tunel"
    }

    # ------------------------------------------------------------------
    # SALIDA: que puede originar este servidor hacia el tunel
    # ------------------------------------------------------------------
    chain salida {
        type filter hook output priority -10; policy accept;

        # El trafico UDP cifrado hacia el hub sale por la interfaz WAN,
        # no por ${IFACE}, asi que no se ve afectado por esta cadena.
        oifname != "${IFACE}" accept

        ct state invalid counter drop
        ct state established,related counter accept

        # Supervision.
        icmp type echo-request ip daddr ${hub_ip} counter accept comment "ping al concentrador"
        icmp type echo-request ip daddr @routers_reco counter accept comment "ping a routers RECO"
        icmp type echo-request ip daddr @redes_reco  counter accept comment "ping a dispositivos RECO"

        # Protocolos industriales. Si los sets estan vacios estas reglas
        # nunca hacen match y no se permite ningun puerto.
        ip daddr @redes_reco tcp dport @puertos_tcp ct state new counter accept comment "SCADA hacia RECO - TCP habilitado"
        ip daddr @redes_reco udp dport @puertos_udp ct state new counter accept comment "SCADA hacia RECO - UDP habilitado"

        # Bloqueo explicito y auditable de la administracion del concentrador.
        ip daddr ${hub_ip} tcp dport { 22, 8291, 80, 443, 8728, 8729 } counter drop comment "este servidor no administra el RB5009"

        counter drop comment "DENY por defecto - salida por tunel"
    }

    # ------------------------------------------------------------------
    # REENVIO: este host no es un router bajo ninguna circunstancia
    # ------------------------------------------------------------------
    chain reenvio {
        type filter hook forward priority -10; policy accept;
        iifname "${IFACE}" counter drop comment "sin reenvio desde el tunel"
        oifname "${IFACE}" counter drop comment "sin reenvio hacia el tunel"
    }
}
FIN
  } > "$NFT_FILE"

  chmod 600 "$NFT_FILE"

  if ! nft -c -f "$NFT_FILE"; then
    die "El archivo nftables generado no es valido. Revisa ${NFT_FILE}. No se aplico ningun cambio."
  fi
  ok "Escrito y validado ${NFT_FILE}"
  if [ -z "$set_tcp" ] && [ -z "$set_udp" ]; then
    warn "Ningun puerto industrial habilitado. Solo ICMP. Usa --tcp / --udp cuando la empresa confirme los protocolos."
  fi
}

habilitar_servicio() {
  titulo "systemd"
  ejecutar "systemctl daemon-reload"
  ejecutar "systemctl enable wg-quick@${IFACE}.service"
  if systemctl is-active --quiet "wg-quick@${IFACE}.service"; then
    info "Reiniciando el tunel para aplicar la configuracion nueva."
    ejecutar "systemctl restart wg-quick@${IFACE}.service"
  else
    ejecutar "systemctl start wg-quick@${IFACE}.service"
  fi
  ok "wg-quick@${IFACE} habilitado al arranque y en ejecucion."
}

imprimir_peer_routeros() {
  local comentario
  if [ "$ROL" = "admin" ]; then
    comentario="CLIENTE-ADMIN-DEBIAN - estacion de gestion"
  else
    comentario="SCADA-DEBIAN - colector en nube - inicia el tunel"
  fi
  local ip_sola="${IP_OVERLAY%%/*}"

  # Salida minima: dos lineas CLAVE=VALOR y nada mas. Sin titulo ni aviso,
  # para que se puedan copiar de una sola pasada y pegarse tal cual.
  if [ "$BREVE" -eq 1 ]; then
    printf '\nPUBLIC-KEY=%s\nPRESHARED-KEY=%s\n' "${MI_PUBKEY}" "${MI_PSK}"
    return 0
  fi

  titulo "Pegar en el RB5009 (RouterOS v7)"
  cat <<FIN

Copia este bloque completo en la terminal del RB5009. Activa Safe Mode antes
de ejecutarlo pulsando Ctrl+X, y vuelve a pulsar Ctrl+X para confirmar.

--------------------------------------------------------------------------
/interface/wireguard/peers/add \\
    interface=wg-hub \\
    public-key="${MI_PUBKEY}" \\
    preshared-key="${MI_PSK}" \\
    allowed-address=${ip_sola}/32 \\
    comment="${comentario}"
--------------------------------------------------------------------------

FIN
  if [ "$ROL" = "scada" ]; then
    cat <<FIN
Y si es la primera vez que se da de alta este servidor, anade su IP a la
lista de direcciones del firewall central:

--------------------------------------------------------------------------
/ip/firewall/address-list/add list=WG-SCADA address=${ip_sola} \\
    comment="Servidor SCADA Debian - overlay"
--------------------------------------------------------------------------

FIN
  fi
  warn "La PSK mostrada arriba es secreta. Guardala en el gestor de secretos y limpia el historial de la terminal."
}

# ----------------------------------------------------------------------------
# Verificacion
# ----------------------------------------------------------------------------
verificar() {
  local fallos=0

  titulo "1. Servicio systemd"
  if systemctl is-enabled --quiet "wg-quick@${IFACE}.service" 2>/dev/null; then
    ok "wg-quick@${IFACE} habilitado al arranque."
  else
    warn "wg-quick@${IFACE} NO esta habilitado al arranque."; fallos=$((fallos+1))
  fi
  if systemctl is-active --quiet "wg-quick@${IFACE}.service" 2>/dev/null; then
    ok "wg-quick@${IFACE} activo."
  else
    warn "wg-quick@${IFACE} NO esta activo."; fallos=$((fallos+1))
    systemctl status "wg-quick@${IFACE}.service" --no-pager -l | sed 's/^/         /' || true
  fi

  titulo "2. Interfaz y handshake"
  if ! ip link show "$IFACE" >/dev/null 2>&1; then
    warn "La interfaz ${IFACE} no existe."; fallos=$((fallos+1))
  else
    ip -brief address show "$IFACE" | sed 's/^/         /'
    printf '         MTU: %s\n' "$(cat "/sys/class/net/${IFACE}/mtu" 2>/dev/null || echo '?')"
    wg show "$IFACE" | sed 's/^/         /'
    local lh
    lh="$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)"
    if [ -n "${lh:-}" ] && [ "$lh" != "0" ]; then
      local edad=$(( $(date +%s) - lh ))
      if [ "$edad" -lt 180 ]; then
        ok "Ultimo handshake hace ${edad}s. Tunel sano."
      else
        warn "Ultimo handshake hace ${edad}s. El tunel puede estar caido."; fallos=$((fallos+1))
      fi
    else
      warn "Sin handshake. El peer no esta dado de alta en el RB5009, o hay bloqueo UDP, o la clave/PSK no coinciden."
      fallos=$((fallos+1))
    fi
  fi

  titulo "3. Rutas instaladas"
  ip route show dev "$IFACE" 2>/dev/null | sed 's/^/         /' || warn "Sin rutas por ${IFACE}."
  if ip route show default | grep -q "dev ${IFACE}"; then
    warn "HAY UNA RUTA POR DEFECTO POR EL TUNEL. Esto no debe ocurrir en este diseno."
    fallos=$((fallos+1))
  else
    ok "La ruta por defecto NO pasa por el tunel."
  fi

  # Auditoria de especificidad: ninguna ruta del tunel puede ser generica.
  local dst masc genericas=0
  while read -r dst _; do
    [ -z "$dst" ] && continue
    case "$dst" in default|broadcast|local|unreachable) continue ;; esac
    case "$dst" in
      */*) masc="${dst##*/}" ;;
      *)   masc=32 ;;                # ip route omite /32 en rutas de host
    esac
    printf '%s' "$masc" | grep -Eq '^[0-9]+$' || continue
    if [ "$masc" -lt "$MASCARA_MINIMA" ]; then
      warn "RUTA GENERICA DETECTADA por ${IFACE}: ${dst} (/${masc})"
      genericas=$((genericas+1))
    fi
  done < <(ip route show dev "$IFACE" 2>/dev/null)

  if [ "$genericas" -eq 0 ]; then
    ok "Todas las rutas del tunel son especificas (ninguna mas amplia que /${MASCARA_MINIMA})."
  else
    warn "${genericas} ruta(s) generica(s) por el tunel. Revisa AllowedIPs en ${CONF}."
    fallos=$((fallos+1))
  fi

  titulo "4. Firewall del tunel"
  if nft list table inet "${NFT_TABLA}" >/dev/null 2>&1; then
    ok "Tabla inet ${NFT_TABLA} cargada."
    nft list table inet "${NFT_TABLA}" | grep -E 'counter packets' | sed 's/^/         /' | head -25
  else
    warn "La tabla inet ${NFT_TABLA} NO esta cargada. Reaplicar: systemctl restart wg-quick@${IFACE}"
    fallos=$((fallos+1))
  fi

  titulo "5. Reenvio IP"
  comprobar_forwarding

  titulo "6. Alcance de los sitios"
  local r
  IFS=',' read -r -a _rt <<< "${ROUTERS_RECO:-}"
  for r in "${_rt[@]:-}"; do
    [ -z "$r" ] && continue
    if ping -c 2 -W 2 -n "$r" >/dev/null 2>&1; then
      ok "Router ${r} responde."
    else
      warn "Router ${r} NO responde."
    fi
  done
  # Los dispositivos se prueban por su IP concreta. Hacer ping al prefijo de
  # --redes-reco no sirve: con un /24 la primera direccion es la de red y no
  # responde nunca, lo que produce un falso negativo en cada verificacion.
  local objetivos="$DISPOSITIVOS_RECO"
  if [ -z "$objetivos" ]; then
    IFS=',' read -r -a _rd <<< "${REDES_RECO:-}"
    for r in "${_rd[@]:-}"; do
      [ -z "$r" ] && continue
      if [ "${r##*/}" = "32" ]; then
        objetivos="${objetivos}${objetivos:+,}${r%%/*}"
      else
        warn "Sin --dispositivos y ${r} no es /32: no hay una IP fiable que probar en esa LAN."
      fi
    done
  fi
  IFS=',' read -r -a _dp <<< "${objetivos:-}"
  for r in "${_dp[@]:-}"; do
    [ -z "$r" ] && continue
    if ping -c 2 -W 3 -n "$r" >/dev/null 2>&1; then
      ok "Dispositivo RECO ${r} responde."
    else
      warn "Dispositivo RECO ${r} NO responde."
    fi
  done

  titulo "Resultado"
  if [ "$fallos" -eq 0 ]; then
    ok "Verificacion sin fallos criticos."
  else
    warn "${fallos} comprobacion(es) con problemas. Revisa el detalle arriba."
    return 1
  fi
}

# ----------------------------------------------------------------------------
# Desinstalacion
# ----------------------------------------------------------------------------
desinstalar() {
  titulo "Desinstalacion del cliente ${IFACE}"
  warn "Se detendra el tunel ${IFACE}. Se perdera la conectividad con los sitios RECO."
  if [ "$ASUMIR_SI" -eq 0 ]; then
    read -r -p "  Confirmar? (s/N): " _c
    case "$_c" in s|S|si|SI) : ;; *) die "Cancelado." ;; esac
  fi
  respaldar
  ejecutar "systemctl stop wg-quick@${IFACE}.service 2>/dev/null || true"
  ejecutar "systemctl disable wg-quick@${IFACE}.service 2>/dev/null || true"

  # El 'systemctl stop' de arriba lleva '|| true' para no abortar cuando el
  # servicio ni siquiera existe, pero eso tambien tapa un fallo real: wg-quick
  # down lee el .conf para saber que desarmar, y si alguien lo borro a mano
  # antes de desinstalar, la baja no ocurre y la interfaz queda arriba pasando
  # trafico. Se comprueba y se elimina directamente, que no depende del .conf.
  if [ "$DRY_RUN" -eq 0 ] && ip link show "${IFACE}" >/dev/null 2>&1; then
    warn "La interfaz ${IFACE} sigue arriba despues de detener el servicio."
    warn "Suele pasar si el .conf fue borrado a mano: wg-quick down no pudo leerlo."
    ejecutar "ip link del '${IFACE}'"
  fi

  ejecutar "nft delete table inet ${NFT_TABLA} 2>/dev/null || true"
  ejecutar "rm -f '${NFT_FILE}'"
  ejecutar "mv '${CONF}' '${BACKUP_DIR}/${IFACE}.conf.desinstalado.${STAMP}' 2>/dev/null || true"

  # Sin esta comprobacion el script podria informar exito con el tunel vivo.
  if [ "$DRY_RUN" -eq 0 ] && ip link show "${IFACE}" >/dev/null 2>&1; then
    die "La interfaz ${IFACE} sigue existiendo. Eliminala a mano: ip link del ${IFACE}"
  fi

  ok "Cliente desinstalado. Las claves siguen en ${WG_DIR} por si hay que reinstalar."
  info "Para borrar tambien las claves: rm -f ${WG_DIR}/${IFACE}-*.key"
  echo
  info "Recuerda revocar el peer en el RB5009:"
  cat <<FIN
--------------------------------------------------------------------------
/interface/wireguard/peers/remove [find comment~"SCADA-DEBIAN"]
--------------------------------------------------------------------------
FIN
}

# ----------------------------------------------------------------------------
# Flujo principal
# ----------------------------------------------------------------------------
main() {
  info_version
  case "$ACCION" in
    verificar)
      requiere_root
      verificar
      ;;
    desinstalar)
      requiere_root
      desinstalar
      ;;
    instalar)
      requiere_root
      comprobar_sistema
      if [ -z "$IP_OVERLAY" ] || [ -z "$HUB_PUBKEY" ] || [ -z "$HUB_ENDPOINT" ]; then
        modo_interactivo
      fi
      validar_parametros
      instalar_paquetes
      detectar_conflictos
      comprobar_forwarding
      respaldar
      generar_claves
      escribir_conf
      if [ "$SIN_FIREWALL" -eq 1 ]; then
        titulo "Firewall nftables"
        warn "OMITIDO por --sin-firewall. Este host no aplica ninguna politica al tunel."
        warn "El filtrado tiene que estar hecho en el concentrador RB5009."
        # Si una instalacion previa dejo la tabla cargada, sigue activa hasta
        # el proximo reinicio aunque el .conf ya no la mencione. Se retira.
        if [ "$DRY_RUN" -eq 0 ] && nft list table inet "${NFT_TABLA}" >/dev/null 2>&1; then
          info "Retirando la tabla inet ${NFT_TABLA} de una instalacion anterior."
          nft delete table inet "${NFT_TABLA}" 2>/dev/null || true
          rm -f "$NFT_FILE"
        fi
        warn "Sin la cadena 'reenvio' este host podria reenviar hacia el tunel si"
        warn "alguien habilita ip_forward. Verificar: sysctl net.ipv4.ip_forward"
      else
        escribir_nft
      fi
      if [ "$DRY_RUN" -eq 1 ]; then
        titulo "Dry-run terminado"
        info "No se aplico ningun cambio. Vuelve a ejecutar sin --dry-run."
        exit 0
      fi
      habilitar_servicio
      imprimir_peer_routeros
      [ "$BREVE" -eq 1 ] && exit 0
      titulo "Siguiente paso"
      cat <<FIN
  1. Da de alta el peer en el RB5009 con el bloque de arriba.
  2. Vuelve aqui y ejecuta:  sudo ${0} --verificar \\
         --routers-reco '${ROUTERS_RECO:-}' --dispositivos '${DISPOSITIVOS_RECO:-}'
  3. Cuando la empresa confirme los protocolos, habilitalos en AMBOS extremos:
       aqui : sudo ${0} --tcp 2404 ... (reejecutar el instalador)
       hub  : /ip/firewall/filter/enable [find comment~"WG-50"]
FIN
      ;;
  esac
}

main
