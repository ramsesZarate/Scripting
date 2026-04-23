#!/bin/sh
# descunix-v4.sh — Detecta productos IBM instalados en un host Unix/Linux.
# Version 4:
#   * salida en español para el usuario
#   * versionado con nivel de certeza para Informix, Db2 e IIDR

set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
LC_ALL=C
export LC_ALL

PROG=${0##*/}
PATH_SEP=$(printf '\034')

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

RUTAS_EXCLUIDAS_PREDETERMINADAS='/proc /sys /dev /run /var/run /snap /mnt /media /cdrom /tmp/.mount_*'

FORMATO=human
SILENCIOSO=0
UN_SOLO_FS=0
CON_VERSIONES=0
RAIZ=/
RUTAS_ESCANEO=
RUTAS_EXCLUIDAS=

SERVIDOR_NOMBRE=desconocido
SERVIDOR_IPS=desconocido
SERVIDOR_SO=desconocido
SERVIDOR_CPUS=desconocido

uso() {
    cat <<EOF
$PROG — detecta productos IBM instalados recorriendo el filesystem.

Uso:
  $PROG [opciones]

Opciones:
  --format=FMT            Formato de salida: human (default) | tsv | json
  --quiet                 Omitir encabezado TSV
  --one-fs                Limitar el barrido al filesystem raíz de cada ruta
  --with-versions         Intentar capturar versión con nivel de certeza
  --root=PATH             Cambiar el punto de partida del barrido (default: /)
  --scan-paths=P1,P2      Escanear solo estas rutas
  --exclude-paths=P1,P2   Excluir rutas adicionales del barrido
  --help                  Mostrar esta ayuda y salir
EOF
}

escapar_json() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

csv_a_palabras() {
    printf '%s' "$1" | tr ',' ' '
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
        timeout "${t}s" "$@" 2>&1 | head -n 20
    else
        "$@" 2>&1 | head -n 20
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
    '
}

extraer_version_db2() {
    awk '
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
        *)
            :
            ;;
    esac
}

ejecutar_como_propietario() {
    owner=$1
    cmd=$2

    if [ -z "$owner" ]; then
        return 1
    fi

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

    if [ -x "$tool" ]; then
        if [ -n "$owner" ]; then
            output=$(ejecutar_como_propietario "$owner" "$tool")
            version=$(printf '%s\n' "$output" | extraer_version_iidr)
            if [ -n "$version" ]; then
                registrar_version "$sig" "$version" "CONFIRMADA" "dmshowversion como $owner" ""
                return
            fi
        fi

        output=$(ejecutar_seguro 5 "$tool")
        version=$(printf '%s\n' "$output" | extraer_version_iidr)
        if [ -n "$version" ]; then
            registrar_version "$sig" "$version" "CONFIRMADA" "$tool" ""
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

probar_version() {
    sig=$1
    path=$2

    case "$sig" in
        oninit|dbaccess) probar_version_informix "$sig" "$path" ;;
        db2level)        probar_version_db2 "$sig" "$path" ;;
        dmts64)          probar_version_iidr "$sig" "$path" ;;
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
    todas_las_podas="$RUTAS_EXCLUIDAS_PREDETERMINADAS"
    [ -n "$RUTAS_EXCLUIDAS" ] && todas_las_podas="$todas_las_podas $(csv_a_palabras "$RUTAS_EXCLUIDAS")"

    for p in $todas_las_podas; do
        if [ "$first" = 1 ]; then
            expr_poda="-path $p"
            first=0
        else
            expr_poda="$expr_poda -o -path $p"
        fi
    done

    bandera_xdev=""
    [ "$UN_SOLO_FS" = 1 ] && bandera_xdev="-xdev"

    roots=$RAIZ
    [ -n "$RUTAS_ESCANEO" ] && roots=$(csv_a_palabras "$RUTAS_ESCANEO")

    for scan_root in $roots; do
        [ -d "$scan_root" ] || continue
        # shellcheck disable=SC2086
        find "$scan_root" $bandera_xdev \( $expr_poda \) -prune -o \
            \( $expr_nombres \) -type f -print 2>/dev/null
    done
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
    [ "$CON_VERSIONES" = 1 ] || return

    while IFS="$(printf '\t')" read -r sig joined_paths; do
        first_path=${joined_paths%%"$PATH_SEP"*}
        probar_version "$sig" "$first_path"
    done < "$GRUPOS"
}

imprimir_bloque_servidor() {
    printf 'Información del servidor\n'
    printf 'Nombre del servidor: %s\n' "$SERVIDOR_NOMBRE"
    printf 'IP(s): %s\n' "$SERVIDOR_IPS"
    printf 'Sistema operativo: %s\n' "$SERVIDOR_SO"
    printf 'Cores/vCPUs del servidor: %s\n' "$SERVIDOR_CPUS"
    printf '\n'
}

emitir_human() {
    imprimir_bloque_servidor

    while IFS="$(printf '\t')" read -r sig joined_paths; do
        label=$(etiqueta_para "$sig")
        printf '%s encontrado en este servidor\n' "$label"
        printf 'Ruta(s):\n'
        printf '%s' "$joined_paths" | tr "$PATH_SEP" '\n'
        printf '\n'

        if [ "$CON_VERSIONES" = 1 ]; then
            version=$(campo_version_para "$sig" 2)
            estado=$(campo_version_para "$sig" 3)
            metodo=$(campo_version_para "$sig" 4)
            nota=$(campo_version_para "$sig" 5)
            [ -n "$version" ] && printf 'Versión: %s\n' "$version"
            [ -n "$estado" ] && printf 'Estado de versión: %s\n' "$estado"
            [ -n "$metodo" ] && printf 'Método de versión: %s\n' "$metodo"
            [ -n "$nota" ] && printf 'Nota de versión: %s\n' "$nota"
            printf '\n'
        else
            printf '\n'
        fi
    done < "$GRUPOS"
}

emitir_tsv() {
    [ "$SILENCIOSO" = 1 ] || printf 'servidor\tips\tsistema_operativo\tcpus\tproducto\tfirma\truta\tversion\testado_version\tmetodo_version\tnota_version\n'

    while IFS="$(printf '\t')" read -r sig joined_paths; do
        label=$(etiqueta_para "$sig")
        version=$(campo_version_para "$sig" 2)
        estado=$(campo_version_para "$sig" 3)
        metodo=$(campo_version_para "$sig" 4)
        nota=$(campo_version_para "$sig" 5)

        printf '%s' "$joined_paths" | tr "$PATH_SEP" '\n' | while IFS= read -r p; do
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$SERVIDOR_NOMBRE" "$SERVIDOR_IPS" "$SERVIDOR_SO" "$SERVIDOR_CPUS" \
                "$label" "$sig" "$p" "$version" "$estado" "$metodo" "$nota"
        done
    done < "$GRUPOS"
}

emitir_json() {
    esc_host=$(escapar_json "$SERVIDOR_NOMBRE")
    esc_ips=$(escapar_json "$SERVIDOR_IPS")
    esc_so=$(escapar_json "$SERVIDOR_SO")
    esc_cpus=$(escapar_json "$SERVIDOR_CPUS")

    printf '{\n'
    printf '  "servidor": {\n'
    printf '    "nombre": "%s",\n' "$esc_host"
    printf '    "ips": "%s",\n' "$esc_ips"
    printf '    "sistema_operativo": "%s",\n' "$esc_so"
    printf '    "cpus": "%s"\n' "$esc_cpus"
    printf '  },\n'
    printf '  "productos": [\n'

    first_prod=1
    while IFS="$(printf '\t')" read -r sig joined_paths; do
        label=$(etiqueta_para "$sig")
        version=$(campo_version_para "$sig" 2)
        estado=$(campo_version_para "$sig" 3)
        metodo=$(campo_version_para "$sig" 4)
        nota=$(campo_version_para "$sig" 5)

        [ "$first_prod" = 0 ] && printf ',\n'
        first_prod=0

        printf '    {\n'
        printf '      "producto": "%s",\n' "$(escapar_json "$label")"
        printf '      "firma": "%s",\n' "$(escapar_json "$sig")"
        printf '      "version": "%s",\n' "$(escapar_json "$version")"
        printf '      "estado_version": "%s",\n' "$(escapar_json "$estado")"
        printf '      "metodo_version": "%s",\n' "$(escapar_json "$metodo")"
        printf '      "nota_version": "%s",\n' "$(escapar_json "$nota")"
        printf '      "rutas": ['

        first_path=1
        joined_lines=$(printf '%s' "$joined_paths" | tr "$PATH_SEP" '\n')
        while IFS= read -r p; do
            [ "$first_path" = 0 ] && printf ', '
            first_path=0
            printf '"%s"' "$(escapar_json "$p")"
        done <<EOF_RUTAS
$joined_lines
EOF_RUTAS

        printf ']\n'
        printf '    }'
    done < "$GRUPOS"

    printf '\n  ]\n'
    printf '}\n'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --format=*)        FORMATO=${1#--format=} ;;
        --format)          shift; FORMATO=${1:-} ;;
        --quiet|-q)        SILENCIOSO=1 ;;
        --one-fs)          UN_SOLO_FS=1 ;;
        --with-versions)   CON_VERSIONES=1 ;;
        --root=*)          RAIZ=${1#--root=} ;;
        --root)            shift; RAIZ=${1:-} ;;
        --scan-paths=*)    RUTAS_ESCANEO=${1#--scan-paths=} ;;
        --scan-paths)      shift; RUTAS_ESCANEO=${1:-} ;;
        --exclude-paths=*) RUTAS_EXCLUIDAS=${1#--exclude-paths=} ;;
        --exclude-paths)   shift; RUTAS_EXCLUIDAS=${1:-} ;;
        -h|--help)         uso; exit 0 ;;
        *)
            printf '%s: opción desconocida: %s\n' "$PROG" "$1" >&2
            uso >&2
            exit 2
            ;;
    esac
    shift
done

case "$FORMATO" in
    human|tsv|json) ;;
    *)
        printf '%s: --format debe ser human|tsv|json (recibido: %s)\n' "$PROG" "$FORMATO" >&2
        exit 2
        ;;
esac

if [ -n "$RUTAS_ESCANEO" ]; then
    for scan_root in $(csv_a_palabras "$RUTAS_ESCANEO"); do
        if [ ! -d "$scan_root" ]; then
            printf '%s: --scan-paths incluye una ruta no válida: %s\n' "$PROG" "$scan_root" >&2
            exit 2
        fi
    done
elif [ ! -d "$RAIZ" ]; then
    printf '%s: --root no es un directorio: %s\n' "$PROG" "$RAIZ" >&2
    exit 2
fi

TMPDIR=${TMPDIR:-/tmp}
HALLAZGOS=$TMPDIR/descunix-v4.$$.hits
GRUPOS=$TMPDIR/descunix-v4.$$.groups
VERSIONES=$TMPDIR/descunix-v4.$$.versions
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

case "$FORMATO" in
    human) emitir_human ;;
    tsv)   emitir_tsv ;;
    json)  emitir_json ;;
esac

if [ -s "$HALLAZGOS" ]; then
    exit 0
else
    exit 1
fi
