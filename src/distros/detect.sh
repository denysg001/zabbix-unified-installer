# shellcheck shell=bash

# Distro detection and early platform requirements.
detect_distro() {
    local bash_major="${BASH_VERSINFO[0]:-0}"
    local bash_minor="${BASH_VERSINFO[1]:-0}"
    local missing=0 cmd

    if ((bash_major < 4 || (bash_major == 4 && bash_minor < 4))); then
        echo "ERRO: Bash 4.4+ é obrigatório para executar este instalador." >&2
        echo "Versão detectada: ${BASH_VERSION:-desconhecida}" >&2
        return 1
    fi

    if ! type -P curl >/dev/null 2>&1 && ! type -P wget >/dev/null 2>&1; then
        echo "ERRO: instale curl ou wget antes de executar o instalador." >&2
        missing=1
    fi

    for cmd in timeout mktemp systemctl; do
        if ! type -P "$cmd" >/dev/null 2>&1; then
            echo "ERRO: comando obrigatório ausente: ${cmd}" >&2
            missing=1
        fi
    done
    [[ "$missing" == "0" ]] || return 1

    if [[ ! -r /etc/os-release ]]; then
        echo "ERRO: /etc/os-release não encontrado; não foi possível detectar a distribuição." >&2
        return 1
    fi

    DISTRO_ID=$(awk -F= '$1=="ID"{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null || true)
    DISTRO_VERSION=$(awk -F= '$1=="VERSION_ID"{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null || true)
    DISTRO_CODENAME=$(awk -F= '$1=="VERSION_CODENAME"{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null || true)
    OS_PRETTY=$(awk -F= '$1=="PRETTY_NAME"{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null || true)

    U_VER="${DISTRO_VERSION}"
    U_CODENAME="${DISTRO_CODENAME}"
    # shellcheck disable=SC2034
    OS_ID="${DISTRO_ID}"

    case "$DISTRO_ID" in
    ubuntu)
        OS_FAMILY="ubuntu"
        OS_LABEL="Ubuntu"
        case "$DISTRO_VERSION" in
        20.04 | 22.04 | 24.04) ;;
        *)
            echo "ERRO: Ubuntu ${DISTRO_VERSION:-desconhecido} não é suportado nesta camada." >&2
            echo "Suportados agora: Ubuntu 20.04, 22.04 e 24.04." >&2
            echo "Para solicitar suporte, abra uma issue informando distro, versão e codename." >&2
            return 1
            ;;
        esac
        ;;
    *)
        OS_FAMILY="unsupported"
        OS_LABEL="${DISTRO_ID:-sistema desconhecido}"
        echo "ERRO: distribuição não suportada nesta camada: ${DISTRO_ID:-desconhecida} ${DISTRO_VERSION:-}." >&2
        echo "Suportadas agora: Ubuntu 20.04, 22.04 e 24.04." >&2
        echo "Para solicitar suporte, abra uma issue informando distro, versão, codename e componente desejado." >&2
        return 1
        ;;
    esac

    OS_DISPLAY="${OS_PRETTY:-${OS_LABEL} ${U_VER} (${U_CODENAME})}"

    RAM_MB=""
    if command -v free >/dev/null 2>&1; then
        RAM_MB=$(free -m 2>/dev/null | awk '/^Mem/{print $2}' || true)
    fi
    if [[ -z "${RAM_MB:-}" ]] && command -v sysctl >/dev/null 2>&1; then
        RAM_MB=$(($(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024))
    fi
    CPU_CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)

    SYS_TIMEZONE=$(timedatectl show --property=Timezone --value 2>/dev/null | awk 'NF{print; exit}' || true)
    if [[ -z "${SYS_TIMEZONE}" ]]; then
        SYS_TIMEZONE=$(cat /etc/timezone 2>/dev/null | tr -d '[:space:]' || true)
    fi
    [[ -z "${SYS_TIMEZONE}" ]] && SYS_TIMEZONE="America/Sao_Paulo"
}
