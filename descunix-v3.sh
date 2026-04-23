#!/bin/sh
# descunix-v3.sh — Detect installed IBM products on a Unix/Linux host.
# Successor to descunix-v2.sh with:
#   * single filesystem pass
#   * pruning of noisy paths
#   * data-driven catalog
#   * output formats: human (default), tsv, json
#   * optional version probes (--with-versions)
#   * server metadata in all output formats
#   * meaningful exit codes
#
# Usage:
#   sh descunix-v3.sh [--format=human|tsv|json] [--quiet] [--one-fs]
#                     [--with-versions] [--root=/path] [--help]
#
# Exit codes:
#   0  at least one product found
#   1  no products found
#   2  usage error

set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
LC_ALL=C
export LC_ALL

PROG=${0##*/}

# ---------------------------------------------------------------------------
# Catalog: signature|label|path_regex
#   signature  — basename looked up by find
#   label      — human label shown in output
#   path_regex — optional ERE; if set, a hit is kept only when the full path
#                matches. Anchors fragile signatures (e.g. control.sh).
# ---------------------------------------------------------------------------
CATALOG='
oninit|Informix|
dmts64|IIDR|
wsadmin.sh|WAS|
mqsilist|IIB / ACE|
dspmq|MQ|
control.sh|B2B / FileGateway|(install/bin|b2bi|gentran)
startSecureProxy.sh|Sterling Secure Proxy|
dbaccess|Informix Client SDK|
c4gl|Informix 4GL Compiler|
r4gl|Informix 4GL Runtime|
fglgo|Informix 4GL RDS|
db2level|IBM Db2|
imcl|IBM Installation Manager|
dsmc|IBM Spectrum Protect|
cogconfig.sh|IBM Cognos|
collation.sh|IBM TADDM|
startPortalServer.sh|WebSphere Portal|
idsldapsearch|IBM Security Directory Server|
datastage|InfoSphere DataStage|
'

# Paths pruned from the scan — noisy and never host IBM products.
PRUNE_PATHS='/proc /sys /dev /run /var/run /snap /mnt /media /cdrom /tmp/.mount_*'

# ---------------------------------------------------------------------------
# Defaults (overridable via flags)
# ---------------------------------------------------------------------------
FORMAT=human
QUIET=0
ONE_FS=0
WITH_VERSIONS=0
ROOT=/

SERVER_HOSTNAME=unknown
SERVER_IPS=unknown
SERVER_OS=unknown
SERVER_CPUS=unknown

usage() {
    cat <<EOF
$PROG — detecta productos IBM instalados recorriendo el filesystem.

Uso:
  $PROG [opciones]

Opciones:
  --format=FMT      Formato de salida: human (default) | tsv | json
  --quiet           No imprimir productos no encontrados / encabezados
  --one-fs          Limitar el barrido al filesystem raíz (find -xdev)
  --with-versions   Intentar capturar versión de cada producto encontrado
  --root=PATH       Cambiar el punto de partida del barrido (default: /)
  --help            Mostrar esta ayuda y salir

Códigos de salida:
  0  al menos un producto encontrado
  1  ninguno encontrado
  2  error de uso

Catálogo actual (firma → producto):
EOF
    while IFS='|' read -r sig label _; do
        [ -z "$sig" ] && continue
        printf '  %-22s %s\n' "$sig" "$label"
    done <<EOF
$CATALOG
EOF
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

get_hostname_value() {
    host=$(hostname 2>/dev/null || true)
    [ -n "$host" ] || host=$(uname -n 2>/dev/null || true)
    printf '%s' "${host:-unknown}"
}

get_ip_values() {
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

    printf '%s' "unknown"
}

get_os_value() {
    os=""

    if [ -r /etc/os-release ]; then
        os=$(awk -F= '
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
        [ -n "$os" ] && {
            printf '%s' "$os"
            return
        }
    fi

    for f in /etc/redhat-release /etc/oracle-release /etc/centos-release /etc/SuSE-release /etc/issue; do
        [ -r "$f" ] || continue
        os=$(head -n 1 "$f" 2>/dev/null)
        [ -n "$os" ] && {
            printf '%s' "$os"
            return
        }
    done

    os_name=$(uname -s 2>/dev/null || echo unknown)
    os_rel=$(uname -r 2>/dev/null || true)
    printf '%s %s' "$os_name" "$os_rel"
}

get_cpu_value() {
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

    printf '%s' "unknown"
}

collect_server_info() {
    SERVER_HOSTNAME=$(get_hostname_value)
    SERVER_IPS=$(get_ip_values)
    SERVER_OS=$(get_os_value)
    SERVER_CPUS=$(get_cpu_value)
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --format=*)      FORMAT=${1#--format=} ;;
        --format)        shift; FORMAT=${1:-} ;;
        --quiet|-q)      QUIET=1 ;;
        --one-fs)        ONE_FS=1 ;;
        --with-versions) WITH_VERSIONS=1 ;;
        --root=*)        ROOT=${1#--root=} ;;
        --root)          shift; ROOT=${1:-} ;;
        -h|--help)       usage; exit 0 ;;
        *)
            printf '%s: opción desconocida: %s\n' "$PROG" "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

case "$FORMAT" in
    human|tsv|json) ;;
    *)
        printf '%s: --format debe ser human|tsv|json (recibido: %s)\n' "$PROG" "$FORMAT" >&2
        exit 2
        ;;
esac

if [ ! -d "$ROOT" ]; then
    printf '%s: --root no es un directorio: %s\n' "$PROG" "$ROOT" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Build the find command from the catalog and run it once.
#   find $ROOT [-xdev]
#     \( -path /proc -o -path /sys ... \) -prune -o
#     \( -name sig1 -o -name sig2 ... \) -type f -print
# ---------------------------------------------------------------------------
run_find() {
    name_expr=""
    first=1
    while IFS='|' read -r sig _ _; do
        [ -z "$sig" ] && continue
        if [ "$first" = 1 ]; then
            name_expr="-name $sig"
            first=0
        else
            name_expr="$name_expr -o -name $sig"
        fi
    done <<EOF
$CATALOG
EOF

    prune_expr=""
    first=1
    for p in $PRUNE_PATHS; do
        if [ "$first" = 1 ]; then
            prune_expr="-path $p"
            first=0
        else
            prune_expr="$prune_expr -o -path $p"
        fi
    done

    xdev_flag=""
    [ "$ONE_FS" = 1 ] && xdev_flag="-xdev"

    # Single filesystem traversal.
    # shellcheck disable=SC2086  # intentional word-splitting of expressions
    find "$ROOT" $xdev_flag \( $prune_expr \) -prune -o \
        \( $name_expr \) -type f -print 2>/dev/null
}

# ---------------------------------------------------------------------------
# Lookup tables: for each signature find its label and path regex.
# We iterate CATALOG instead of using associative arrays (not POSIX).
# ---------------------------------------------------------------------------
label_for() {
    target=$1
    while IFS='|' read -r sig label _; do
        [ "$sig" = "$target" ] && {
            printf '%s' "$label"
            return
        }
    done <<EOF
$CATALOG
EOF
}

regex_for() {
    target=$1
    while IFS='|' read -r sig _ rx; do
        [ "$sig" = "$target" ] && {
            printf '%s' "$rx"
            return
        }
    done <<EOF
$CATALOG
EOF
}

# ---------------------------------------------------------------------------
# Version probes. Cheap, best-effort, gated by command -v and timeout(1).
# Each probe prints a single line (or empty on failure).
# ---------------------------------------------------------------------------
safe_run() {
    # safe_run TIMEOUT_S cmd args...
    t=$1
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "${t}s" "$@" 2>/dev/null | head -n 1
    else
        "$@" 2>/dev/null | head -n 1
    fi
}

version_probe() {
    sig=$1
    path=$2
    case "$sig" in
        oninit)    safe_run 3 "$path" -version ;;
        dspmq)     command -v dspmqver >/dev/null 2>&1 && safe_run 3 dspmqver -b ;;
        mqsilist)  safe_run 3 "$path" -v ;;
        db2level)  safe_run 3 "$path" ;;
        imcl)      safe_run 5 "$path" -version ;;
        dsmc)      safe_run 3 "$path" -version ;;
        wsadmin.sh) : ;; # too expensive (boots JVM) — skip
        *)         : ;;
    esac
}

# ---------------------------------------------------------------------------
# Scan and collect hits keyed by signature.
# Results stored in a temp file as: signature<TAB>path
# ---------------------------------------------------------------------------
TMPDIR=${TMPDIR:-/tmp}
HITS=$TMPDIR/descunix-v3.$$.hits
trap 'rm -f "$HITS"' EXIT INT TERM
: > "$HITS"

collect_server_info

run_find | while IFS= read -r path; do
    base=${path##*/}
    rx=$(regex_for "$base")
    if [ -n "$rx" ]; then
        printf '%s' "$path" | grep -Eq "$rx" || continue
    fi
    printf '%s\t%s\n' "$base" "$path" >> "$HITS"
done

# ---------------------------------------------------------------------------
# Emit results.
# ---------------------------------------------------------------------------
emit_human() {
    printf 'Información del servidor\n'
    printf 'Nombre del servidor: %s\n' "$SERVER_HOSTNAME"
    printf 'IP(s): %s\n' "$SERVER_IPS"
    printf 'Sistema operativo: %s\n' "$SERVER_OS"
    printf 'Cores/vCPUs del servidor: %s\n' "$SERVER_CPUS"
    printf '\n'

    while IFS='|' read -r sig label _; do
        [ -z "$sig" ] && continue
        paths=$(awk -F'\t' -v s="$sig" '$1==s {print $2}' "$HITS")
        if [ -n "$paths" ]; then
            printf '%s encontrado en este servidor\n' "$label"
            printf 'Ruta(s):\n%s\n' "$paths"
            if [ "$WITH_VERSIONS" = 1 ]; then
                first_path=$(printf '%s\n' "$paths" | head -n 1)
                v=$(version_probe "$sig" "$first_path")
                [ -n "$v" ] && printf 'Versión: %s\n' "$v"
            fi
            printf '\n'
        elif [ "$QUIET" != 1 ]; then
            :
        fi
    done <<EOF
$CATALOG
EOF
}

emit_tsv() {
    [ "$QUIET" = 1 ] || printf 'host\tips\tos\tcpus\tproduct\tsignature\tpath\tversion\n'
    while IFS='|' read -r sig label _; do
        [ -z "$sig" ] && continue
        awk -F'\t' -v s="$sig" '$1==s {print $2}' "$HITS" | while IFS= read -r p; do
            v=""
            [ "$WITH_VERSIONS" = 1 ] && v=$(version_probe "$sig" "$p")
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$SERVER_HOSTNAME" "$SERVER_IPS" "$SERVER_OS" "$SERVER_CPUS" \
                "$label" "$sig" "$p" "$v"
        done
    done <<EOF
$CATALOG
EOF
}

emit_json() {
    esc_host=$(json_escape "$SERVER_HOSTNAME")
    esc_ips=$(json_escape "$SERVER_IPS")
    esc_os=$(json_escape "$SERVER_OS")
    esc_cpus=$(json_escape "$SERVER_CPUS")

    printf '{\n'
    printf '  "server": {\n'
    printf '    "hostname": "%s",\n' "$esc_host"
    printf '    "ips": "%s",\n' "$esc_ips"
    printf '    "os": "%s",\n' "$esc_os"
    printf '    "cpus": "%s"\n' "$esc_cpus"
    printf '  },\n'
    printf '  "products": [\n'

    first_prod=1
    while IFS='|' read -r sig label _; do
        [ -z "$sig" ] && continue
        paths=$(awk -F'\t' -v s="$sig" '$1==s {print $2}' "$HITS")
        [ -z "$paths" ] && continue

        [ "$first_prod" = 0 ] && printf ',\n'
        first_prod=0

        v=""
        if [ "$WITH_VERSIONS" = 1 ]; then
            first_path=$(printf '%s\n' "$paths" | head -n 1)
            v=$(version_probe "$sig" "$first_path")
        fi

        esc_label=$(json_escape "$label")
        esc_sig=$(json_escape "$sig")
        esc_ver=$(json_escape "$v")

        printf '    {\n'
        printf '      "product": "%s",\n' "$esc_label"
        printf '      "signature": "%s",\n' "$esc_sig"
        printf '      "version": "%s",\n' "$esc_ver"
        printf '      "paths": ['

        first_p=1
        while IFS= read -r p; do
            [ "$first_p" = 0 ] && printf ', '
            first_p=0
            esc_path=$(json_escape "$p")
            printf '"%s"' "$esc_path"
        done <<EOF_PATHS
$paths
EOF_PATHS

        printf ']\n'
        printf '    }'
    done <<EOF
$CATALOG
EOF

    printf '\n  ]\n'
    printf '}\n'
}

case "$FORMAT" in
    human) emit_human ;;
    tsv)   emit_tsv ;;
    json)  emit_json ;;
esac

if [ -s "$HITS" ]; then
    exit 0
else
    exit 1
fi
