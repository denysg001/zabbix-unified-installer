# shellcheck shell=bash

# Shared input, repository, package, OS, and compatibility validation helpers.
validate_timezone_name() {
    local tz="$1"
    [[ -n "$tz" ]] || return 1
    [[ "$tz" == *".."* || "$tz" == /* ]] && return 1
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl list-timezones 2>/dev/null | grep -Fx -- "$tz" >/dev/null 2>&1 && return 0
    fi
    [[ "$tz" == "UTC" ]] && return 0
    [[ -f "/usr/share/zoneinfo/${tz}" ]]
}
validate_identifier() {
    local value="$1" label="$2"
    if [[ ! "$value" =~ ^[a-zA-Z_][a-zA-Z0-9_]{0,62}$ ]]; then
        echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} ${label} inválido: ${value}"
        echo -e "  Use apenas letras, números e underline. Deve começar com letra ou underline."
        exit 1
    fi
}
validate_port() {
    local port="$1"
    if [[ ! "$port" =~ ^[0-9]+$ || "$port" -lt 1 || "$port" -gt 65535 ]]; then
        echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} Porta inválida: ${port}"
        exit 1
    fi
}
validate_size() {
    local value="$1" label="$2"
    if [[ ! "$value" =~ ^[0-9]+[KkMmGg]?$ ]]; then
        echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} ${label} inválido: ${value}"
        echo -e "  Exemplos válidos: 32M, 128M, 1G ou 300"
        exit 1
    fi
}
validate_int_range() {
    local value="$1" label="$2" min="$3" max="$4"
    if [[ ! "$value" =~ ^[0-9]+$ || "$value" -lt "$min" || "$value" -gt "$max" ]]; then
        echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} ${label} inválido: ${value}"
        echo -e "  Valor permitido: ${min}–${max}"
        exit 1
    fi
}
validate_decimal_range() {
    local value="$1" label="$2" min="$3" max="$4"
    if [[ ! "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} ${label} inválido: ${value}"
        echo -e "  Use número decimal com ponto, exemplo: 0.9 ou 1.1"
        exit 1
    fi
    awk -v v="$value" -v min="$min" -v max="$max" 'BEGIN { exit !(v >= min && v <= max) }' || {
        echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} ${label} fora do intervalo: ${value}"
        echo -e "  Valor permitido: ${min}–${max}"
        exit 1
    }
}
validate_zero_or_int_range() {
    local value="$1" label="$2" min="$3" max="$4"
    if [[ "$value" == "0" ]]; then
        return 0
    fi
    validate_int_range "$value" "$label" "$min" "$max"
}
validate_nonblank_no_control() {
    local value="$1" label="$2"
    if [[ -z "$value" || "$value" =~ [[:cntrl:]] ]]; then
        echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} ${label} inválido."
        echo -e "  Não pode estar vazio nem conter caracteres de controlo."
        exit 1
    fi
}
validate_zabbix_identity() {
    local value="$1" label="$2"
    validate_nonblank_no_control "$value" "$label"
    if [[ "$value" =~ ^[[:space:]]|[[:space:]]$ ]]; then
        echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} ${label} inválido: espaços no início ou fim."
        exit 1
    fi
}
local_ipv4_addresses() {
    {
        hostname -I 2>/dev/null | tr ' ' '\n' || true
        if command -v ip >/dev/null 2>&1; then
            ip -o -4 addr show scope global 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4}' || true
        fi
        primary_ipv4 2>/dev/null || true
    } | awk '/^([0-9]{1,3}\.){3}[0-9]{1,3}$/ && !seen[$0]++'
}
is_local_ipv4_address() {
    local host="$1" local_ip
    [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    for local_ip in $(local_ipv4_addresses); do
        [[ "$host" == "$local_ip" ]] && return 0
    done
    return 1
}
is_forbidden_active_proxy_target() {
    local host="$1" resolved_ip
    host="${host#[}"
    host="${host%]}"
    case "$host" in
    0 | 0.0.0.0 | :: | ::1 | localhost | localhost.localdomain)
        return 0
        ;;
    esac
    [[ "$host" =~ ^127\. ]] && return 0
    is_local_ipv4_address "$host" && return 0

    if command -v getent >/dev/null 2>&1; then
        while read -r resolved_ip; do
            [[ "$resolved_ip" =~ ^127\. ]] && return 0
            is_local_ipv4_address "$resolved_ip" && return 0
        done < <(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u)
    fi
    return 1
}
first_endpoint_host() {
    local value="$1" entry host
    value="${value//;/ }"
    value="${value//,/ }"
    for entry in $value; do
        entry="${entry//[[:space:]]/}"
        [[ -z "$entry" ]] && continue
        host="$entry"
        if [[ "$entry" == *":"* && "$entry" != *"]"* ]]; then
            host="${entry%:*}"
        fi
        host="${host#[}"
        host="${host%]}"
        printf '%s' "$host"
        return 0
    done
    return 1
}
validate_proxy_server_value() {
    local value="$1" mode="$2" label="${3:-Server do Proxy}"
    local server_list entry host port

    if [[ -z "$value" || "$value" =~ [[:cntrl:]] || "$value" =~ ^[[:space:]]|[[:space:]]$ ]]; then
        echo -e "   ${VERMELHO}${label} inválido.${RESET}"
        return 1
    fi
    [[ "$mode" != "0" ]] && return 0

    server_list="${value//;/ }"
    server_list="${server_list//,/ }"
    for entry in $server_list; do
        entry="${entry//[[:space:]]/}"
        [[ -z "$entry" ]] && continue
        host="$entry"
        port=""
        if [[ "$entry" == *":"* && "$entry" != *"]"* ]]; then
            host="${entry%:*}"
            port="${entry##*:}"
        fi
        host="${host#[}"
        host="${host%]}"
        if is_forbidden_active_proxy_target "$host"; then
            echo -e "   ${VERMELHO}${label} inválido para Proxy ativo: ${entry}${RESET}"
            echo -e "   Informe o IP/DNS real do Zabbix Server, não localhost nem o IP deste Proxy."
            echo -e "   Exemplo: 10.1.30.111"
            return 1
        fi
        if [[ -n "$port" ]]; then
            if [[ ! "$port" =~ ^[0-9]+$ || "$port" -lt 1 || "$port" -gt 65535 ]]; then
                echo -e "   ${VERMELHO}Porta inválida em ${entry}.${RESET}"
                return 1
            fi
        fi
    done
    return 0
}
supported_versions_for_component() {
    local component="$1"
    case "${OS_FAMILY}:${component}" in
    ubuntu:db) echo "18.04 20.04 22.04 24.04 26.04" ;;
    ubuntu:server) echo "20.04 22.04 24.04 26.04" ;;
    ubuntu:proxy) echo "16.04 18.04 20.04 22.04 24.04 26.04" ;;
    debian:db | debian:server | debian:proxy) echo "12 13" ;;
    rhel:db | rhel:server | rhel:proxy) echo "" ;;
    *) echo "" ;;
    esac
}
is_component_supported() {
    local component="$1" supported
    supported="$(supported_versions_for_component "$component")"
    [[ -n "$supported" && " ${supported} " == *" ${U_VER} "* ]]
}
validate_supported_system_any_component() {
    if is_component_supported db || is_component_supported server || is_component_supported proxy; then
        return 0
    fi
    echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} ${OS_DISPLAY} não é suportado por este instalador."
    echo -e "  Ubuntu suportado: DB 18.04/20.04/22.04/24.04/26.04 | Server 20.04/22.04/24.04/26.04 | Proxy 16.04/18.04/20.04/22.04/24.04/26.04"
    echo -e "  Debian suportado: 12 (bookworm) e 13 (trixie)"
    echo -e "  AlmaLinux/Rocky: detectado, mas instalação ainda indisponível nesta versão"
    if [[ "$OS_FAMILY" == "debian" && "$U_VER" == "11" ]]; then
        echo -e "  ${AMARELO}Debian 11 foi removido porque faltam pacotes oficiais Zabbix Server nas combinações validadas.${RESET}"
        echo -e "  Pacote crítico ausente: zabbix-server-pgsql."
    fi
    if [[ "$OS_FAMILY" == "rhel" ]]; then
        abort_rhel_not_ready
    fi
    exit 1
}
validate_supported_ubuntu_any_component() {
    validate_supported_system_any_component
}
component_supported_or_die() {
    local component="$1" supported
    supported="$(supported_versions_for_component "$component")"
    if ! is_component_supported "$component"; then
        echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} ${OS_DISPLAY} não é suportado para o componente ${component}."
        echo -e "  Versões suportadas para este sistema/componente: ${supported:-nenhuma}"
        exit 1
    fi
    echo -e "  ${VERDE}✔ ${OS_DISPLAY} suportado para ${component}${RESET}"
}
zabbix_release_url() {
    local version="$1"
    case "${OS_FAMILY}:${version}" in
    ubuntu:8.0) echo "https://repo.zabbix.com/zabbix/8.0/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_8.0+ubuntu${U_VER}_all.deb" ;;
    ubuntu:7.4) echo "https://repo.zabbix.com/zabbix/7.4/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.4+ubuntu${U_VER}_all.deb" ;;
    ubuntu:7.0) echo "https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu${U_VER}_all.deb" ;;
    debian:8.0) echo "https://repo.zabbix.com/zabbix/8.0/release/debian/pool/main/z/zabbix-release/zabbix-release_latest_8.0+debian${U_VER}_all.deb" ;;
    debian:7.4) echo "https://repo.zabbix.com/zabbix/7.4/release/debian/pool/main/z/zabbix-release/zabbix-release_latest_7.4+debian${U_VER}_all.deb" ;;
    debian:7.0) echo "https://repo.zabbix.com/zabbix/7.0/debian/pool/main/z/zabbix-release/zabbix-release_latest_7.0+debian${U_VER}_all.deb" ;;
    *) return 1 ;;
    esac
}
zabbix_packages_index_url() {
    local version="$1" arch
    arch=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
    case "${OS_FAMILY}:${version}" in
    ubuntu:8.0) echo "https://repo.zabbix.com/zabbix/8.0/unstable/ubuntu/dists/${U_CODENAME}/main/binary-${arch}/Packages.gz" ;;
    ubuntu:7.4) echo "https://repo.zabbix.com/zabbix/7.4/stable/ubuntu/dists/${U_CODENAME}/main/binary-${arch}/Packages.gz" ;;
    ubuntu:7.0) echo "https://repo.zabbix.com/zabbix/7.0/ubuntu/dists/${U_CODENAME}/main/binary-${arch}/Packages.gz" ;;
    debian:8.0) echo "https://repo.zabbix.com/zabbix/8.0/unstable/debian/dists/${U_CODENAME}/main/binary-${arch}/Packages.gz" ;;
    debian:7.4) echo "https://repo.zabbix.com/zabbix/7.4/stable/debian/dists/${U_CODENAME}/main/binary-${arch}/Packages.gz" ;;
    debian:7.0) echo "https://repo.zabbix.com/zabbix/7.0/debian/dists/${U_CODENAME}/main/binary-${arch}/Packages.gz" ;;
    *) return 1 ;;
    esac
}
validate_official_zabbix_package() {
    local package="$1" version="${2:-${ZBX_VERSION:-}}" index_url package_index cache_file
    [[ -n "$version" ]] || {
        echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} versão Zabbix não definida para validar ${package}."
        exit 1
    }
    index_url="$(zabbix_packages_index_url "$version" 2>/dev/null || true)"
    if [[ -z "$index_url" ]]; then
        echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} não há índice Zabbix conhecido para ${OS_DISPLAY} + Zabbix ${version}."
        exit 1
    fi
    cache_file="${VALIDATION_CACHE_DIR}/zabbix_${OS_FAMILY}_${U_CODENAME}_${version}_$(dpkg --print-architecture 2>/dev/null || echo amd64).Packages"
    if [[ -s "$cache_file" && $(($(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0))) -lt 1800 ]]; then
        package_index="$(cat "$cache_file" 2>/dev/null || true)"
    elif ! package_index="$(_curl -fsL --max-time 25 "$index_url" 2>/dev/null | timeout 10 gzip -dc 2>/dev/null)"; then
        echo -e "\n${VERMELHO}${NEGRITO}ERRO:${RESET} não foi possível consultar o índice oficial do Zabbix antes de alterar o APT."
        echo -e "  URL testada: ${index_url}"
        echo -e "  Sistema: ${OS_DISPLAY}"
        exit 1
    else
        printf '%s\n' "$package_index" >"$cache_file" 2>/dev/null || true
    fi
    if ! grep -q "^Package: ${package}$" <<<"$package_index"; then
        echo -e "\n${VERMELHO}${NEGRITO}ERRO:${RESET} pacote ${package} não existe no índice oficial do Zabbix ${version}."
        echo -e "  URL testada: ${index_url}"
        echo -e "  Sistema: ${OS_DISPLAY}"
        echo -e "  A instalação foi interrompida antes de registrar o repositório no sistema."
        exit 1
    fi
    echo -e "  ${VERDE}✔${RESET} Índice oficial Zabbix ${version}: ${package} disponível"
    log_msg "INFO" "Pacote ${package} validado no índice oficial Zabbix ${version}: ${index_url}"
}
validate_supported_architecture() {
    local arch
    arch=$(dpkg --print-architecture 2>/dev/null || uname -m 2>/dev/null || echo "unknown")
    case "$arch" in
    amd64 | arm64)
        echo -e "  ${VERDE}✔${RESET} Arquitetura suportada para validação: ${arch}"
        ;;
    *)
        echo -e "\n${VERMELHO}${NEGRITO}ERRO:${RESET} arquitetura não validada por este instalador: ${arch}"
        echo -e "  Use amd64/arm64 ou valide manualmente os repositórios oficiais antes de prosseguir."
        exit 1
        ;;
    esac
}
default_php_for_system() {
    case "$OS_FAMILY:$U_VER" in
    debian:12) echo "8.2" ;;
    debian:13) echo "8.4" ;;
    ubuntu:20.04) echo "8.1" ;;
    ubuntu:22.04) echo "8.1" ;;
    ubuntu:24.04) echo "8.3" ;;
    ubuntu:26.04) echo "8.5" ;;
    *) echo "8.1" ;;
    esac
}
validate_compatibility_matrix() {
    local component="$1" experimental=0 reason=""
    abort_rhel_not_ready
    validate_supported_architecture
    component_supported_or_die "$component"
    if [[ "${PG_VER:-17}" == "18" ]]; then
        experimental=1
        reason="PostgreSQL 18 pode estar em adoção inicial para alguns componentes/extensões."
    fi
    if [[ "${ZBX_VERSION:-${ZBX_TARGET_VERSION:-}}" == "8.0" ]]; then
        experimental=1
        reason="${reason:+${reason} }Zabbix 8.0 depende de publicação atual do repositório oficial."
    fi
    if [[ "$experimental" == "1" && "${SIMULATE_MODE:-0}" != "1" ]]; then
        echo -e "\n${AMARELO}${NEGRITO}⚠ Combinação possível, mas tratada como experimental.${RESET}"
        echo -e "  ${reason}"
        echo -e "  Sistema: ${OS_DISPLAY}"
        echo -e "  Zabbix: ${ZBX_VERSION:-${ZBX_TARGET_VERSION:-N/D}} | PostgreSQL: ${PG_VER:-N/D} | PHP: ${PHP_VER:-N/D}"
        local ack
        read -rp "  Digite CONTINUAR para aceitar esta combinação experimental: " ack
        [[ "$ack" == "CONTINUAR" ]] || {
            echo -e "${AMARELO}Operação cancelada pelo operador.${RESET}"
            exit 0
        }
    fi
}
validate_frontend_runtime_packages() {
    local php_ver="${1:-$(default_php_for_system)}"
    validate_packages_available nginx \
        "php${php_ver}-fpm" "php${php_ver}-pgsql" "php${php_ver}-bcmath" \
        "php${php_ver}-mbstring" "php${php_ver}-gd" "php${php_ver}-xml" \
        "php${php_ver}-ldap" "php${php_ver}-curl" "php${php_ver}-zip"
}
validate_remote_packages_index() {
    local label="$1" url="$2"
    shift 2
    local package_index pkg missing=0 optional=0 cache_key cache_file
    if [[ "${1:-}" == "--optional" ]]; then
        optional=1
        shift
    fi
    echo -e "  ${CIANO}Consultando:${RESET} ${url}"
    cache_key="$(printf '%s' "$url" | sed 's/[^a-zA-Z0-9_.-]/_/g')"
    cache_file="${VALIDATION_CACHE_DIR}/${cache_key}"
    if [[ -s "$cache_file" && $(($(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0))) -lt 1800 ]]; then
        package_index="$(cat "$cache_file" 2>/dev/null || true)"
    elif ! package_index="$(_curl -fsL --max-time 30 "$url" 2>/dev/null | timeout 10 gzip -dc 2>/dev/null)"; then
        echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} não foi possível ler índice oficial: ${label}"
        echo -e "  URL: ${url}"
        exit 1
    else
        printf '%s\n' "$package_index" >"$cache_file" 2>/dev/null || true
    fi
    for pkg in "$@"; do
        if grep -q "^Package: ${pkg}$" <<<"$package_index"; then
            echo -e "  ${VERDE}✔${RESET} ${pkg}"
        else
            echo -e "  ${VERMELHO}✖${RESET} ${pkg} ausente"
            missing=1
        fi
    done
    if [[ "$missing" != "0" && "$optional" == "1" ]]; then
        return 1
    fi
    [[ "$missing" == "0" ]] || exit 1
}
pgdg_packages_index_url() {
    local arch
    arch=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
    echo "https://apt.postgresql.org/pub/repos/apt/dists/${U_CODENAME}-pgdg/main/binary-${arch}/Packages.gz"
}
timescale_packages_index_url() {
    local arch tsdb_os
    arch=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
    tsdb_os="$(timescale_repo_os)"
    echo "https://packagecloud.io/timescale/timescaledb/${tsdb_os}/dists/${U_CODENAME}/main/binary-${arch}/Packages.gz"
}
run_repo_check() {
    local component="$1" zbx_ver pg_ver php_ver ts_pkg
    clear
    echo -e "${CIANO}${NEGRITO}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CIANO}${NEGRITO}║              REPO-CHECK — SEM INSTALAR NADA              ║${RESET}"
    echo -e "${CIANO}${NEGRITO}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo -e "\n${CIANO}${NEGRITO}▸ SISTEMA${RESET}"
    printf "  %-24s %s\n" "Sistema:" "$OS_DISPLAY"
    printf "  %-24s %s\n" "Arquitetura:" "$(dpkg --print-architecture 2>/dev/null || uname -m)"
    abort_rhel_not_ready
    component_supported_or_die "$component"
    validate_supported_architecture
    echo -e "\n${CIANO}${NEGRITO}▸ REPOSITÓRIO BASE${RESET}"
    pkg_update >/dev/null
    validate_packages_available curl wget ca-certificates gnupg openssl
    case "$component" in
    db)
        zbx_ver="7.4"
        pg_ver="17"
        echo -e "\n${CIANO}${NEGRITO}▸ POSTGRESQL / PGDG${RESET}"
        validate_remote_packages_index "PGDG" "$(pgdg_packages_index_url)" "postgresql-${pg_ver}" "postgresql-client-${pg_ver}"
        echo -e "\n${CIANO}${NEGRITO}▸ TIMESCALEDB${RESET}"
        ts_pkg="timescaledb-2-postgresql-${pg_ver}"
        if validate_remote_packages_index "TimescaleDB" "$(timescale_packages_index_url)" --optional "$ts_pkg"; then
            :
        else
            echo -e "  ${AMARELO}⚠ TimescaleDB indisponível para esta combinação; instalação poderia seguir sem ele.${RESET}"
        fi
        echo -e "\n${CIANO}${NEGRITO}▸ ZABBIX AGENT 2${RESET}"
        validate_official_zabbix_package zabbix-agent2 "$zbx_ver"
        ;;
    server)
        zbx_ver="7.4"
        pg_ver="17"
        php_ver="$(default_php_for_system)"
        echo -e "\n${CIANO}${NEGRITO}▸ POSTGRESQL CLIENT${RESET}"
        validate_remote_packages_index "PGDG" "$(pgdg_packages_index_url)" "postgresql-client-${pg_ver}"
        echo -e "\n${CIANO}${NEGRITO}▸ ZABBIX SERVER${RESET}"
        validate_official_zabbix_package zabbix-server-pgsql "$zbx_ver"
        echo -e "\n${CIANO}${NEGRITO}▸ FRONTEND${RESET}"
        validate_frontend_runtime_packages "$php_ver"
        ;;
    proxy)
        zbx_ver="7.4"
        echo -e "\n${CIANO}${NEGRITO}▸ ZABBIX PROXY${RESET}"
        validate_official_zabbix_package zabbix-proxy-sqlite3 "$zbx_ver"
        validate_packages_available sqlite3
        ;;
    *)
        echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} componente inválido para --repo-check: ${component}"
        exit 1
        ;;
    esac
    echo -e "\n${VERDE}${NEGRITO}Repo-check concluído. Nenhuma instalação foi executada.${RESET}\n"
}
check_package_available() {
    local pkg="$1" label="${2:-$1}" optional="${3:-0}" candidate
    if [[ "$OS_FAMILY" == "rhel" ]]; then
        if command -v dnf >/dev/null 2>&1 && dnf list --available "$pkg" >/dev/null 2>&1; then
            echo -e "  ${VERDE}✔${RESET} ${label}: disponível no DNF"
            log_msg "INFO" "Pacote validado no DNF: ${pkg}"
            return 0
        fi
        if [[ "$optional" == "1" ]]; then
            echo -e "  ${AMARELO}⚠${RESET} ${label}: pacote opcional não encontrado no DNF."
            log_msg "WARN" "Pacote opcional indisponível no DNF: ${pkg}"
            return 1
        fi
        echo -e "\n${VERMELHO}${NEGRITO}ERRO:${RESET} pacote obrigatório não encontrado no DNF: ${pkg}"
        echo -e "  Sistema: ${OS_DISPLAY}"
        exit 1
    fi
    candidate=$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/{print $2; exit}')
    if [[ -n "$candidate" && "$candidate" != "(none)" ]]; then
        echo -e "  ${VERDE}✔${RESET} ${label}: ${candidate}"
        log_msg "INFO" "Pacote validado no repositório: ${pkg} -> ${candidate}"
        return 0
    fi
    if [[ "$optional" == "1" ]]; then
        echo -e "  ${AMARELO}⚠${RESET} ${label}: pacote não encontrado; continuará sem este recurso."
        log_msg "WARN" "Pacote opcional indisponível: ${pkg}"
        return 1
    fi
    echo -e "\n${VERMELHO}${NEGRITO}ERRO:${RESET} pacote obrigatório não encontrado no repositório local: ${pkg}"
    echo -e "  Sistema: ${OS_DISPLAY}"
    echo -e "  Diagnóstico sugerido: apt-cache policy ${pkg} && apt-get update"
    log_msg "ERROR" "Pacote obrigatório indisponível: ${pkg}"
    exit 1
}
validate_packages_available() {
    local pkg
    for pkg in "$@"; do
        check_package_available "$pkg"
    done
}
validate_ipv4_cidr() {
    local value="$1" label="${2:-IP/CIDR}"
    local ip cidr octets octet
    if [[ "$value" == */* ]]; then
        ip="${value%/*}"
        cidr="${value#*/}"
        if [[ ! "$cidr" =~ ^[0-9]+$ || "$cidr" -lt 0 || "$cidr" -gt 32 ]]; then
            echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} ${label} inválido: ${value}"
            echo -e "  CIDR deve estar entre /0 e /32."
            exit 1
        fi
    else
        ip="$value"
    fi
    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} ${label} inválido: ${value}"
        echo -e "  Use IPv4, exemplo: 192.168.1.10 ou 192.168.1.0/24."
        exit 1
    fi
    IFS='.' read -r -a octets <<<"$ip"
    for octet in "${octets[@]}"; do
        if ((octet < 0 || octet > 255)); then
            echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} ${label} inválido: ${value}"
            echo -e "  Cada octeto IPv4 deve estar entre 0 e 255."
            exit 1
        fi
    done
}
