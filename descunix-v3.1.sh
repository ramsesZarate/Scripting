#!/bin/sh
# descunix-v3.1.sh — Detect installed IBM products on a Unix/Linux host.
# Focused update over v3 with:
#   * single filesystem pass per scan root
#   * optional targeted scan paths for faster runs
#   * optional extra exclude paths
#   * grouped results built once (less repeated awk work)
#   * cached version probes (one probe per found product)
#   * server metadata in all output formats

set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
LC_ALL=C
export LC_ALL

PROG=${0##*/}
NL='
'
PATH_SEP=$(printf '\034')

CATALOG='
oninit|Informix
dmts64|IIDR
wsadmin.sh|WAS
mqsilist|IIB / ACE
dspmq|MQ
control.sh|B2B / FileGateway
startSecureProxy.sh|Sterling Secure Proxy
dbaccess|Informix Client SDK
c4gl|Informix 4GL Compiler
r4gl|Informix 4GL Runtime
fglgo|Informix 4GL RDS
db2level|IBM Db2
imcl|IBM Installation Manager
dsmc|IBM Spectrum Protect
cogconfig.sh|IBM Cognos
collation.sh|IBM TADDM
startPortalServer.sh|WebSphere Portal
idsldapsearch|IBM Security Directory Server
datastage|InfoSphere DataStage
'

DEFAULT_PRUNE_PATHS='/proc /sys /dev /run /var/run /snap /mnt /media /cdrom /tmp/.mount_*'

FORMAT=human
QUIET=0
ONE_FS=0
WITH_VERSIONS=0
ROOT=/
SCAN_PATHS=
EXCLUDE_PATHS=

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
  --format=FMT            Formato de salida: human (default) | tsv | json
  --quiet                 Omitir encabezado TSV
  --one-fs                Limitar el barrido al filesystem raíz de cada scan root
  --with-versions         Intentar capturar versión de cada producto encontrado
  --root=PATH             Cambiar el punto de partida del barrido (default: /)
  --scan-paths=P1,P2      Escanear solo estas rutas (más rápido que barrer /)
  --exclude-paths=P1,P2   Excluir rutas adicionales del barrido
  --help                  Mostrar esta ayuda y salir
EOF
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

csv_to_words() {
    printf '%s' "$1" | tr ',' ' '
}

join_lines() {
    awk -v sep="$1" 'BEGIN { first=1 } {
        if (!first) {
            printf "%s", sep
        }
        printf "%s", $0
        first=0
    }'
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

label_for() {
    target=$1
    while IFS='|' read -r sig label; do
        [ -z "$sig" ] && continue
        [ "$sig" = "$target" ] && {
            printf '%s' "$label"
            return
        }
    done <<EOF
$CATALOG
EOF
}

safe_run() {
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
        wsadmin.sh) : ;;
        *)         : ;;
    esac
}

should_keep_hit() {
    sig=$1
    path=$2

    case "$sig" in
        control.sh)
            case "$path" in
                *install/bin*|*b2bi*|*gentran*) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        *)
            return 0
            ;;
    esac
}

run_find() {
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
$CATALOG
EOF

    prune_expr=""
    first=1
    all_prunes="$DEFAULT_PRUNE_PATHS"
    [ -n "$EXCLUDE_PATHS" ] && all_prunes="$all_prunes $(csv_to_words "$EXCLUDE_PATHS")"

    for p in $all_prunes; do
        if [ "$first" = 1 ]; then
            prune_expr="-path $p"
            first=0
        else
            prune_expr="$prune_expr -o -path $p"
        fi
    done

    xdev_flag=""
    [ "$ONE_FS" = 1 ] && xdev_flag="-xdev"

    roots=$ROOT
    [ -n "$SCAN_PATHS" ] && roots=$(csv_to_words "$SCAN_PATHS")

    for scan_root in $roots; do
        [ -d "$scan_root" ] || continue
        # shellcheck disable=SC2086
        find "$scan_root" $xdev_flag \( $prune_expr \) -prune -o \
            \( $name_expr \) -type f -print 2>/dev/null
    done
}

build_groups() {
    awk -F '\t' -v sep="$PATH_SEP" '
        {
            if (!(seen[$1]++)) {
                order[++count] = $1
            }
            if ($1 in paths) {
                paths[$1] = paths[$1] sep $2
            } else {
                paths[$1] = $2
            }
        }
        END {
            for (i = 1; i <= count; i++) {
                sig = order[i]
                print sig "\t" paths[sig]
            }
        }
    ' "$HITS" > "$GROUPS"
}

build_versions() {
    : > "$VERSIONS"
    [ "$WITH_VERSIONS" = 1 ] || return

    while IFS="$(printf '\t')" read -r sig joined_paths; do
        first_path=${joined_paths%%"$PATH_SEP"*}
        version=$(version_probe "$sig" "$first_path")
        printf '%s\t%s\n' "$sig" "$version" >> "$VERSIONS"
    done < "$GROUPS"
}

version_for() {
    sig=$1
    awk -F '\t' -v s="$sig" '$1==s {print $2; exit}' "$VERSIONS"
}

print_server_block() {
    printf 'Información del servidor\n'
    printf 'Nombre del servidor: %s\n' "$SERVER_HOSTNAME"
    printf 'IP(s): %s\n' "$SERVER_IPS"
    printf 'Sistema operativo: %s\n' "$SERVER_OS"
    printf 'Cores/vCPUs del servidor: %s\n' "$SERVER_CPUS"
    printf '\n'
}

emit_human() {
    print_server_block

    while IFS="$(printf '\t')" read -r sig joined_paths; do
        label=$(label_for "$sig")
        printf '%s encontrado en este servidor\n' "$label"
        printf 'Ruta(s):\n'
        printf '%s' "$joined_paths" | tr "$PATH_SEP" '\n'
        printf '\n'

        if [ "$WITH_VERSIONS" = 1 ]; then
            v=$(version_for "$sig")
            [ -n "$v" ] && printf 'Versión: %s\n\n' "$v"
        else
            printf '\n'
        fi
    done < "$GROUPS"
}

emit_tsv() {
    [ "$QUIET" = 1 ] || printf 'host\tips\tos\tcpus\tproduct\tsignature\tpath\tversion\n'

    while IFS="$(printf '\t')" read -r sig joined_paths; do
        label=$(label_for "$sig")
        v=$(version_for "$sig")

        printf '%s' "$joined_paths" | tr "$PATH_SEP" '\n' | while IFS= read -r p; do
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$SERVER_HOSTNAME" "$SERVER_IPS" "$SERVER_OS" "$SERVER_CPUS" \
                "$label" "$sig" "$p" "$v"
        done
    done < "$GROUPS"
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
    while IFS="$(printf '\t')" read -r sig joined_paths; do
        label=$(label_for "$sig")
        v=$(version_for "$sig")
        esc_label=$(json_escape "$label")
        esc_sig=$(json_escape "$sig")
        esc_ver=$(json_escape "$v")

        [ "$first_prod" = 0 ] && printf ',\n'
        first_prod=0

        printf '    {\n'
        printf '      "product": "%s",\n' "$esc_label"
        printf '      "signature": "%s",\n' "$esc_sig"
        printf '      "version": "%s",\n' "$esc_ver"
        printf '      "paths": ['

        first_path=1
        joined_lines=$(printf '%s' "$joined_paths" | tr "$PATH_SEP" '\n')
        while IFS= read -r p; do
            esc_path=$(json_escape "$p")
            if [ "$first_path" = 0 ]; then
                printf ', '
            fi
            first_path=0
            printf '"%s"' "$esc_path"
        done <<EOF
$joined_lines
EOF

        printf ']\n'
        printf '    }'
    done < "$GROUPS"

    printf '\n  ]\n'
    printf '}\n'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --format=*)        FORMAT=${1#--format=} ;;
        --format)          shift; FORMAT=${1:-} ;;
        --quiet|-q)        QUIET=1 ;;
        --one-fs)          ONE_FS=1 ;;
        --with-versions)   WITH_VERSIONS=1 ;;
        --root=*)          ROOT=${1#--root=} ;;
        --root)            shift; ROOT=${1:-} ;;
        --scan-paths=*)    SCAN_PATHS=${1#--scan-paths=} ;;
        --scan-paths)      shift; SCAN_PATHS=${1:-} ;;
        --exclude-paths=*) EXCLUDE_PATHS=${1#--exclude-paths=} ;;
        --exclude-paths)   shift; EXCLUDE_PATHS=${1:-} ;;
        -h|--help)         usage; exit 0 ;;
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

if [ -n "$SCAN_PATHS" ]; then
    for scan_root in $(csv_to_words "$SCAN_PATHS"); do
        if [ ! -d "$scan_root" ]; then
            printf '%s: --scan-paths incluye una ruta no válida: %s\n' "$PROG" "$scan_root" >&2
            exit 2
        fi
    done
elif [ ! -d "$ROOT" ]; then
    printf '%s: --root no es un directorio: %s\n' "$PROG" "$ROOT" >&2
    exit 2
fi

TMPDIR=${TMPDIR:-/tmp}
HITS=$TMPDIR/descunix-v3.1.$$.hits
GROUPS=$TMPDIR/descunix-v3.1.$$.groups
VERSIONS=$TMPDIR/descunix-v3.1.$$.versions
trap 'rm -f "$HITS" "$GROUPS" "$VERSIONS"' EXIT INT TERM
: > "$HITS"
: > "$GROUPS"
: > "$VERSIONS"

collect_server_info

run_find | while IFS= read -r path; do
    sig=${path##*/}
    should_keep_hit "$sig" "$path" || continue
    printf '%s\t%s\n' "$sig" "$path" >> "$HITS"
done

if [ -s "$HITS" ]; then
    build_groups
    build_versions
fi

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
