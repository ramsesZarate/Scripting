#!/bin/sh
# descLinux-v9.sh — Detecta productos IBM instalados en un host Unix/Linux.
# Deriva de v8. Mejoras en v9:
#   - Informix Connect / Client SDK: esql, esqlc, ifxbld, dbaccessdemo
#   - Informix High-Performance Loader: ifxloload, ifxulload
#   - Informix JDBC Driver: ifxjdbc.jar (con validación estricta de ruta)
#   - Informix Client SDK / Connect / JDBC:
#       * prioriza clientversion cuando exista dentro del mismo INFORMIXDIR
#       * intenta ifx_getversion como segundo mecanismo
#       * revisa $INFORMIXDIR/etc/*cr para recuperar versión de Client SDK / ESQL
#       * si el árbol comparte engine + cliente, reporta Client SDK como versión
#         asociada/inferida al INFORMIXDIR cuando no haya evidencia más específica
#   - Nombre de archivo de salida:
#       descLinux_v9_<SERVIDOR>_<YYYYMMDD>.txt
#   - Hardenings:
#       * oninit -V se ejecuta con INFORMIXDIR/PATH del mismo árbol
#       * se endurece el filtro de WAS para evitar falsos positivos con Oracle
#       * se endurece el filtro de TWS para evitar falsos positivos de conman
#       * find global con timeout configurable FIND_TIMEOUT_S

set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
LC_ALL=C
export LC_ALL

PROG=${0##*/}
OUTPUT_FILE=""
SEPARADOR='************************************************************'
FIND_TIMEOUT_S=${FIND_TIMEOUT_S:-120}

CATALOGO='
oninit|IBM Informix Enterprise Edition
dmts64|IBM InfoSphere Data Replication
wsadmin.sh|IBM WebSphere Application Server
mqsilist|IBM App Connect Enterprise / IBM Integration Bus
dspmq|IBM MQ
control.sh|IBM Sterling B2B / File Gateway
startSecureProxy.sh|IBM Sterling Secure Proxy - Inbound
BPMConfig.sh|IBM Business Process Manager / IBM Business Automation Workflow
DecisionCenter.ear|IBM Operational Decision Manager
dbaccess|IBM Informix Client SDK
esql|IBM Informix Connect / Client SDK
esqlc|IBM Informix Connect / Client SDK
ifxbld|IBM Informix Connect / Client SDK
dbaccessdemo|IBM Informix Connect
ifxloload|IBM Informix High-Performance Loader
ifxulload|IBM Informix High-Performance Loader
ifxjdbc.jar|IBM Informix JDBC Driver
c4gl|IBM Informix 4GL Compiler Development
r4gl|IBM Informix 4GL Compiler Runtime Option
fglgo|IBM Informix 4GL RDS Development
cdr|IBM Informix Enterprise Replication
ism_startup|IBM Informix Storage Manager
db2level|IBM Db2
imcl|IBM Installation Manager
dsmc|IBM Spectrum Protect
cogconfig.sh|IBM Cognos
collation.sh|IBM TADDM
startPortalServer.sh|WebSphere Portal
idsldapsearch|IBM Security Directory Server
dsrpcd|IBM InfoSphere DataStage / DataStage
BESClient|IBM Tivoli Endpoint Manager / BigFix
conman|IBM Tivoli Workload Scheduler
udclient|IBM UrbanCode Deploy
wesbinstall|IBM WebSphere Enterprise Service Bus
tm1sd|IBM Cognos TM1 / Planning Analytics
tm1s|IBM Cognos TM1 / Planning Analytics
isql|IBM Informix SQL Development
'

RUTAS_EXCLUIDAS='/proc /sys /dev /run /var/run /snap /mnt /media /cdrom /tmp/.mount_*'

SERVIDOR_NOMBRE=desconocido
SERVIDOR_IPS=desconocido
SERVIDOR_SO=desconocido
SERVIDOR_CPUS=desconocido

OUTPUT_DEST=/dev/stdout

uso() {
    cat <<EOF
$PROG — detecta productos IBM instalados recorriendo el filesystem.

Uso:
  $PROG
EOF
}

salida() {
    printf '%s\n' "$1" >> "$OUTPUT_DEST"
}

obtener_nombre_servidor() {
    host=$(hostname 2>/dev/null || true)
    [ -n "$host" ] || host=$(uname -n 2>/dev/null || true)
    printf '%s' "${host:-desconocido}"
}

obtener_ips() {
    ips=""

    if command -v hostname >/dev/null 2>&1; then
        ips=$(hostname -I 2>/dev/null | awk '{$1=$1; print}')
        [ -n "$ips" ] && {
            printf '%s' "$ips"
            return
        }
    fi

    if command -v ip >/dev/null 2>&1; then
        ips=$(ip -o -4 addr show scope global 2>/dev/null | awk '
            BEGIN { first=1 }
            {
                split($4, a, "/")
                if (!first) {
                    printf ", "
                }
                printf "%s", a[1]
                first=0
            }
            END {
                if (NR > 0) {
                    printf "\n"
                }
            }
        ')
        [ -n "$ips" ] && {
            printf '%s' "$ips"
            return
        }
    fi

    if command -v ifconfig >/dev/null 2>&1; then
        ips=$(ifconfig 2>/dev/null | awk '
            BEGIN { first=1 }
            /inet / {
                ip=$2
                sub(/^addr:/, "", ip)
                if (ip == "127.0.0.1" || ip == "0.0.0.0") {
                    next
                }
                if (!first) {
                    printf ", "
                }
                printf "%s", ip
                first=0
            }
            END {
                if (!first) {
                    printf "\n"
                }
            }
        ')
        [ -n "$ips" ] && {
            printf '%s' "$ips"
            return
        }
    fi

    printf '%s' "desconocido"
}

obtener_so() {
    so=""

    if [ -r /etc/os-release ]; then
        so=$(awk -F= '
            $1=="PRETTY_NAME" {
                gsub(/^"/, "", $2)
                gsub(/"$/, "", $2)
                print $2
                exit
            }
            $1=="NAME" {
                name=$2
                gsub(/^"/, "", name)
                gsub(/"$/, "", name)
            }
            $1=="VERSION" {
                version=$2
                gsub(/^"/, "", version)
                gsub(/"$/, "", version)
            }
            END {
                if (name != "") {
                    if (version != "") {
                        print name " " version
                    } else {
                        print name
                    }
                }
            }
        ' /etc/os-release)
        [ -n "$so" ] && {
            printf '%s' "$so"
            return
        }
    fi

    for f in /etc/redhat-release /etc/oracle-release /etc/centos-release /etc/SuSE-release /etc/issue; do
        [ -r "$f" ] || continue
        so=$(head -n 1 "$f" 2>/dev/null)
        [ -n "$so" ] && {
            printf '%s' "$so"
            return
        }
    done

    so_nombre=$(uname -s 2>/dev/null || echo desconocido)
    so_rel=$(uname -r 2>/dev/null || true)
    printf '%s %s' "$so_nombre" "$so_rel"
}

obtener_cpus() {
    cpus=""

    if command -v getconf >/dev/null 2>&1; then
        cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)
        [ -n "$cpus" ] && {
            printf '%s' "$cpus"
            return
        }
    fi

    if command -v nproc >/dev/null 2>&1; then
        cpus=$(nproc 2>/dev/null || true)
        [ -n "$cpus" ] && {
            printf '%s' "$cpus"
            return
        }
    fi

    if [ -r /proc/cpuinfo ]; then
        cpus=$(awk '/^processor[[:space:]]*:/ {count++} END {if (count > 0) print count}' /proc/cpuinfo)
        [ -n "$cpus" ] && {
            printf '%s' "$cpus"
            return
        }
    fi

    printf '%s' "desconocido"
}

recolectar_info_servidor() {
    SERVIDOR_NOMBRE=$(obtener_nombre_servidor)
    SERVIDOR_IPS=$(obtener_ips)
    SERVIDOR_SO=$(obtener_so)
    SERVIDOR_CPUS=$(obtener_cpus)
}

etiqueta_base_para() {
    target=$1
    while IFS='|' read -r sig label; do
        [ -z "$sig" ] && continue
        [ "$sig" = "$target" ] && {
            printf '%s' "$label"
            return
        }
    done <<EOF
$CATALOGO
EOF
}

ejecutar_seguro() {
    # Ejecuta un comando con límite de tiempo.
    # Estrategia:
    #   1) Si existe el comando 'timeout' (coreutils 7+): úsalo directamente.
    #   2) Si no existe (SUSE 9, OL 5.x, etc.): ejecutar en background,
    #      esperar t segundos y matar si sigue corriendo.
    #      Limitación conocida: en sh POSIX puro, $! del pipeline no es
    #      portable; se usa subshell para capturar el PID del proceso real.
    t=$1
    shift

    if command -v timeout >/dev/null 2>&1; then
        timeout "${t}s" "$@" 2>&1 | head -n 60
        return
    fi

    # Fallback: background + sleep + kill
    _tmpout=${TMPDIR:-/tmp}/ejecutar_seguro.$$.out
    "$@" > "$_tmpout" 2>&1 &
    _pid=$!
    _elapsed=0
    while [ "$_elapsed" -lt "$t" ]; do
        sleep 1
        _elapsed=$(( _elapsed + 1 ))
        kill -0 "$_pid" 2>/dev/null || break
    done
    if kill -0 "$_pid" 2>/dev/null; then
        kill -TERM "$_pid" 2>/dev/null
        sleep 2
        kill -0 "$_pid" 2>/dev/null && kill -KILL "$_pid" 2>/dev/null
    fi
    wait "$_pid" 2>/dev/null
    head -n 60 "$_tmpout"
    rm -f "$_tmpout"
}

propietario_de_ruta() {
    ls -ld "$1" 2>/dev/null | awk 'NR==1 {print $3}'
}

extraer_version_informix() {
    awk '
        /IBM Informix Dynamic Server Version/ {
            sub(/^.*Version /, "", $0)
            gsub(/^[[:space:]]+/, "", $0)
            gsub(/[[:space:]]+Copyright.*$/, "", $0)
            gsub(/[[:space:]]+as part of.*$/, "", $0)
            print
            exit
        }
        /Version/ && !/No such file|no such directory|errno|locale|Unable/ {
            sub(/^.*Version[[:space:]]+/, "", $0)
            gsub(/^[[:space:]]+/, "", $0)
            gsub(/[[:space:]]+Copyright.*$/, "", $0)
            print
            exit
        }
    '
}

extraer_version_db2() {
    awk '
        /Informational tokens/ && match($0, /DB2 v[0-9.]+/) {
            v=substr($0, RSTART + 5, RLENGTH - 5)
            print v
            exit
        }
        match($0, /DB2 v[0-9.]+/) {
            v=substr($0, RSTART + 5, RLENGTH - 5)
            print v
            exit
        }
    '
}

extraer_version_iidr() {
    awk -F': ' '
        /^Version:/ {
            gsub(/^[[:space:]]+/, "", $2)
            gsub(/[[:space:]]+$/, "", $2)
            print $2
            exit
        }
    '
}

extraer_build_iidr() {
    awk -F': ' '
        /^Build:/ {
            gsub(/^[[:space:]]+/, "", $2)
            gsub(/[[:space:]]+$/, "", $2)
            print $2
            exit
        }
    '
}

extraer_version_mq() {
    awk -F': ' '
        /^Version:/ {
            gsub(/^[[:space:]]+/, "", $2)
            gsub(/[[:space:]]+$/, "", $2)
            print $2
            exit
        }
        /^[[:space:]]*Name:/ { next }
        /^[[:space:]]*BuildType:/ { next }
        /^[[:space:]]*Level:/ { next }
        match($0, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/) {
            print substr($0, RSTART, RLENGTH)
            exit
        }
    '
}

extraer_version_was() {
    awk '
        /WebSphere Application Server Network Deployment/ && /[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?/ && !/Java|SDK|JVM|Technology for Java/ {
            match($0, /[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?/)
            print substr($0, RSTART, RLENGTH)
            exit
        }
        /Network Deployment/ && /[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?/ && !/Java|SDK|JVM/ {
            match($0, /[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?/)
            print substr($0, RSTART, RLENGTH)
            exit
        }
        /WebSphere/ && /[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?/ && !/Java|SDK|JVM|Technology for Java/ {
            match($0, /[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?/)
            print substr($0, RSTART, RLENGTH)
            exit
        }
        /Product Version/ && /[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?/ && !/Java|SDK|JVM/ {
            match($0, /[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?/)
            print substr($0, RSTART, RLENGTH)
            exit
        }
    '
}

extraer_version_ace_iib() {
    awk '
        /(App Connect Enterprise|Integration Bus|Broker version|Version)/ && /[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?/ {
            if ($0 ~ /Java|SDK|JVM/) {
                next
            }
            match($0, /[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?/)
            print substr($0, RSTART, RLENGTH)
            exit
        }
    '
}

extraer_version_bpm() {
    awk '
        /(Business Automation Workflow|Business Process Manager|BPM|Version)/ && /[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?/ {
            if ($0 ~ /Java|SDK|JVM/) {
                next
            }
            match($0, /[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?/)
            print substr($0, RSTART, RLENGTH)
            exit
        }
    '
}

extraer_version_ifx_getversion_clientsdk() {
    awk '
        /Client SDK Version[[:space:]]+[0-9]/ {
            sub(/^.*Client SDK Version[[:space:]]+/, "", $0)
            gsub(/^[[:space:]]+/, "", $0)
            print
            exit
        }
        /Version[[:space:]]+[0-9]/ {
            sub(/^.*Version[[:space:]]+/, "", $0)
            gsub(/^[[:space:]]+/, "", $0)
            print
            exit
        }
    '
}

extraer_version_clientversion_clientsdk() {
    awk '
        /Client SDK Version/ {
            sub(/^.*Client SDK Version[[:space:]]+/, "", $0)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            print
            exit
        }
        /Informix Connect Version/ {
            sub(/^.*Informix Connect Version[[:space:]]+/, "", $0)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            print
            exit
        }
        /Version/ && !/No such file|no such directory|errno|locale|Unable/ {
            sub(/^.*Version[[:space:]]+/, "", $0)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            print
            exit
        }
    '
}

extraer_version_ifx_getversion_esql() {
    awk '
        /EMBEDDED SQL for C Version[[:space:]]+[0-9]/ {
            sub(/^.*EMBEDDED SQL for C Version[[:space:]]+/, "", $0)
            gsub(/^[[:space:]]+/, "", $0)
            print
            exit
        }
        /Client SDK Version[[:space:]]+[0-9]/ {
            sub(/^.*Client SDK Version[[:space:]]+/, "", $0)
            gsub(/^[[:space:]]+/, "", $0)
            print
            exit
        }
        /Version[[:space:]]+[0-9]/ {
            sub(/^.*Version[[:space:]]+/, "", $0)
            gsub(/^[[:space:]]+/, "", $0)
            print
            exit
        }
    '
}

extraer_version_ifx_cr_clientsdk() {
    awk '
        /Client SDK Version[[:space:]]+[0-9]/ {
            sub(/^.*Client SDK Version[[:space:]]+/, "", $0)
            gsub(/^[[:space:]]+/, "", $0)
            print
            exit
        }
    '
}

extraer_version_ifx_cr_esql() {
    awk '
        /EMBEDDED SQL for C Version[[:space:]]+[0-9]/ {
            sub(/^.*EMBEDDED SQL for C Version[[:space:]]+/, "", $0)
            gsub(/^[[:space:]]+/, "", $0)
            print
            exit
        }
        /Client SDK Version[[:space:]]+[0-9]/ {
            sub(/^.*Client SDK Version[[:space:]]+/, "", $0)
            gsub(/^[[:space:]]+/, "", $0)
            print
            exit
        }
    '
}

informix_base_dir_para() {
    _ib_path=$1
    case "$_ib_path" in
        */bin/*)
            printf '%s\n' "${_ib_path%/bin/*}"
            ;;
        */lib/esql/*)
            printf '%s\n' "${_ib_path%/lib/esql/*}"
            ;;
        */jdbc/lib/*)
            printf '%s\n' "${_ib_path%/jdbc/lib/*}"
            ;;
        */etc/*)
            printf '%s\n' "${_ib_path%/etc/*}"
            ;;
        *)
            printf '%s\n' "${_ib_path%/*}"
            ;;
    esac
}

informix_compartido_con_engine() {
    _ibase=$1
    [ -n "$_ibase" ] && [ -x "$_ibase/bin/oninit" ]
}

ejecutar_ifx_getversion() {
    _ifg_base=$1
    _ifg_obj=$2
    ejecutar_seguro 5 sh -c '
        INFORMIXDIR=$1
        PATH=$1/bin:$PATH
        export INFORMIXDIR PATH
        if [ -x "$1/bin/ifx_getversion" ]; then
            "$1/bin/ifx_getversion" "$2"
        elif command -v ifx_getversion >/dev/null 2>&1; then
            ifx_getversion "$2"
        else
            exit 127
        fi
    ' sh "$_ifg_base" "$_ifg_obj"
}

ejecutar_clientversion() {
    _cv_base=$1
    ejecutar_seguro 5 sh -c '
        INFORMIXDIR=$1
        PATH=$1/bin:$PATH
        export INFORMIXDIR PATH
        if [ -x "$1/bin/clientversion" ]; then
            "$1/bin/clientversion"
        elif command -v clientversion >/dev/null 2>&1; then
            clientversion
        else
            exit 127
        fi
    ' sh "$_cv_base"
}

ejecutar_oninit_version() {
    _oi_base=$1
    ejecutar_seguro 5 sh -c '
        INFORMIXDIR=$1
        PATH=$1/bin:$PATH
        export INFORMIXDIR PATH
        if [ -x "$1/bin/oninit" ]; then
            "$1/bin/oninit" -V
        else
            exit 127
        fi
    ' sh "$_oi_base"
}

leer_cr_informix() {
    _cr_base=$1
    [ -d "$_cr_base/etc" ] || return 1
    cat "$_cr_base"/etc/*cr 2>/dev/null
}

version_desde_ruta() {
    sig=$1
    path=$2
    case "$sig" in
        dsrpcd)
            printf '%s\n' "$path" | awk '
                match($0, /(InformationServer|DataStage)[^\/]*[[:digit:]]+\.[[:digit:]]+(\.[[:digit:]]+(\.[[:digit:]]+)?)?/) {
                    s=substr($0, RSTART, RLENGTH)
                    if (match(s, /[0-9]+\.[0-9]+(\.[0-9]+(\.[0-9]+)?)?/)) {
                        print substr(s, RSTART, RLENGTH)
                        exit
                    }
                }
                match($0, /\/v[0-9]+\.[0-9]+(\.[0-9]+(\.[0-9]+)?)?\//) {
                    v=substr($0, RSTART + 2, RLENGTH - 3)
                    print v
                    exit
                }
            '
            ;;
        db2level)
            printf '%s\n' "$path" | awk '
                match($0, /\/V[0-9.]+\//) {
                    v=substr($0, RSTART + 2, RLENGTH - 3)
                    print v
                    exit
                }
            '
            ;;
        cdr|ism_startup|oninit|dbaccess)
            printf '%s\n' "$path" | awk '
                match($0, /informix_[0-9][0-9.]*\.[A-Z0-9]+/) {
                    v=substr($0, RSTART + 9, RLENGTH - 9)
                    print v
                    exit
                }
            '
            ;;
        mqsilist)
            printf '%s\n' "$path" | awk '
                match($0, /(ace|ACE)[-_]?[0-9]+/) {
                    print substr($0, RSTART, RLENGTH)
                    exit
                }
                match($0, /(iib|IIB)[-_]?[0-9]+/) {
                    print substr($0, RSTART, RLENGTH)
                    exit
                }
            '
            ;;
        BPMConfig.sh)
            printf '%s\n' "$path" | awk '
                match($0, /(BAW|baw)[-_]?[0-9]+(\.[0-9]+)*/) {
                    print substr($0, RSTART, RLENGTH)
                    exit
                }
                match($0, /(BPM|bpm)[-_]?[0-9]+(\.[0-9]+)*/) {
                    print substr($0, RSTART, RLENGTH)
                    exit
                }
            '
            ;;
        conman)
            # TWS instala típicamente en rutas como /opt/IBM/TWS/v<ver>/
            printf '%s\n' "$path" | awk '
                match($0, /(TWS|tws|WorkloadScheduler)[^/]*[0-9]+\.[0-9]+(\.[0-9]+(\.[0-9]+)?)?/) {
                    s=substr($0, RSTART, RLENGTH)
                    if (match(s, /[0-9]+\.[0-9]+(\.[0-9]+(\.[0-9]+)?)?/)) {
                        print substr(s, RSTART, RLENGTH)
                        exit
                    }
                }
                match($0, /\/v[0-9]+\.[0-9]+(\.[0-9]+(\.[0-9]+)?)?\//) {
                    v=substr($0, RSTART + 2, RLENGTH - 3)
                    print v
                    exit
                }
            '
            ;;
        tm1sd|tm1s)
            # TM1 instala típicamente en /opt/IBM/cognos/tm1/ o /opt/ibm/tm1/
            printf '%s\n' "$path" | awk '
                match($0, /(tm1|TM1|PlanningAnalytics)[^/]*[0-9]+\.[0-9]+(\.[0-9]+(\.[0-9]+)?)?/) {
                    s=substr($0, RSTART, RLENGTH)
                    if (match(s, /[0-9]+\.[0-9]+(\.[0-9]+(\.[0-9]+)?)?/)) {
                        print substr(s, RSTART, RLENGTH)
                        exit
                    }
                }
                match($0, /\/v[0-9]+\.[0-9]+(\.[0-9]+(\.[0-9]+)?)?\//) {
                    v=substr($0, RSTART + 2, RLENGTH - 3)
                    print v
                    exit
                }
            '
            ;;
        udclient)
            # UCD instala en rutas como /opt/IBM/urbancode/deploy/<ver>/
            printf '%s\n' "$path" | awk '
                match($0, /(urbancode|UrbanCode|ucd|UCD)[^/]*[0-9]+\.[0-9]+(\.[0-9]+(\.[0-9]+)?)?/) {
                    s=substr($0, RSTART, RLENGTH)
                    if (match(s, /[0-9]+\.[0-9]+(\.[0-9]+(\.[0-9]+)?)?/)) {
                        print substr(s, RSTART, RLENGTH)
                        exit
                    }
                }
                match($0, /\/[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?\//) {
                    v=substr($0, RSTART + 1, RLENGTH - 2)
                    print v
                    exit
                }
            '
            ;;
        *)
            :
            ;;
    esac
}

ejecutar_como_propietario() {
    owner=$1
    cmd=$2

    [ -n "$owner" ] || return 1

    usuario_actual=$(id -un 2>/dev/null || echo unknown)
    if [ "$usuario_actual" = "$owner" ]; then
        sh -c "$cmd" 2>&1
        return
    fi

    if command -v su >/dev/null 2>&1; then
        su - "$owner" -c "$cmd" 2>&1
        return
    fi

    return 1
}

debe_conservarse() {
    sig=$1
    path=$2

    case "$sig" in
        control.sh)
            case "$path" in
                *filegateway*|*FileGateway*|*file_gateway*|*b2bi*|*B2BI*|*B2Bi*|*gentran*|*Gentran*|*sterling*|*Sterling*|*STERLING*|*install/bin*|*integrator*|*Integrator*|*/si/*|*/SFG/*|*/sfg/*|*/B2B/*|*/b2b/*)
                    return 0
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
        startSecureProxy.sh)
            case "$path" in
                *secureproxy*|*SecureProxy*|*SECUREPROXY*|*sterling*|*Sterling*|*STERLING*|*ssp*|*SSP*|*/proxy/*|*/Proxy/*|*/IBM/SSP*|*/IBM/ssp*)
                    return 0
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
        isql)
            # isql es un nombre genérico — otros stacks SQL (Sybase, FreeTDS)
            # también lo usan. Solo conservar si la ruta tiene contexto Informix.
            case "$path" in
                *informix*|*Informix*|*INFORMIX*|*ifx*|*IFX*)
                    return 0
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
        esql|esqlc|ifxbld|dbaccessdemo|ifxloload|ifxulload)
            # Nombres relativamente específicos de Informix pero validamos
            # contexto de ruta para mayor seguridad.
            case "$path" in
                *informix*|*Informix*|*INFORMIX*|*ifx*|*IFX*|*IBM*)
                    return 0
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
        ifxjdbc.jar)
            # JAR redistribuible — puede aparecer en cualquier proyecto Java.
            # Solo conservar si está en una ruta con contexto inequívoco de
            # instalación Informix, no dentro de aplicaciones de terceros.
            case "$path" in
                *informix*|*Informix*|*INFORMIX*|*ifx*|*IFX*|*/IBM/*)
                    return 0
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
        wsadmin.sh)
            case "$path" in
                *oracle_common*|*Oracle_WT*|*oracle/*)
                    return 1
                    ;;
            esac
            bin_dir=${path%/wsadmin.sh}
            if [ -x "$bin_dir/versionInfo.sh" ] || [ -x "${bin_dir%/bin}/bin/versionInfo.sh" ]; then
                return 0
            fi
            case "$path" in
                *AppServer*|*WebSphere*)
                    return 0
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
        conman)
            case "$path" in
                */bin/conman|*TWS*|*tws*|*WorkloadScheduler*|*workloadscheduler*|*IBM/Workload*)
                    return 0
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
        *)
            return 0
            ;;
    esac
}

producto_desde_ruta() {
    sig=$1
    path=$2
    base_label=$(etiqueta_base_para "$sig")

    case "$sig" in
        wsadmin.sh)
            if printf '%s\n' "$path" | grep -qiE '/dmgr/|/profiles/[[:alnum:]_.-]*dmgr'; then
                printf '%s' 'IBM WebSphere Application Server Network Deployment'
            else
                printf '%s' "$base_label"
            fi
            ;;
        mqsilist)
            if printf '%s\n' "$path" | grep -qiE '/MessageBroker/|/WMBT/|/MBT[0-9]'; then
                printf '%s' 'IBM WebSphere Message Broker'
            else
                printf '%s' 'IBM App Connect Enterprise / IBM Integration Bus'
            fi
            ;;
        control.sh)
            if printf '%s\n' "$path" | grep -qiE 'filegateway|file_gateway'; then
                printf '%s' 'IBM Sterling File Gateway'
            elif printf '%s\n' "$path" | grep -qiE 'b2bi|gentran'; then
                printf '%s' 'IBM Sterling B2B Integrator'
            else
                printf '%s' 'IBM Sterling B2B / File Gateway'
            fi
            ;;
        BPMConfig.sh)
            if printf '%s\n' "$path" | grep -qiE 'baw|business.?automation.?workflow'; then
                printf '%s' 'IBM Business Automation Workflow'
            else
                printf '%s' 'IBM Business Process Manager'
            fi
            ;;
        DecisionCenter.ear)
            printf '%s' 'IBM Operational Decision Manager'
            ;;
        *)
            printf '%s' "$base_label"
            ;;
    esac
}

probar_version_informix() {
    path=$1
    base_dir=$(informix_base_dir_para "$path")
    output=$(ejecutar_oninit_version "$base_dir")
    [ -n "$output" ] || output=$(ejecutar_seguro 3 "$path" -V)
    version=$(printf '%s\n' "$output" | extraer_version_informix)
    if [ -n "$version" ]; then
        printf '%s\t%s\t%s\t%s\n' "$version" "CONFIRMADA" "$path -V" ""
        return
    fi

    inferida=$(version_desde_ruta oninit "$path")
    if [ -n "$inferida" ]; then
        printf '%s\t%s\t%s\t%s\n' "$inferida" "INFERIDA" "ruta de instalación" "El comando oficial no devolvió una versión interpretable"
        return
    fi

    printf '\t%s\t%s\t%s\n' "NO_DISPONIBLE" "ninguno" "No fue posible determinar la versión"
}

probar_version_ifx_clientsdk() {
    path=$1
    base_dir=$(informix_base_dir_para "$path")

    output=$(ejecutar_clientversion "$base_dir" 2>/dev/null || true)
    version=$(printf '%s\n' "$output" | extraer_version_clientversion_clientsdk)
    if [ -n "$version" ]; then
        printf '%s\t%s\t%s\t%s\n' "$version" "CONFIRMADA" "clientversion" ""
        return
    fi

    output=$(ejecutar_ifx_getversion "$base_dir" clientsdk 2>/dev/null || true)
    version=$(printf '%s\n' "$output" | extraer_version_ifx_getversion_clientsdk)
    if [ -n "$version" ]; then
        printf '%s\t%s\t%s\t%s\n' "$version" "CONFIRMADA" "ifx_getversion clientsdk" ""
        return
    fi

    output=$(leer_cr_informix "$base_dir" 2>/dev/null || true)
    version=$(printf '%s\n' "$output" | extraer_version_ifx_cr_clientsdk)
    if [ -n "$version" ]; then
        printf '%s\t%s\t%s\t%s\n' "$version" "CONFIRMADA" "$base_dir/etc/*cr" "La versión se obtuvo desde archivos de control del árbol Informix"
        return
    fi

    output=$(ejecutar_seguro 3 "$path" -V)
    version=$(printf '%s\n' "$output" | extraer_version_informix)
    if [ -n "$version" ]; then
        if informix_compartido_con_engine "$base_dir"; then
            printf '%s\t%s\t%s\t%s\n' "$version" "INFERIDA" "$path -V / instalación compartida Informix" "El Client SDK comparte INFORMIXDIR con el engine; la versión se asoció al stack Informix del mismo árbol"
        else
            printf '%s\t%s\t%s\t%s\n' "$version" "CONFIRMADA" "$path -V" ""
        fi
        return
    fi

    inferida=$(version_desde_ruta oninit "$path")
    if [ -n "$inferida" ]; then
        printf '%s\t%s\t%s\t%s\n' "$inferida" "INFERIDA" "ruta de instalación" "La versión se infirió desde la ruta del árbol Informix asociado"
        return
    fi

    printf '\t%s\t%s\t%s\n' "NO_DISPONIBLE" "ninguno" "Client SDK detectado; no se pudo determinar una versión confiable"
}

probar_version_informix_componente() {
    sig=$1
    path=$2
    base_dir=""

    case "$sig" in
        cdr) base_dir=${path%/bin/cdr} ;;
        ism_startup) base_dir=${path%/bin/ism_startup} ;;
    esac

    if [ -n "$base_dir" ] && [ -x "$base_dir/bin/oninit" ]; then
        output=$(ejecutar_oninit_version "$base_dir")
        version=$(printf '%s\n' "$output" | extraer_version_informix)
        if [ -n "$version" ]; then
            printf '%s\t%s\t%s\t%s\n' "$version" "INFERIDA" "$base_dir/bin/oninit -V" "La versión del componente se asoció a la instalación principal de Informix"
            return
        fi
    fi

    inferida=$(version_desde_ruta "$sig" "$path")
    if [ -n "$inferida" ]; then
        printf '%s\t%s\t%s\t%s\n' "$inferida" "INFERIDA" "ruta de instalación" "La versión se infirió desde la ruta del componente Informix"
        return
    fi

    printf '\t%s\t%s\t%s\n' "NO_DISPONIBLE" "ninguno" "Componente Informix detectado; no se encontró un método de versión confiable"
}

probar_version_db2() {
    path=$1
    owner=$(propietario_de_ruta "$path")

    if [ -n "$owner" ]; then
        output=$(ejecutar_como_propietario "$owner" "$path")
        version=$(printf '%s\n' "$output" | extraer_version_db2)
        if [ -n "$version" ]; then
            printf '%s\t%s\t%s\t%s\n' "$version" "CONFIRMADA" "db2level como $owner" ""
            return
        fi
    fi

    output=$(ejecutar_seguro 3 "$path")
    version=$(printf '%s\n' "$output" | extraer_version_db2)
    if [ -n "$version" ]; then
        printf '%s\t%s\t%s\t%s\n' "$version" "CONFIRMADA" "$path" ""
        return
    fi

    inferida=$(version_desde_ruta db2level "$path")
    if [ -n "$inferida" ]; then
        nota="db2level no devolvió una versión utilizable"
        [ -n "$owner" ] && nota="$nota; propietario=$owner"
        printf '%s\t%s\t%s\t%s\n' "$inferida" "INFERIDA" "ruta de instalación" "$nota"
        return
    fi

    printf '\t%s\t%s\t%s\n' "NO_DISPONIBLE" "ninguno" "No fue posible determinar la versión"
}

probar_version_iidr() {
    path=$1
    base_dir=${path%/bin/dmts64}
    tool=$base_dir/bin/dmshowversion
    owner=$(propietario_de_ruta "$path")

    if [ -x "$tool" ]; then
        if [ -n "$owner" ]; then
            output=$(ejecutar_como_propietario "$owner" "$tool")
            version=$(printf '%s\n' "$output" | extraer_version_iidr)
            if [ -n "$version" ]; then
                build=$(printf '%s\n' "$output" | extraer_build_iidr)
                nota=""
                [ -n "$build" ] && nota="Build: $build"
                printf '%s\t%s\t%s\t%s\n' "$version" "CONFIRMADA" "dmshowversion como $owner" "$nota"
                return
            fi
        fi

        output=$(ejecutar_seguro 5 "$tool")
        version=$(printf '%s\n' "$output" | extraer_version_iidr)
        if [ -n "$version" ]; then
            build=$(printf '%s\n' "$output" | extraer_build_iidr)
            nota=""
            [ -n "$build" ] && nota="Build: $build"
            printf '%s\t%s\t%s\t%s\n' "$version" "CONFIRMADA" "$tool" "$nota"
            return
        fi
    fi

    output=$(ejecutar_seguro 3 "$path" -version)
    if printf '%s\n' "$output" | grep -qi 'cannot be run as root'; then
        nota="dmts64 no puede ejecutarse como root"
        [ -n "$owner" ] && nota="$nota; propietario=$owner"
        printf '\t%s\t%s\t%s\n' "BLOQUEADA" "dmts64 -version" "$nota"
        return
    fi

    printf '\t%s\t%s\t%s\n' "NO_DISPONIBLE" "ninguno" "No fue posible determinar la versión"
}

probar_version_mq() {
    path=$1
    bin_dir=${path%/dspmq}
    tool=$bin_dir/dspmqver

    if [ -x "$tool" ]; then
        output=$(ejecutar_seguro 3 "$tool" -b)
        version=$(printf '%s\n' "$output" | extraer_version_mq)
        if [ -n "$version" ]; then
            printf '%s\t%s\t%s\t%s\n' "$version" "CONFIRMADA" "$tool -b" ""
            return
        fi

        output=$(ejecutar_seguro 3 "$tool")
        version=$(printf '%s\n' "$output" | extraer_version_mq)
        if [ -n "$version" ]; then
            printf '%s\t%s\t%s\t%s\n' "$version" "CONFIRMADA" "$tool" ""
            return
        fi
    fi

    if command -v dspmqver >/dev/null 2>&1; then
        output=$(ejecutar_seguro 3 dspmqver -b)
        version=$(printf '%s\n' "$output" | extraer_version_mq)
        if [ -n "$version" ]; then
            printf '%s\t%s\t%s\t%s\n' "$version" "CONFIRMADA" "dspmqver -b" ""
            return
        fi
        output=$(ejecutar_seguro 3 dspmqver)
        version=$(printf '%s\n' "$output" | extraer_version_mq)
        if [ -n "$version" ]; then
            printf '%s\t%s\t%s\t%s\n' "$version" "CONFIRMADA" "dspmqver" ""
            return
        fi
    fi

    printf '\t%s\t%s\t%s\n' "NO_DISPONIBLE" "ninguno" "No fue posible determinar la versión"
}

probar_version_was() {
    path=$1
    bin_dir=${path%/wsadmin.sh}
    tool=$bin_dir/versionInfo.sh

    if [ -x "$tool" ]; then
        output=$(ejecutar_seguro 10 "$tool")
        version=$(printf '%s\n' "$output" | extraer_version_was)
        if [ -n "$version" ]; then
            note=""
            if printf '%s\n' "$output" | grep -qi 'Network Deployment'; then
                note="Se encontró evidencia de Network Deployment"
            fi
            printf '%s\t%s\t%s\t%s\n' "$version" "CONFIRMADA" "$tool" "$note"
            return
        fi

        if printf '%s\n' "$output" | grep -qiE 'permission denied|not permitted|cannot|failed|error'; then
            printf '\t%s\t%s\t%s\n' "BLOQUEADA" "$tool" "versionInfo.sh devolvió un error o requirió entorno adicional"
            return
        fi
    fi

    if printf '%s\n' "$path" | grep -qiE '/dmgr/|/profiles/[[:alnum:]_.-]*dmgr'; then
        printf '\t%s\t%s\t%s\n' "INFERIDA" "ruta de instalación" "La ruta sugiere Network Deployment, pero no se confirmó la versión"
        return
    fi

    printf '\t%s\t%s\t%s\n' "NO_DISPONIBLE" "ninguno" "No fue posible determinar la versión"
}

probar_version_ace_iib() {
    path=$1
    bin_dir=${path%/mqsilist}
    tool=$bin_dir/mqsiversion
    profile=$bin_dir/mqsiprofile

    if [ -x "$tool" ]; then
        output=$(ejecutar_seguro 5 "$tool")
        version=$(printf '%s\n' "$output" | extraer_version_ace_iib)
        if [ -n "$version" ]; then
            printf '%s\t%s\t%s\t%s\n' "$version" "CONFIRMADA" "$tool" ""
            return
        fi
    fi

    if [ -x "$profile" ] && [ -x "$tool" ]; then
        output=$(sh -c ". \"$profile\" >/dev/null 2>&1; \"$tool\"" 2>&1 | head -n 60)
        version=$(printf '%s\n' "$output" | extraer_version_ace_iib)
        if [ -n "$version" ]; then
            printf '%s\t%s\t%s\t%s\n' "$version" "CONFIRMADA" "mqsiprofile + mqsiversion" ""
            return
        fi
        if printf '%s\n' "$output" | grep -qiE 'permission denied|not permitted|cannot|failed|error'; then
            printf '\t%s\t%s\t%s\n' "BLOQUEADA" "mqsiprofile + mqsiversion" "La consulta de versión requirió entorno o permisos adicionales"
            return
        fi
    fi

    inferida=$(version_desde_ruta mqsilist "$path")
    if [ -n "$inferida" ]; then
        printf '%s\t%s\t%s\t%s\n' "$inferida" "INFERIDA" "ruta de instalación" "La versión se infirió desde la ruta detectada"
        return
    fi

    printf '\t%s\t%s\t%s\n' "NO_DISPONIBLE" "ninguno" "No fue posible determinar la versión"
}

probar_version_wmb() {
    # WebSphere Message Broker comparte el binario mqsilist con ACE/IIB.
    # La distinción es por ruta. El versionado usa mqsiversion si está presente.
    # Cobertura parcial: mqsiversion puede no existir en WMB v2.x/v5.x.
    path=$1
    bin_dir=${path%/mqsilist}
    tool=$bin_dir/mqsiversion
    profile=$bin_dir/mqsiprofile

    if [ -x "$tool" ]; then
        output=$(ejecutar_seguro 5 "$tool")
        version=$(printf '%s\n' "$output" | extraer_version_ace_iib)
        if [ -n "$version" ]; then
            printf '%s\t%s\t%s\t%s\n' "$version" "CONFIRMADA" "$tool" ""
            return
        fi
    fi

    if [ -x "$profile" ] && [ -x "$tool" ]; then
        output=$(sh -c ". \"$profile\" >/dev/null 2>&1; \"$tool\"" 2>&1 | head -n 60)
        version=$(printf '%s\n' "$output" | extraer_version_ace_iib)
        if [ -n "$version" ]; then
            printf '%s\t%s\t%s\t%s\n' "$version" "CONFIRMADA" "mqsiprofile + mqsiversion" ""
            return
        fi
    fi

    inferida=$(version_desde_ruta mqsilist "$path")
    if [ -n "$inferida" ]; then
        printf '%s\t%s\t%s\t%s\n' "$inferida" "INFERIDA" "ruta de instalación" "La versión se infirió desde la ruta detectada"
        return
    fi

    printf '\t%s\t%s\t%s\n' "NO_DISPONIBLE" "ninguno" "WebSphere Message Broker detectado; cobertura parcial — mqsiversion no disponible en esta instalación"
}

probar_version_sterling_control() {
    path=$1
    product=$(producto_desde_ruta control.sh "$path")
    note_base="Clasificación basada en ruta de instalación"
    if printf '%s\n' "$path" | grep -qiE 'install/bin'; then
        note_base="$note_base; se detectó install/bin"
    fi
    if printf '%s\n' "$path" | grep -qiE 'properties'; then
        note_base="$note_base; se detectó properties"
    fi
    case "$product" in
        "IBM Sterling File Gateway")
            printf '\t%s\t%s\t%s\n' "INFERIDA" "ruta de instalación" "$note_base; la ruta sugiere Sterling File Gateway; no se confirmó versión"
            ;;
        "IBM Sterling B2B Integrator")
            printf '\t%s\t%s\t%s\n' "INFERIDA" "ruta de instalación" "$note_base; la ruta sugiere Sterling B2B Integrator; no se confirmó versión"
            ;;
        *)
            printf '\t%s\t%s\t%s\n' "INFERIDA" "ruta de instalación" "$note_base; control.sh detectado, pero no fue posible clasificar con precisión si corresponde a File Gateway o B2B Integrator"
            ;;
    esac
}

probar_version_secure_proxy() {
    printf '\t%s\t%s\t%s\n' "NO_DISPONIBLE" "ninguno" "Secure Proxy detectado; falta implementar una obtención de versión confiable"
}

probar_version_bpm() {
    path=$1
    bin_dir=${path%/BPMConfig.sh}
    tool=$bin_dir/BPMShowVersion.sh
    version_tool=$bin_dir/versionInfo.sh

    if [ -x "$tool" ]; then
        output=$(ejecutar_seguro 10 "$tool")
        version=$(printf '%s\n' "$output" | extraer_version_bpm)
        if [ -n "$version" ]; then
            printf '%s\t%s\t%s\t%s\n' "$version" "CONFIRMADA" "$tool" ""
            return
        fi
        if printf '%s\n' "$output" | grep -qiE 'permission denied|not permitted|cannot|failed|error'; then
            printf '\t%s\t%s\t%s\n' "BLOQUEADA" "$tool" "BPMShowVersion.sh devolvió un error o requirió entorno adicional"
            return
        fi
    fi

    if [ -x "$version_tool" ]; then
        output=$(ejecutar_seguro 10 "$version_tool")
        version=$(printf '%s\n' "$output" | extraer_version_bpm)
        if [ -n "$version" ]; then
            printf '%s\t%s\t%s\t%s\n' "$version" "CONFIRMADA" "$version_tool" ""
            return
        fi
        if printf '%s\n' "$output" | grep -qiE 'permission denied|not permitted|cannot|failed|error'; then
            printf '\t%s\t%s\t%s\n' "BLOQUEADA" "$version_tool" "versionInfo.sh devolvió un error o requirió entorno adicional"
            return
        fi
    fi

    inferida=$(version_desde_ruta BPMConfig.sh "$path")
    if [ -n "$inferida" ]; then
        printf '%s\t%s\t%s\t%s\n' "$inferida" "INFERIDA" "ruta de instalación" "La versión se infirió desde la ruta detectada"
        return
    fi

    printf '\t%s\t%s\t%s\n' "NO_DISPONIBLE" "ninguno" "BPM detectado; no se confirmó versión"
}

probar_version_odm() {
    printf '\t%s\t%s\t%s\n' "NO_DISPONIBLE" "ninguno" "ODM detectado; falta implementar una obtención de versión confiable"
}

probar_version_datastage() {
    path=$1
    inferida=$(version_desde_ruta dsrpcd "$path")
    if [ -n "$inferida" ]; then
        printf '%s\t%s\t%s\t%s\n' "$inferida" "INFERIDA" "ruta de instalación" "La versión se infirió desde la ruta detectada de Information Server / DataStage"
        return
    fi

    printf '\t%s\t%s\t%s\n' "NO_DISPONIBLE" "ninguno" "DataStage detectado; no se encontró un método de versión confiable en esta ruta"
}

probar_version_tem() {
    path=$1
    # BESClient no tiene flag de versión confiable en todas las versiones
    # Se intenta obtener versión desde el binario directamente
    output=$(ejecutar_seguro 5 "$path" --version 2>/dev/null)
    version=$(printf '%s\n' "$output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    if [ -n "$version" ]; then
        printf '%s\t%s\t%s\t%s\n' "$version" "CONFIRMADA" "$path --version" ""
        return
    fi
    printf '\t%s\t%s\t%s\n' "NO_DISPONIBLE" "ninguno" "BigFix/TEM detectado; no se pudo obtener versión del agente"
}

probar_version_tws() {
    path=$1
    output=$(ejecutar_seguro 5 "$path" -v 2>/dev/null)
    version=$(printf '%s\n' "$output" | awk '
        tolower($0) ~ /version|tivoli|workload|scheduler/ && match($0, /[0-9]+\.[0-9]+(\.[0-9]+(\.[0-9]+)?)?/) {
            print substr($0, RSTART, RLENGTH)
            exit
        }
    ')
    if [ -n "$version" ]; then
        printf '%s\t%s\t%s\t%s\n' "$version" "CONFIRMADA" "$path -v" ""
        return
    fi
    inferida=$(version_desde_ruta conman "$path")
    if [ -n "$inferida" ]; then
        printf '%s\t%s\t%s\t%s\n' "$inferida" "INFERIDA" "ruta de instalación" "La versión se infirió desde la ruta detectada"
        return
    fi
    printf '\t%s\t%s\t%s\n' "NO_DISPONIBLE" "ninguno" "TWS detectado; no se pudo obtener versión"
}

probar_version_ucd() {
    path=$1
    output=$(ejecutar_seguro 5 "$path" version 2>/dev/null)
    version=$(printf '%s\n' "$output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    if [ -n "$version" ]; then
        printf '%s\t%s\t%s\t%s\n' "$version" "CONFIRMADA" "$path version" ""
        return
    fi
    printf '\t%s\t%s\t%s\n' "NO_DISPONIBLE" "ninguno" "UrbanCode Deploy detectado; no se pudo obtener versión del cliente"
}

probar_version_wesb() {
    printf '\t%s\t%s\t%s\n' "NO_DISPONIBLE" "ninguno" "WebSphere ESB detectado; no hay comando de versión confiable disponible"
}

probar_version_tm1() {
    path=$1
    inferida=$(version_desde_ruta tm1sd "$path")
    if [ -n "$inferida" ]; then
        printf '%s\t%s\t%s\t%s\n' "$inferida" "INFERIDA" "ruta de instalación" "La versión se infirió desde la ruta detectada"
        return
    fi
    printf '\t%s\t%s\t%s\n' "NO_DISPONIBLE" "ninguno" "TM1 detectado; no se pudo obtener versión del servidor"
}

probar_version_isql() {
    path=$1
    # isql es un cliente Informix en versiones viejas — versión no disponible sin engine activo
    printf '\t%s\t%s\t%s\n' "NO_DISPONIBLE" "ninguno" "Informix SQL Development detectado vía isql; versión requiere engine activo"
}

probar_version_ifx_connect() {
    path=$1
    base_dir=$(informix_base_dir_para "$path")

    output=$(ejecutar_clientversion "$base_dir" 2>/dev/null || true)
    version=$(printf '%s\n' "$output" | extraer_version_clientversion_clientsdk)
    if [ -n "$version" ]; then
        printf '%s\t%s\t%s\t%s\n' "$version" "CONFIRMADA" "clientversion" ""
        return
    fi

    output=$(ejecutar_ifx_getversion "$base_dir" esql 2>/dev/null || true)
    version=$(printf '%s\n' "$output" | extraer_version_ifx_getversion_esql)
    if [ -n "$version" ]; then
        printf '%s\t%s\t%s\t%s\n' "$version" "CONFIRMADA" "ifx_getversion esql" ""
        return
    fi

    output=$(leer_cr_informix "$base_dir" 2>/dev/null || true)
    version=$(printf '%s\n' "$output" | extraer_version_ifx_cr_esql)
    if [ -n "$version" ]; then
        printf '%s\t%s\t%s\t%s\n' "$version" "CONFIRMADA" "$base_dir/etc/*cr" "La versión se obtuvo desde archivos de control del árbol Informix"
        return
    fi

    inferida=$(version_desde_ruta oninit "$path")
    if [ -n "$inferida" ]; then
        printf '%s\t%s\t%s\t%s\n' "$inferida" "INFERIDA" "instalación compartida Informix" "La versión se asoció al árbol Informix donde reside el componente de conectividad"
        return
    fi
    printf '\t%s\t%s\t%s\n' "NO_DISPONIBLE" "ninguno" "Informix Connect / Client SDK detectado; no se pudo determinar versión"
}

probar_version_ifx_hpl() {
    path=$1
    # ifxloload/ifxulload — High-Performance Loader
    inferida=$(version_desde_ruta oninit "$path")
    if [ -n "$inferida" ]; then
        printf '%s\t%s\t%s\t%s\n' "$inferida" "INFERIDA" "ruta de instalación" "La versión se infirió desde la ruta del High-Performance Loader"
        return
    fi
    printf '\t%s\t%s\t%s\n' "NO_DISPONIBLE" "ninguno" "Informix High-Performance Loader detectado; no se pudo determinar versión"
}

probar_version_ifx_jdbc() {
    path=$1
    base_dir=$(informix_base_dir_para "$path")

    output=$(ejecutar_clientversion "$base_dir" 2>/dev/null || true)
    version=$(printf '%s\n' "$output" | extraer_version_clientversion_clientsdk)
    if [ -n "$version" ]; then
        printf '%s\t%s\t%s\t%s\n' "$version" "INFERIDA" "clientversion" "La versión del JDBC se asoció al stack cliente Informix del mismo árbol"
        return
    fi

    output=$(ejecutar_ifx_getversion "$base_dir" libjava 2>/dev/null || true)
    version=$(printf '%s\n' "$output" | extraer_version_ifx_getversion_clientsdk)
    if [ -n "$version" ]; then
        printf '%s\t%s\t%s\t%s\n' "$version" "CONFIRMADA" "ifx_getversion libjava" ""
        return
    fi

    if informix_compartido_con_engine "$base_dir"; then
        inferida=$(version_desde_ruta oninit "$path")
        if [ -n "$inferida" ]; then
            printf '%s\t%s\t%s\t%s\n' "$inferida" "INFERIDA" "instalación compartida Informix" "El JDBC Driver reside en un INFORMIXDIR compartido con el engine; la versión se asoció a ese árbol"
            return
        fi
    fi

    printf '%s\n' "$path" | awk '
        match($0, /ifxjdbc[-_]?[0-9]+\.[0-9]+(\.[0-9]+(\.[0-9]+)?)?/) {
            s=substr($0, RSTART, RLENGTH)
            if (match(s, /[0-9]+\.[0-9]+(\.[0-9]+(\.[0-9]+)?)?/)) {
                print substr(s, RSTART, RLENGTH)
                exit
            }
        }
    ' | {
        read -r ver
        if [ -n "$ver" ]; then
            printf '%s\t%s\t%s\t%s\n' "$ver" "INFERIDA" "nombre del JAR" "La versión se infirió desde el nombre del archivo JDBC"
        else
            printf '\t%s\t%s\t%s\n' "NO_DISPONIBLE" "ninguno" "Informix JDBC Driver detectado; versión no determinable sin inspeccionar el JAR"
        fi
    }
}

construir_resultados() {
    : > "$RESULTADOS"
    while IFS="$(printf '\t')" read -r sig path; do
        label=$(producto_desde_ruta "$sig" "$path")
        case "$sig" in
            oninit)              meta=$(probar_version_informix "$path") ;;
            dbaccess)            meta=$(probar_version_ifx_clientsdk "$path") ;;
            cdr|ism_startup)     meta=$(probar_version_informix_componente "$sig" "$path") ;;
            db2level)            meta=$(probar_version_db2 "$path") ;;
            dmts64)              meta=$(probar_version_iidr "$path") ;;
            dspmq)               meta=$(probar_version_mq "$path") ;;
            wsadmin.sh)          meta=$(probar_version_was "$path") ;;
            mqsilist)
                # Distinguir entre WMB (versiones viejas) y ACE/IIB por ruta
                _label=$(producto_desde_ruta mqsilist "$path")
                case "$_label" in
                    *"Message Broker"*) meta=$(probar_version_wmb "$path") ;;
                    *)                  meta=$(probar_version_ace_iib "$path") ;;
                esac
                ;;
            control.sh)          meta=$(probar_version_sterling_control "$path") ;;
            startSecureProxy.sh) meta=$(probar_version_secure_proxy) ;;
            BPMConfig.sh)        meta=$(probar_version_bpm "$path") ;;
            DecisionCenter.ear)  meta=$(probar_version_odm) ;;
            dsrpcd)              meta=$(probar_version_datastage "$path") ;;
            BESClient)           meta=$(probar_version_tem "$path") ;;
            conman)              meta=$(probar_version_tws "$path") ;;
            udclient)            meta=$(probar_version_ucd "$path") ;;
            wesbinstall)         meta=$(probar_version_wesb) ;;
            tm1sd|tm1s)          meta=$(probar_version_tm1 "$path") ;;
            isql)                meta=$(probar_version_isql "$path") ;;
            esql|esqlc|ifxbld|dbaccessdemo) meta=$(probar_version_ifx_connect "$path") ;;
            ifxloload|ifxulload) meta=$(probar_version_ifx_hpl "$path") ;;
            ifxjdbc.jar)         meta=$(probar_version_ifx_jdbc "$path") ;;
            *)
                meta=$(printf '\t%s\t%s\t%s\n' "NO_DISPONIBLE" "no implementado" "La obtención de versión no está implementada para este producto")
                ;;
        esac

        version=$(printf '%s\n' "$meta" | awk -F '\t' 'NR==1 {print $1}')
        estado=$(printf '%s\n' "$meta" | awk -F '\t' 'NR==1 {print $2}')
        metodo=$(printf '%s\n' "$meta" | awk -F '\t' 'NR==1 {print $3}')
        nota=$(printf '%s\n' "$meta" | awk -F '\t' 'NR==1 {print $4}')
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$sig" "$path" "$version" "$estado" "$metodo" "$nota" >> "$RESULTADOS"
    done < "$HALLAZGOS"
}

emitir_bloque_servidor() {
    _ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date 2>/dev/null || echo "desconocido")
    salida "$SEPARADOR"
    salida "Información del servidor"
    salida "$SEPARADOR"
    salida "Nombre del servidor: $SERVIDOR_NOMBRE"
    salida "IP(s): $SERVIDOR_IPS"
    salida "Sistema operativo: $SERVIDOR_SO"
    salida "Cores/vCPUs del servidor: $SERVIDOR_CPUS"
    salida "Fecha y hora de ejecución: $_ts"
    salida ""
}

emitir_reporte() {
    emitir_bloque_servidor

    while IFS="$(printf '\t')" read -r label sig path version estado metodo nota; do
        salida "$SEPARADOR"
        salida "$label encontrado en este servidor"
        salida "$SEPARADOR"
        salida "Ruta(s):"
        salida "$path"
        salida ""
        [ -n "$version" ] && salida "Versión: $version"
        [ -n "$estado" ] && salida "Estado de versión: $estado"
        [ -n "$metodo" ] && salida "Método de versión: $metodo"
        [ -n "$nota" ] && salida "Nota de versión: $nota"
        salida ""
    done < "$RESULTADOS"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) uso; exit 0 ;;
        *)
            printf '%s: opción desconocida: %s\n' "$PROG" "$1" >&2
            uso >&2
            exit 2
            ;;
    esac
    shift
done

TMPDIR=${TMPDIR:-/tmp}
HALLAZGOS=$TMPDIR/descLinux-v9.$$.hits
RESULTADOS=$TMPDIR/descLinux-v9.$$.results
FIND_TMP=$TMPDIR/descLinux-v9.$$.find
trap 'rm -f "$HALLAZGOS" "$RESULTADOS" "$FIND_TMP"' EXIT INT TERM
: > "$HALLAZGOS"
: > "$RESULTADOS"

recolectar_info_servidor

_nombre_sanitizado=$(printf '%s' "$SERVIDOR_NOMBRE" | tr -cs 'A-Za-z0-9_-' '_')
_fecha=$(date '+%Y%m%d' 2>/dev/null || echo "00000000")
OUTPUT_FILE=./descLinux_v9_${_nombre_sanitizado}_${_fecha}.txt

: > "$OUTPUT_FILE" 2>/dev/null || {
    printf '%s: no se pudo escribir el archivo de salida: %s\n' "$PROG" "$OUTPUT_FILE" >&2
    exit 2
}
OUTPUT_DEST=$OUTPUT_FILE

name_expr=""
first=1
while IFS='|' read -r sig _; do
    [ -z "$sig" ] && continue
    if [ "$first" = 1 ]; then
        name_expr="-name $sig"
        first=0
    else
        name_expr="$name_expr -o -name $sig"
    fi
done <<EOF
$CATALOGO
EOF

# Construir expresión de prune para find.
# IMPORTANTE: NO se usa -xdev porque en Linux es común que /opt, /IBM o /data
# sean filesystems locales montados por separado (LVM, discos dedicados).
# Con -xdev el find no cruzaría esos mounts y se perderían instalaciones IBM.
# En su lugar se excluyen explícitamente los filesystems virtuales y de red
# conocidos mediante -path ... -prune, que es POSIX y funciona en SOs viejos.
# Las rutas excluidas cubren: kernel virtual (/proc, /sys), dispositivos (/dev),
# runtime (/run, /var/run), snaps, medios removibles y temporales de mount.

prune_expr=""
first=1
for p in $RUTAS_EXCLUIDAS; do
    if [ "$first" = 1 ]; then
        prune_expr="-path $p"
        first=0
    else
        prune_expr="$prune_expr -o -path $p"
    fi
done

# shellcheck disable=SC2086
find / \( $prune_expr \) -prune -o \( $name_expr \) -type f -print 2>/dev/null > "$FIND_TMP" &
_find_pid=$!
_find_elapsed=0
while [ "$_find_elapsed" -lt "$FIND_TIMEOUT_S" ]; do
    sleep 5
    _find_elapsed=$(( _find_elapsed + 5 ))
    kill -0 "$_find_pid" 2>/dev/null || break
done
if kill -0 "$_find_pid" 2>/dev/null; then
    kill -TERM "$_find_pid" 2>/dev/null
    sleep 2
    kill -0 "$_find_pid" 2>/dev/null && kill -KILL "$_find_pid" 2>/dev/null
fi
wait "$_find_pid" 2>/dev/null || true

while IFS= read -r path; do
    sig=${path##*/}
    debe_conservarse "$sig" "$path" || continue
    printf '%s\t%s\n' "$sig" "$path" >> "$HALLAZGOS"
done < "$FIND_TMP"

if [ "$_find_elapsed" -ge "$FIND_TIMEOUT_S" ]; then
    printf '%s: ADVERTENCIA: find supero el limite de %ss y fue interrumpido. Resultados pueden ser incompletos.\n' "$PROG" "$FIND_TIMEOUT_S" >&2
fi

if [ -s "$HALLAZGOS" ]; then
    construir_resultados
fi

emitir_reporte

cat "$OUTPUT_FILE"

if [ -s "$HALLAZGOS" ]; then
    exit 0
else
    exit 1
fi
