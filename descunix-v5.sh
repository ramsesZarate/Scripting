#!/bin/sh
# descunix-v5.sh — Detecta productos IBM instalados en un host Unix/Linux.
# Comportamiento por defecto:
#   * busca productos IBM
#   * muestra información del servidor
#   * intenta obtener versión
#   * reporta si la versión es CONFIRMADA, INFERIDA, BLOQUEADA o NO_DISPONIBLE
# Además:
#   * genera automáticamente un archivo .txt en el directorio actual
#   * reemplaza el archivo si ya existe
#   * refina parseos para Informix, Db2, IIDR, MQ, WAS y ACE / IIB

set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
LC_ALL=C
export LC_ALL

PROG=${0##*/}
PATH_SEP=$(printf '\034')
OUTPUT_FILE=./descunix-v5.txt

CATALOGO='
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

etiqueta_para() {
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
    t=$1
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "${t}s" "$@" 2>&1 | head -n 60
    else
        "$@" 2>&1 | head -n 60
    fi
}

propietario_de_ruta() {
    ls -ld "$1" 2>/dev/null | awk 'NR==1 {print $3}'
}

extraer_version_informix() {
    awk '
        /IBM Informix Dynamic Server Version/ {
            sub(/^.*Version /, "", $0)
            gsub(/^[[:space:]]+/, "", $0)
            print
            exit
        }
        /Version/ && !/No such file|no such directory|errno|locale|Unable/ {
            sub(/^.*Version[[:space:]]+/, "", $0)
            gsub(/^[[:space:]]+/, "", $0)
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
        /^Version/ && /[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?/ && !/Java|SDK|JVM/ {
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

version_desde_ruta() {
    sig=$1
    path=$2
    case "$sig" in
        db2level)
            printf '%s\n' "$path" | awk '
                match($0, /\/V[0-9.]+\//) {
                    v=substr($0, RSTART + 2, RLENGTH - 3)
                    print v
                    exit
                }
            '
            ;;
        oninit|dbaccess)
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

registrar_version() {
    sig=$1
    version=$2
    estado=$3
    metodo=$4
    nota=$5
    printf '%s\t%s\t%s\t%s\t%s\n' "$sig" "$version" "$estado" "$metodo" "$nota" >> "$VERSIONES"
}

probar_version_informix() {
    sig=$1
    path=$2

    output=$(ejecutar_seguro 3 "$path" -V)
    version=$(printf '%s\n' "$output" | extraer_version_informix)
    if [ -n "$version" ]; then
        registrar_version "$sig" "$version" "CONFIRMADA" "$path -V" ""
        return
    fi

    inferida=$(version_desde_ruta "$sig" "$path")
    if [ -n "$inferida" ]; then
        registrar_version "$sig" "$inferida" "INFERIDA" "ruta de instalación" "El comando oficial no devolvió una versión interpretable"
        return
    fi

    registrar_version "$sig" "" "NO_DISPONIBLE" "ninguno" "No fue posible determinar la versión"
}

probar_version_db2() {
    sig=$1
    path=$2
    owner=$(propietario_de_ruta "$path")
    output=""
    version=""

    if [ -n "$owner" ]; then
        output=$(ejecutar_como_propietario "$owner" "$path")
        version=$(printf '%s\n' "$output" | extraer_version_db2)
        if [ -n "$version" ]; then
            registrar_version "$sig" "$version" "CONFIRMADA" "db2level como $owner" ""
            return
        fi
    fi

    output=$(ejecutar_seguro 3 "$path")
    version=$(printf '%s\n' "$output" | extraer_version_db2)
    if [ -n "$version" ]; then
        registrar_version "$sig" "$version" "CONFIRMADA" "$path" ""
        return
    fi

    inferida=$(version_desde_ruta "$sig" "$path")
    if [ -n "$inferida" ]; then
        nota="db2level no devolvió una versión utilizable"
        [ -n "$owner" ] && nota="$nota; propietario=$owner"
        registrar_version "$sig" "$inferida" "INFERIDA" "ruta de instalación" "$nota"
        return
    fi

    registrar_version "$sig" "" "NO_DISPONIBLE" "ninguno" "No fue posible determinar la versión"
}

probar_version_iidr() {
    sig=$1
    path=$2
    base_dir=${path%/bin/dmts64}
    tool=$base_dir/bin/dmshowversion
    owner=$(propietario_de_ruta "$path")
    output=""
    version=""
    build=""

    if [ -x "$tool" ]; then
        if [ -n "$owner" ]; then
            output=$(ejecutar_como_propietario "$owner" "$tool")
            version=$(printf '%s\n' "$output" | extraer_version_iidr)
            if [ -n "$version" ]; then
                build=$(printf '%s\n' "$output" | extraer_build_iidr)
                nota=""
                [ -n "$build" ] && nota="Build: $build"
                registrar_version "$sig" "$version" "CONFIRMADA" "dmshowversion como $owner" "$nota"
                return
            fi
        fi

        output=$(ejecutar_seguro 5 "$tool")
        version=$(printf '%s\n' "$output" | extraer_version_iidr)
        if [ -n "$version" ]; then
            build=$(printf '%s\n' "$output" | extraer_build_iidr)
            nota=""
            [ -n "$build" ] && nota="Build: $build"
            registrar_version "$sig" "$version" "CONFIRMADA" "$tool" "$nota"
            return
        fi
    fi

    output=$(ejecutar_seguro 3 "$path" -version)
    if printf '%s\n' "$output" | grep -qi 'cannot be run as root'; then
        nota="dmts64 no puede ejecutarse como root"
        [ -n "$owner" ] && nota="$nota; propietario=$owner"
        registrar_version "$sig" "" "BLOQUEADA" "dmts64 -version" "$nota"
        return
    fi

    registrar_version "$sig" "" "NO_DISPONIBLE" "ninguno" "No fue posible determinar la versión"
}

probar_version_mq() {
    sig=$1
    path=$2
    bin_dir=${path%/dspmq}
    tool=$bin_dir/dspmqver
    output=""
    version=""

    if [ -x "$tool" ]; then
        output=$(ejecutar_seguro 3 "$tool" -b)
        version=$(printf '%s\n' "$output" | extraer_version_mq)
        if [ -n "$version" ]; then
            registrar_version "$sig" "$version" "CONFIRMADA" "$tool -b" ""
            return
        fi

        output=$(ejecutar_seguro 3 "$tool")
        version=$(printf '%s\n' "$output" | extraer_version_mq)
        if [ -n "$version" ]; then
            registrar_version "$sig" "$version" "CONFIRMADA" "$tool" ""
            return
        fi
    fi

    if command -v dspmqver >/dev/null 2>&1; then
        output=$(ejecutar_seguro 3 dspmqver -b)
        version=$(printf '%s\n' "$output" | extraer_version_mq)
        if [ -n "$version" ]; then
            registrar_version "$sig" "$version" "CONFIRMADA" "dspmqver -b" ""
            return
        fi

        output=$(ejecutar_seguro 3 dspmqver)
        version=$(printf '%s\n' "$output" | extraer_version_mq)
        if [ -n "$version" ]; then
            registrar_version "$sig" "$version" "CONFIRMADA" "dspmqver" ""
            return
        fi
    fi

    registrar_version "$sig" "" "NO_DISPONIBLE" "ninguno" "No fue posible determinar la versión"
}

probar_version_was() {
    sig=$1
    path=$2
    bin_dir=${path%/wsadmin.sh}
    tool=$bin_dir/versionInfo.sh
    output=""
    version=""

    if [ -x "$tool" ]; then
        output=$(ejecutar_seguro 10 "$tool")
        version=$(printf '%s\n' "$output" | extraer_version_was)
        if [ -n "$version" ]; then
            registrar_version "$sig" "$version" "CONFIRMADA" "$tool" ""
            return
        fi

        if printf '%s\n' "$output" | grep -qiE 'permission denied|not permitted|cannot|failed|error'; then
            registrar_version "$sig" "" "BLOQUEADA" "$tool" "versionInfo.sh devolvió un error o requirió entorno adicional"
            return
        fi
    fi

    registrar_version "$sig" "" "NO_DISPONIBLE" "ninguno" "No fue posible determinar la versión"
}

probar_version_ace_iib() {
    sig=$1
    path=$2
    bin_dir=${path%/mqsilist}
    tool=$bin_dir/mqsiversion
    profile=$bin_dir/mqsiprofile
    output=""
    version=""

    if [ -x "$tool" ]; then
        output=$(ejecutar_seguro 5 "$tool")
        version=$(printf '%s\n' "$output" | extraer_version_ace_iib)
        if [ -n "$version" ]; then
            registrar_version "$sig" "$version" "CONFIRMADA" "$tool" ""
            return
        fi
    fi

    if [ -x "$profile" ] && [ -x "$tool" ]; then
        output=$(sh -c ". \"$profile\" >/dev/null 2>&1; \"$tool\"" 2>&1 | head -n 60)
        version=$(printf '%s\n' "$output" | extraer_version_ace_iib)
        if [ -n "$version" ]; then
            registrar_version "$sig" "$version" "CONFIRMADA" "mqsiprofile + mqsiversion" ""
            return
        fi
        if printf '%s\n' "$output" | grep -qiE 'permission denied|not permitted|cannot|failed|error'; then
            registrar_version "$sig" "" "BLOQUEADA" "mqsiprofile + mqsiversion" "La consulta de versión requirió entorno o permisos adicionales"
            return
        fi
    fi

    inferida=$(version_desde_ruta "$sig" "$path")
    if [ -n "$inferida" ]; then
        registrar_version "$sig" "$inferida" "INFERIDA" "ruta de instalación" "La versión se infirió desde la ruta detectada"
        return
    fi

    registrar_version "$sig" "" "NO_DISPONIBLE" "ninguno" "No fue posible determinar la versión"
}

probar_version() {
    sig=$1
    path=$2

    case "$sig" in
        oninit|dbaccess) probar_version_informix "$sig" "$path" ;;
        db2level)        probar_version_db2 "$sig" "$path" ;;
        dmts64)          probar_version_iidr "$sig" "$path" ;;
        dspmq)           probar_version_mq "$sig" "$path" ;;
        wsadmin.sh)      probar_version_was "$sig" "$path" ;;
        mqsilist)        probar_version_ace_iib "$sig" "$path" ;;
        *)
            registrar_version "$sig" "" "NO_DISPONIBLE" "no implementado" "La obtención de versión no está implementada para este producto"
            ;;
    esac
}

campo_version_para() {
    sig=$1
    col=$2
    awk -F '\t' -v s="$sig" -v c="$col" '$1==s {print $c; exit}' "$VERSIONES"
}

debe_conservarse() {
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

ejecutar_find() {
    expr_nombres=""
    first=1
    while IFS='|' read -r sig _; do
        [ -z "$sig" ] && continue
        if [ "$first" = 1 ]; then
            expr_nombres="-name $sig"
            first=0
        else
            expr_nombres="$expr_nombres -o -name $sig"
        fi
    done <<EOF
$CATALOGO
EOF

    expr_poda=""
    first=1
    for p in $RUTAS_EXCLUIDAS; do
        if [ "$first" = 1 ]; then
            expr_poda="-path $p"
            first=0
        else
            expr_poda="$expr_poda -o -path $p"
        fi
    done

    # shellcheck disable=SC2086
    find / \( $expr_poda \) -prune -o \( $expr_nombres \) -type f -print 2>/dev/null
}

construir_grupos() {
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
    ' "$HALLAZGOS" > "$GRUPOS"
}

construir_versiones() {
    : > "$VERSIONES"
    while IFS="$(printf '\t')" read -r sig joined_paths; do
        first_path=${joined_paths%%"$PATH_SEP"*}
        probar_version "$sig" "$first_path"
    done < "$GRUPOS"
}

imprimir_bloque_servidor() {
    salida "Información del servidor"
    salida "Nombre del servidor: $SERVIDOR_NOMBRE"
    salida "IP(s): $SERVIDOR_IPS"
    salida "Sistema operativo: $SERVIDOR_SO"
    salida "Cores/vCPUs del servidor: $SERVIDOR_CPUS"
    salida ""
}

emitir_reporte() {
    imprimir_bloque_servidor

    while IFS="$(printf '\t')" read -r sig joined_paths; do
        label=$(etiqueta_para "$sig")
        version=$(campo_version_para "$sig" 2)
        estado=$(campo_version_para "$sig" 3)
        metodo=$(campo_version_para "$sig" 4)
        nota=$(campo_version_para "$sig" 5)

        salida "$label encontrado en este servidor"
        salida "Ruta(s):"
        printf '%s' "$joined_paths" | tr "$PATH_SEP" '\n' >> "$OUTPUT_DEST"
        salida ""
        [ -n "$version" ] && salida "Versión: $version"
        [ -n "$estado" ] && salida "Estado de versión: $estado"
        [ -n "$metodo" ] && salida "Método de versión: $metodo"
        [ -n "$nota" ] && salida "Nota de versión: $nota"
        salida ""
    done < "$GRUPOS"
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

: > "$OUTPUT_FILE" 2>/dev/null || {
    printf '%s: no se pudo escribir el archivo de salida: %s\n' "$PROG" "$OUTPUT_FILE" >&2
    exit 2
}
OUTPUT_DEST=$OUTPUT_FILE

TMPDIR=${TMPDIR:-/tmp}
HALLAZGOS=$TMPDIR/descunix-v5.$$.hits
GRUPOS=$TMPDIR/descunix-v5.$$.groups
VERSIONES=$TMPDIR/descunix-v5.$$.versions
trap 'rm -f "$HALLAZGOS" "$GRUPOS" "$VERSIONES"' EXIT INT TERM
: > "$HALLAZGOS"
: > "$GRUPOS"
: > "$VERSIONES"

recolectar_info_servidor

ejecutar_find | while IFS= read -r path; do
    sig=${path##*/}
    debe_conservarse "$sig" "$path" || continue
    printf '%s\t%s\n' "$sig" "$path" >> "$HALLAZGOS"
done

if [ -s "$HALLAZGOS" ]; then
    construir_grupos
    construir_versiones
fi

emitir_reporte

cat "$OUTPUT_FILE"

if [ -s "$HALLAZGOS" ]; then
    exit 0
else
    exit 1
fi
