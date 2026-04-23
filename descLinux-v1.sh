#!/bin/sh
# descunix-v5.5.sh — Detecta productos IBM instalados en un host Unix/Linux.
# Mejoras de precisión sobre v5.4:
#   * evalúa cada ruta detectada como hallazgo independiente
#   * calcula nombre de producto, versión y certeza por ruta
#   * reduce errores cuando existen múltiples instalaciones del mismo producto
#   * agrega/refina detección conservadora para IBM BPM, IBM BAW y IBM ODM

set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
LC_ALL=C
export LC_ALL

PROG=${0##*/}
OUTPUT_FILE=./descunix-v5.5.txt
SEPARADOR='************************************************************'

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
c4gl|IBM Informix 4GL Compiler Development
r4gl|IBM Informix 4GL Compiler Runtime Option
fglgo|IBM Informix 4GL RDS Development
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
                *filegateway*|*FileGateway*|*b2bi*|*B2BI*|*gentran*|*Gentran*|*install/bin*)
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
    output=$(ejecutar_seguro 3 "$path" -V)
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

construir_resultados() {
    : > "$RESULTADOS"
    while IFS="$(printf '\t')" read -r sig path; do
        label=$(producto_desde_ruta "$sig" "$path")
        case "$sig" in
            oninit|dbaccess)     meta=$(probar_version_informix "$path") ;;
            db2level)            meta=$(probar_version_db2 "$path") ;;
            dmts64)              meta=$(probar_version_iidr "$path") ;;
            dspmq)               meta=$(probar_version_mq "$path") ;;
            wsadmin.sh)          meta=$(probar_version_was "$path") ;;
            mqsilist)            meta=$(probar_version_ace_iib "$path") ;;
            control.sh)          meta=$(probar_version_sterling_control "$path") ;;
            startSecureProxy.sh) meta=$(probar_version_secure_proxy) ;;
            BPMConfig.sh)        meta=$(probar_version_bpm "$path") ;;
            DecisionCenter.ear)  meta=$(probar_version_odm) ;;
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
    salida "$SEPARADOR"
    salida "Información del servidor"
    salida "$SEPARADOR"
    salida "Nombre del servidor: $SERVIDOR_NOMBRE"
    salida "IP(s): $SERVIDOR_IPS"
    salida "Sistema operativo: $SERVIDOR_SO"
    salida "Cores/vCPUs del servidor: $SERVIDOR_CPUS"
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

: > "$OUTPUT_FILE" 2>/dev/null || {
    printf '%s: no se pudo escribir el archivo de salida: %s\n' "$PROG" "$OUTPUT_FILE" >&2
    exit 2
}
OUTPUT_DEST=$OUTPUT_FILE

TMPDIR=${TMPDIR:-/tmp}
HALLAZGOS=$TMPDIR/descunix-v5.5.$$.hits
RESULTADOS=$TMPDIR/descunix-v5.5.$$.results
trap 'rm -f "$HALLAZGOS" "$RESULTADOS"' EXIT INT TERM
: > "$HALLAZGOS"
: > "$RESULTADOS"

recolectar_info_servidor

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
find / \( $prune_expr \) -prune -o \( $name_expr \) -type f -print 2>/dev/null | while IFS= read -r path; do
    sig=${path##*/}
    debe_conservarse "$sig" "$path" || continue
    printf '%s\t%s\n' "$sig" "$path" >> "$HALLAZGOS"
done

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
