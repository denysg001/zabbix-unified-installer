# shellcheck shell=bash

APT_FLAGS=(-y -o "Dpkg::Options::=--force-confdef" -o "Dpkg::Options::=--force-confold" -o "Dpkg::Options::=--force-confmiss")
ZBX_FRONTEND_LANG="en_US"
# Shared system, package-manager, network, shell, and support utilities.
safe_diag_cmd() {
    timeout 10 "$@" 2>/dev/null || true
}
as_user() {
    local user="$1"
    shift
    if [[ "$(id -un 2>/dev/null || true)" == "$user" ]]; then
        "$@"
    elif [[ "$EUID" -eq 0 ]]; then
        runuser -u "$user" -- "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -u "$user" "$@"
    else
        echo "Permissão insuficiente: execute como root ou instale sudo para alternar para ${user}." >&2
        return 127
    fi
}
postgres_cmd() {
    as_user postgres "$@"
}
postgres_psql() {
    postgres_cmd psql "$@"
}
postgres_psql_timeout() {
    local timeout_s="$1"
    shift
    timeout "$timeout_s" bash -c '
        user="$1"
        shift
        if [[ "$(id -un 2>/dev/null || true)" == "$user" ]]; then
            exec "$@"
        elif [[ "$EUID" -eq 0 ]]; then
            exec runuser -u "$user" -- "$@"
        elif command -v sudo >/dev/null 2>&1; then
            exec sudo -u "$user" "$@"
        else
            echo "Permissão insuficiente: execute como root ou instale sudo." >&2
            exit 127
        fi
    ' _ postgres psql "$@"
}
_curl() {
    local has_max_time=0 arg
    for arg in "$@"; do
        [[ "$arg" == "--max-time" || "$arg" == -m || "$arg" == --max-time=* ]] && has_max_time=1
    done
    if [[ "$has_max_time" == "1" ]]; then
        command curl --connect-timeout 10 --retry 3 --retry-delay 2 --retry-connrefused "$@"
    else
        command curl --connect-timeout 10 --max-time 10 --retry 3 --retry-delay 2 --retry-connrefused "$@"
    fi
}
_wget() {
    command wget --timeout=10 --tries=3 "$@"
}
psql() {
    local psql_bin
    psql_bin="$(type -P psql 2>/dev/null || true)"
    [[ -n "$psql_bin" ]] || {
        echo "psql não encontrado" >&2
        return 127
    }
    PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}" timeout "${PSQL_TIMEOUT:-900}" "$psql_bin" "$@"
}
acquire_install_lock() {
    [[ "${CHECK_ONLY:-0}" == "1" ]] && return 0
    local lock_component="${COMPONENT:-menu}"
    LOCK_FILE="/tmp/zabbix_unified_${lock_component}.lock"
    if [[ -f "$LOCK_FILE" ]]; then
        local old_pid
        old_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
        if [[ -n "$old_pid" && "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
            echo -e "\n\e[31m\e[1mERRO:\e[0m já existe uma execução ativa deste instalador para '${lock_component}' (PID ${old_pid})."
            echo -e "Remova ${LOCK_FILE} apenas se tiver certeza de que não há instalação em andamento."
            exit 1
        fi
        rm -f "$LOCK_FILE" 2>/dev/null || true
    fi
    echo "$$" >"$LOCK_FILE"
    add_exit_trap cleanup_install_lock
}
auto_repair_apt() {
    local timeout=15
    local waited=0

    apt_process_running() {
        pgrep -x "apt" >/dev/null 2>&1 ||
            pgrep -x "apt-get" >/dev/null 2>&1 ||
            pgrep -x "dpkg" >/dev/null 2>&1 ||
            pgrep -x "unattended-upgrades" >/dev/null 2>&1
    }

    while apt_process_running; do
        if ((waited >= timeout)); then
            [[ -n "${LOG_FILE:-}" ]] && echo "APT ocupado ha ${timeout}s; tentando liberar apt-daily..." >>"$LOG_FILE" 2>/dev/null || true
            systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
            systemctl kill --kill-who=all apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    if ! apt_process_running; then
        rm -f /var/lib/dpkg/lock-frontend \
            /var/lib/dpkg/lock \
            /var/lib/apt/lists/lock \
            /var/cache/apt/archives/lock 2>/dev/null || true
    else
        [[ -n "${LOG_FILE:-}" ]] && echo "APT/dpkg ainda em execucao; locks preservados." >>"$LOG_FILE" 2>/dev/null || true
    fi

    dpkg --configure -a 2>/dev/null | { [[ -n "${LOG_FILE:-}" ]] && tee -a "$LOG_FILE" || cat; } 2>/dev/null || true
    apt-get install -f -y 2>/dev/null | { [[ -n "${LOG_FILE:-}" ]] && tee -a "$LOG_FILE" || cat; } 2>/dev/null || true
}
select_timezone_value() {
    local current="$1" context="$2" opt custom_tz
    [[ -z "$current" ]] && current="America/Sao_Paulo"
    echo -e "\n${CIANO}${NEGRITO}>>> FUSO HORÁRIO DO SISTEMA <<<${RESET}" >&2
    echo -e "  Fuso atual/detectado: ${NEGRITO}${current}${RESET}" >&2
    echo -e "  ${AMARELO}${context}${RESET}" >&2
    echo -e "\n  1) America/Sao_Paulo (Brasil)" >&2
    echo -e "  2) UTC" >&2
    echo -e "  3) Manter detectado (${current})" >&2
    echo -e "  4) Outro fuso validado" >&2
    while true; do
        read -rp "  Escolha (1, 2, 3 ou 4): " opt
        case "$opt" in
        1)
            printf '%s\n' "America/Sao_Paulo"
            return 0
            ;;
        2)
            printf '%s\n' "UTC"
            return 0
            ;;
        3 | "")
            printf '%s\n' "$current"
            return 0
            ;;
        4)
            while true; do
                read -rp "   Novo fuso (ex: America/Sao_Paulo, Europe/Lisbon, UTC): " custom_tz
                if validate_timezone_name "$custom_tz"; then
                    printf '%s\n' "$custom_tz"
                    return 0
                fi
                echo -e "   ${VERMELHO}Fuso inválido ou não encontrado neste sistema.${RESET}" >&2
            done
            ;;
        *) echo -e "  ${VERMELHO}Opção inválida.${RESET}" >&2 ;;
        esac
    done
}
ensure_utf8_locales() {
    if [[ -f /etc/locale.gen ]]; then
        grep -qE '^[# ]*en_US\.UTF-8 UTF-8' /etc/locale.gen 2>/dev/null &&
            sed -i 's/^[# ]*en_US\.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
        grep -qE '^[# ]*pt_BR\.UTF-8 UTF-8' /etc/locale.gen 2>/dev/null &&
            sed -i 's/^[# ]*pt_BR\.UTF-8 UTF-8/pt_BR.UTF-8 UTF-8/' /etc/locale.gen
        grep -qE '^en_US\.UTF-8 UTF-8' /etc/locale.gen 2>/dev/null || echo 'en_US.UTF-8 UTF-8' >>/etc/locale.gen
        grep -qE '^pt_BR\.UTF-8 UTF-8' /etc/locale.gen 2>/dev/null || echo 'pt_BR.UTF-8 UTF-8' >>/etc/locale.gen
    fi
    locale-gen en_US.UTF-8 pt_BR.UTF-8 2>/dev/null || locale-gen 2>/dev/null || true
    if locale -a 2>/dev/null | grep -qiE '^en_US\.(utf8|UTF-8)$'; then
        update-locale LANG=en_US.UTF-8 2>/dev/null || true
    else
        add_install_warning "Locale en_US.UTF-8 não pôde ser ativado automaticamente; instalação continuará."
        log_msg "WARN" "Locale en_US.UTF-8 não pôde ser ativado automaticamente; instalação continuará."
    fi
    return 0
}
php_supports_pt_br_locale() {
    command -v php >/dev/null 2>&1 || return 1
    php -r 'exit(setlocale(LC_ALL, "pt_BR.UTF-8", "pt_BR.utf8", "pt_BR") === false ? 1 : 0);' \
        >/dev/null 2>&1
}
ensure_zabbix_frontend_locales() {
    ensure_utf8_locales

    if php_supports_pt_br_locale; then
        ZBX_FRONTEND_LANG="pt_BR"
        log_msg "INFO" "Locale pt_BR validado pelo PHP; frontend Zabbix será configurado em pt_BR."
        return 0
    fi

    if [[ "$OS_FAMILY" == "debian" ]] && check_package_available "locales-all" "locales-all" 1; then
        apt-get install "${APT_FLAGS[@]}" locales-all
        ensure_utf8_locales
    fi

    if php_supports_pt_br_locale; then
        ZBX_FRONTEND_LANG="pt_BR"
        log_msg "INFO" "Locale pt_BR validado pelo PHP após instalar locales-all."
    else
        ZBX_FRONTEND_LANG="en_US"
        add_install_warning "Locale pt_BR indisponível para PHP-FPM; Admin do frontend ficará em en_US para evitar alertas vermelhos."
    fi
    return 0
}
ask_yes_no() {
    local question="$1" var_name="$2"
    echo -e "\n${AMARELO}${NEGRITO}${question}${RESET}"
    echo -e "  1) Sim   2) Não"
    while true; do
        read -rp "  Escolha (1 ou 2): " choice
        case "$choice" in
        1)
            printf -v "$var_name" "1"
            break
            ;;
        2)
            printf -v "$var_name" "0"
            break
            ;;
        *) echo -e "  ${VERMELHO}Opção inválida.${RESET}" ;;
        esac
    done
}
pkg_update() {
    case "$OS_FAMILY" in
    ubuntu | debian) apt-get update ;;
    rhel) dnf makecache ;;
    *)
        echo "Sistema não suportado para atualização de repositórios: ${OS_DISPLAY}" >&2
        return 1
        ;;
    esac
}
pkg_install() {
    case "$OS_FAMILY" in
    ubuntu | debian) apt-get install "${APT_FLAGS[@]}" "$@" ;;
    rhel) dnf install -y "$@" ;;
    *)
        echo "Sistema não suportado para instalação de pacotes: ${OS_DISPLAY}" >&2
        return 1
        ;;
    esac
}
pkg_purge() {
    case "$OS_FAMILY" in
    ubuntu | debian) apt-get purge -y "$@" ;;
    rhel) dnf remove -y "$@" ;;
    *)
        echo "Sistema não suportado para remoção de pacotes: ${OS_DISPLAY}" >&2
        return 1
        ;;
    esac
}
pkg_is_installed() {
    local pkg="$1"
    case "$OS_FAMILY" in
    ubuntu | debian) dpkg -s "$pkg" >/dev/null 2>&1 ;;
    rhel) rpm -q "$pkg" >/dev/null 2>&1 ;;
    *) return 1 ;;
    esac
}
abort_rhel_not_ready() {
    if [[ "$OS_FAMILY" == "rhel" ]]; then
        echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} ${OS_DISPLAY} foi detectado, mas os fluxos RHEL ainda não estão implementados por completo."
        echo -e "  O instalador reconhece AlmaLinux/Rocky para preparação futura, mas aborta antes de qualquer instalação parcial."
        echo -e "  Use Ubuntu/Debian suportado nesta versão."
        exit 1
    fi
}
sql_quote_literal() {
    local s="$1"
    s="${s//\'/\'\'}"
    printf "'%s'" "$s"
}
sql_quote_ident() {
    local s="$1"
    s="${s//\"/\"\"}"
    printf '"%s"' "$s"
}
package_version() {
    local pkg="$1"
    case "$OS_FAMILY" in
    ubuntu | debian)
        dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true
        ;;
    rhel)
        rpm -q --qf '%{VERSION}-%{RELEASE}' "$pkg" 2>/dev/null || true
        ;;
    esac
}
package_version_or_na() {
    local version
    version=$(package_version "$1")
    printf '%s' "${version:-N/D}"
}
pgpass_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//:/\\:}"
    printf "%s" "$s"
}
php_single_quote_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\'/\\\'}"
    printf "%s" "$s"
}
test_tcp_connectivity() {
    local host="$1" port="$2" timeout_s="${3:-5}"
    timeout "$timeout_s" bash -c ":</dev/tcp/${host}/${port}" >/dev/null 2>&1
}
check_proxy_server_connectivity() {
    local server_list="${1:-${ZBX_SERVER:-}}" mode="${2:-${PROXY_MODE:-0}}"
    local entry host port ok=0 total=0

    echo -e "\n${CIANO}${NEGRITO}▸ TESTE PROXY → SERVER${RESET}"
    if [[ -z "$server_list" ]]; then
        echo -e "  ${AMARELO}⚠${RESET} Server do Proxy não informado; teste ignorado."
        [[ "${DOCTOR_ACTIVE:-0}" == "1" ]] && DOCTOR_WARN=$((DOCTOR_WARN + 1))
        return 0
    fi
    if [[ "$mode" != "0" ]]; then
        printf "  %-34s %s\n" "Modo:" "PASSIVO — o Server conecta no Proxy"
        printf "  %-34s %s\n" "Server autorizado:" "$server_list"
        echo -e "  ${AMARELO}ℹ${RESET} Teste ativo de saída não se aplica neste modo."
        return 0
    fi

    printf "  %-34s %s\n" "Modo:" "ATIVO — o Proxy conecta no Server"
    server_list="${server_list//;/ }"
    server_list="${server_list//,/ }"
    for entry in $server_list; do
        entry="${entry//[[:space:]]/}"
        [[ -z "$entry" ]] && continue
        host="$entry"
        port="10051"
        if [[ "$entry" == *":"* && "$entry" != *"]"* ]]; then
            host="${entry%:*}"
            port="${entry##*:}"
        fi
        host="${host#[}"
        host="${host%]}"
        if is_forbidden_active_proxy_target "$host"; then
            printf "  %-34s ${AMARELO}%s${RESET}\n" "${host}:${port}" "destino inválido para Proxy ativo"
            [[ "${DOCTOR_ACTIVE:-0}" == "1" ]] && DOCTOR_WARN=$((DOCTOR_WARN + 1))
            continue
        fi
        total=$((total + 1))
        if test_tcp_connectivity "$host" "$port" 5; then
            printf "  %-34s ${VERDE}%s${RESET}\n" "${host}:${port}" "OK"
            ok=1
        else
            printf "  %-34s ${AMARELO}%s${RESET}\n" "${host}:${port}" "sem conexão TCP"
        fi
    done
    [[ "$total" -gt 0 && "$ok" == "0" ]] &&
        echo -e "  ${AMARELO}⚠ Nenhum destino respondeu agora. Verifique rota/firewall/porta 10051 no Server.${RESET}"
    [[ "$total" -gt 0 && "$ok" == "0" && "${DOCTOR_ACTIVE:-0}" == "1" ]] && DOCTOR_WARN=$((DOCTOR_WARN + 1))
    return 0
}
timescale_repo_os() {
    case "$OS_FAMILY" in
    ubuntu | debian) echo "$OS_FAMILY" ;;
    *) return 1 ;;
    esac
}
install_optional_packages() {
    local pkg
    for pkg in "$@"; do
        if check_package_available "$pkg" "$pkg" 1; then
            apt-get install "${APT_FLAGS[@]}" "$pkg" ||
                log_msg "WARN" "Falha ao instalar pacote opcional ${pkg}; continuando."
        else
            add_install_warning "Pacote opcional '${pkg}' indisponível no repositório; instalação continuou sem ele."
            log_msg "WARN" "Pacote opcional ausente no repositório: ${pkg}"
        fi
    done
}
install_server_base_deps() {
    local pkgs=(curl wget ca-certificates gnupg apt-transport-https lsb-release locales python3)
    if [[ "$NEED_PHP_PPA" == "1" && "$OS_FAMILY" == "ubuntu" ]]; then
        pkgs+=(software-properties-common)
    fi
    apt-get install "${APT_FLAGS[@]}" "${pkgs[@]}"
}
install_server_diag_tools() {
    apt-get install "${APT_FLAGS[@]}" curl wget nano snmp snmpd fping nmap traceroute net-tools jq openssl
    install_optional_packages snmp-mibs-downloader
}
install_proxy_full_tools() {
    apt-get install "${APT_FLAGS[@]}" curl wget nano sqlite3 snmp snmpd fping nmap traceroute net-tools jq openssl
    install_optional_packages snmp-mibs-downloader
}
check_system_clock() {
    echo -e "\n${CIANO}${NEGRITO}▸ Relógio do sistema${RESET}"
    if ! command -v timedatectl >/dev/null 2>&1; then
        echo -e "  ${AMARELO}⚠ timedatectl não disponível; verificação de relógio ignorada.${RESET}"
        return 0
    fi
    local ntp sync timezone
    ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
    sync=$(timedatectl show -p SystemClockSynchronized --value 2>/dev/null || true)
    timezone=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    printf "  %-34s %s\n" "Timezone:" "${timezone:-N/D}"
    printf "  %-34s %s\n" "NTP sincronizado:" "${ntp:-N/D}"
    printf "  %-34s %s\n" "Relógio sincronizado:" "${sync:-N/D}"
    if [[ "$ntp" == "no" || "$sync" == "no" ]]; then
        echo -e "  ${AMARELO}⚠ Relógio possivelmente não sincronizado. Isso pode afetar TLS, Proxy e coleta.${RESET}"
    fi
}
warn_weak_secret() {
    local secret="$1" label="${2:-Senha}"
    local score=0
    [[ -z "$secret" ]] && return 0
    ((${#secret} >= 12)) && score=$((score + 1))
    [[ "$secret" =~ [a-z] ]] && score=$((score + 1))
    [[ "$secret" =~ [A-Z] ]] && score=$((score + 1))
    [[ "$secret" =~ [0-9] ]] && score=$((score + 1))
    [[ "$secret" =~ [^a-zA-Z0-9] ]] && score=$((score + 1))
    if ((score < 3)); then
        echo -e "  ${AMARELO}⚠ ${label} parece fraca. O script permite continuar, mas recomenda 12+ caracteres com letras, números e símbolos.${RESET}"
    fi
}
print_support_commands() {
    local component="$1"
    echo -e "\n${CIANO}${NEGRITO}▸ COMANDOS ÚTEIS DE SUPORTE${RESET}"
    printf "  %-26s %s\n" "Log da instalação:" "tail -n 120 ${LOG_FILE}"
    case "$component" in
    db)
        printf "  %-26s %s\n" "PostgreSQL:" "systemctl status postgresql --no-pager"
        printf "  %-26s %s\n" "Logs PostgreSQL:" "journalctl -u postgresql -n 80 --no-pager"
        ;;
    server)
        printf "  %-26s %s\n" "Zabbix Server:" "systemctl status zabbix-server --no-pager"
        printf "  %-26s %s\n" "Nginx:" "systemctl status nginx --no-pager"
        printf "  %-26s %s\n" "Logs Server:" "journalctl -u zabbix-server -n 80 --no-pager"
        ;;
    proxy)
        printf "  %-26s %s\n" "Zabbix Proxy:" "systemctl status zabbix-proxy --no-pager"
        printf "  %-26s %s\n" "Logs Proxy:" "journalctl -u zabbix-proxy -n 80 --no-pager"
        ;;
    esac
    printf "  %-26s %s\n" "Doctor:" "$0 ${component} --doctor"
}
check_zabbix_repo_url() {
    if ! _curl -fsI --max-time 15 "$REPO_URL" >/dev/null 2>&1; then
        echo -e "\n${VERMELHO}${NEGRITO}ERRO:${RESET} Repositório Zabbix não encontrado para:"
        echo -e "  Zabbix ${ZBX_VERSION} + ${OS_DISPLAY}"
        echo -e "  URL testada: ${REPO_URL}"
        echo -e "\n${AMARELO}${NEGRITO}Possíveis causas:${RESET}"
        echo -e "  • Esta combinação ainda não foi publicada no repo oficial do Zabbix."
        echo -e "  • ${OS_LABEL} ${U_VER} pode ser recente demais para Zabbix ${ZBX_VERSION}."
        echo -e "  • DNS/proxy/rede pode estar bloqueando https://repo.zabbix.com."
        case "$ZBX_VERSION" in
        "8.0") echo -e "  Sugestão operacional: testar Zabbix 7.4 ou validar publicação do 8.0 para ${OS_LABEL} ${U_VER}." ;;
        "7.4") echo -e "  Sugestão operacional: testar Zabbix 7.0 LTS se 7.4 ainda não estiver publicado para ${OS_LABEL} ${U_VER}." ;;
        "7.0") echo -e "  Sugestão operacional: validar conectividade externa e codename (${U_CODENAME})." ;;
        esac
        exit 1
    fi
}
verify_zabbix_repo_active() {
    local check_pkg="${1:-zabbix-agent2}"
    local candidate
    candidate=$(apt-cache policy "$check_pkg" 2>/dev/null | awk '/Candidate:/{print $2}')
    if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
        echo -e "\n${VERMELHO}${NEGRITO}ERRO:${RESET} Repositório Zabbix ${ZBX_VERSION} não está acessível após apt-get update."
        echo -e "  Pacote ${check_pkg} não encontrado no índice local."
        echo -e "\n${AMARELO}${NEGRITO}Causas comuns:${RESET}"
        echo -e "  • Entrada de repositório stale ou duplicada em /etc/apt/sources.list.d/"
        echo -e "    (verifique se existe zabbix.list E zabbix.sources — remova o mais antigo)"
        echo -e "  • GPG key do repositório não instalada (dpkg -i pode ter falhado silenciosamente)"
        echo -e "  • Falha de rede ao descarregar o índice do repo.zabbix.com"
        echo -e "\n${AMARELO}Diagnóstico manual:${RESET}"
        echo -e "  apt-cache policy ${check_pkg}"
        echo -e "  ls /etc/apt/sources.list.d/zabbix*"
        echo -e "  apt-get update 2>&1 | grep -i zabbix"
        return 1
    fi
    echo -e "  ${VERDE}✔ Repositório Zabbix ${ZBX_VERSION} activo — ${check_pkg}: ${candidate}${RESET}"
}
check_disk_space() {
    local min_mb="${1:-2048}"
    local avail_mb
    avail_mb=$(df -Pm / | awk 'NR==2 {print $4}')
    if [[ -z "${avail_mb:-}" || ! "$avail_mb" =~ ^[0-9]+$ ]]; then
        echo -e "${AMARELO}⚠ Não foi possível verificar espaço livre em disco.${RESET}"
        return 0
    fi
    if ((avail_mb < min_mb)); then
        echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} Espaço livre insuficiente em /."
        echo -e "  Livre: ${avail_mb} MB | Mínimo recomendado: ${min_mb} MB"
        exit 1
    fi
    echo -e "  ${VERDE}✔ Espaço livre em /: ${avail_mb} MB${RESET}"
}
check_min_ram() {
    local min_mb="${1:-1024}"
    if [[ -z "${RAM_MB:-}" || ! "$RAM_MB" =~ ^[0-9]+$ ]]; then
        echo -e "${AMARELO}⚠ Não foi possível verificar RAM total.${RESET}"
        return 0
    fi
    if ((RAM_MB < min_mb)); then
        echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} RAM insuficiente."
        echo -e "  Detectado: ${RAM_MB} MB | Mínimo recomendado: ${min_mb} MB"
        exit 1
    fi
    echo -e "  ${VERDE}✔ RAM total: ${RAM_MB} MB${RESET}"
}
check_required_commands() {
    local missing=0 cmd
    for cmd in "$@"; do
        if type -P "$cmd" >/dev/null 2>&1; then
            echo -e "  ${VERDE}✔${RESET} ${cmd}"
        else
            echo -e "  ${VERMELHO}✖${RESET} ${cmd} não encontrado"
            missing=1
        fi
    done
    [[ "$missing" == "0" ]] || {
        echo -e "\n${VERMELHO}${NEGRITO}ERRO:${RESET} comandos obrigatórios ausentes."
        exit 1
    }
}
check_bootstrap_downloader() {
    local has_downloader=0
    if type -P curl >/dev/null 2>&1; then
        echo -e "  ${VERDE}✔${RESET} curl"
        has_downloader=1
    else
        echo -e "  ${AMARELO}⚠${RESET} curl não encontrado agora; será instalado nas dependências base."
    fi
    if type -P wget >/dev/null 2>&1; then
        echo -e "  ${VERDE}✔${RESET} wget"
        has_downloader=1
    else
        echo -e "  ${AMARELO}⚠${RESET} wget não encontrado agora; será instalado nas dependências base."
    fi
    if [[ "$has_downloader" != "1" ]]; then
        echo -e "\n${VERMELHO}${NEGRITO}ERRO:${RESET} curl e wget ausentes."
        echo -e "  Instale ao menos um downloader antes de iniciar:"
        echo -e "  ${NEGRITO}apt-get update && apt-get install -y curl${RESET}"
        exit 1
    fi
}
setup_timezone_ntp() {
    local target_timezone="$1"
    # Em containers LXC o relógio é gerido pelo host — tentar alterar causa erro fatal.
    # systemd-detect-virt -c retorna 0 (verdadeiro) se for qualquer container (LXC, Docker, etc).
    if ! systemd-detect-virt -c -q 2>/dev/null; then
        run_step "Ajustando relógio (${target_timezone})" timedatectl set-timezone "${target_timezone}"
        run_step "Ativando motor NTP" systemctl enable --now systemd-timesyncd
    else
        echo -e "\n  ${AMARELO}⚠ Ambiente de container (LXC) detectado. Pulando configuração de NTP (gerido pelo Host).${RESET}"
    fi
}
port_process_info() {
    local port="$1" raw proc pid_count suffix
    if command -v ss >/dev/null 2>&1; then
        raw=$(ss -ltnp 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$"')
        [[ -z "$raw" ]] && return
        proc=$(printf '%s\n' "$raw" | awk -F\" 'NF>=2 {print $2; exit}' || true)
        pid_count=$(printf '%s\n' "$raw" | awk '{n+=gsub(/pid=[0-9]+/,"&")} END{print n+0}' || echo 0)
        [[ "$pid_count" -gt 1 ]] && suffix="processos" || suffix="processo"
        echo "${proc:-(desconhecido)} — ${pid_count} ${suffix}"
    elif command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | awk 'NR==2{print $1, "— PID", $2}'
    fi
}
confirm_port_if_busy() {
    local port="$1" component="$2" label="$3" info allowed=0 ok
    info=$(port_process_info "$port" || true)
    [[ -z "$info" ]] && {
        echo -e "  ${VERDE}✔ Porta ${port}/TCP livre (${label})${RESET}"
        return 0
    }
    case "$component:$port" in
    db:5432) [[ "$info" =~ postgres|postmaster ]] && allowed=1 ;;
    server:80 | server:443) [[ "$info" =~ nginx|apache2|php-fpm|zabbix ]] && allowed=1 ;;
    server:10051) [[ "$info" =~ zabbix_server|zabbix-server ]] && allowed=1 ;;
    proxy:10051) [[ "$info" =~ zabbix_proxy|zabbix-proxy ]] && allowed=1 ;;
    esac
    if [[ "$allowed" == "1" ]]; then
        echo -e "  ${AMARELO}⚠ Porta ${port}/TCP ocupada por instalação relacionada (${label}); a limpeza deve tratar isso.${RESET}"
        echo -e "    ${info}"
        return 0
    fi
    echo -e "\n${AMARELO}${NEGRITO}⚠ Porta ${port}/TCP em uso por processo não identificado como instalação antiga.${RESET}"
    echo -e "  ${NEGRITO}Componente:${RESET} ${component}"
    echo -e "  ${NEGRITO}Processo:${RESET} ${info}"
    ask_yes_no "Continuar mesmo assim?" ok
    [[ "$ok" == "1" ]] || {
        echo -e "${VERMELHO}Instalação abortada pelo operador.${RESET}"
        exit 1
    }
}
primary_ipv4() {
    local ip_addr=""
    if command -v ip >/dev/null 2>&1; then
        ip_addr=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)
    fi
    [[ -z "$ip_addr" ]] && ip_addr=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    echo "$ip_addr"
}
is_private_ipv4() {
    local ip_addr="$1" a b
    [[ "$ip_addr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r a b _ <<<"$ip_addr"
    [[ "$a" == "10" ]] && return 0
    [[ "$a" == "172" && "$b" -ge 16 && "$b" -le 31 ]] && return 0
    [[ "$a" == "192" && "$b" == "168" ]] && return 0
    return 1
}
print_environment_context() {
    local ip_addr env_label
    ip_addr=$(primary_ipv4)
    [[ -z "$ip_addr" ]] && {
        echo -e "  ${AMARELO}⚠ IP principal não detectado.${RESET}"
        return 0
    }
    if is_private_ipv4 "$ip_addr"; then
        env_label="LAB/REDE PRIVADA"
        echo -e "  ${VERDE}✔ Ambiente detectado:${RESET} ${env_label} (${ip_addr})"
    else
        env_label="PRODUÇÃO/PÚBLICO"
        echo -e "  ${AMARELO}${NEGRITO}⚠ Ambiente detectado:${RESET} ${env_label} (${ip_addr})"
        echo -e "  ${AMARELO}Revise portas expostas, bind em 0.0.0.0/0 e acessos amplos antes de continuar.${RESET}"
    fi
    log_msg "INFO" "Ambiente detectado: ${env_label} (${ip_addr})"
}
detect_previous_installation() {
    local component="$1" found=0
    case "$component" in
    db)
        dpkg -l 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^ii|^rc/ && $2 ~ /^(postgresql|timescaledb)/ {found=1} END{exit !found}' && found=1 || true
        [[ -d /etc/postgresql || -d /var/lib/postgresql ]] && found=1
        ;;
    server)
        dpkg -l 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^ii|^rc/ && $2 ~ /^(zabbix|nginx|php.*fpm)/ {found=1} END{exit !found}' && found=1 || true
        [[ -d /etc/zabbix || -d /var/lib/zabbix || -d /var/log/zabbix ]] && found=1
        ;;
    proxy)
        dpkg -l 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^ii|^rc/ && $2 ~ /^zabbix/ {found=1} END{exit !found}' && found=1 || true
        [[ -d /etc/zabbix || -d /var/lib/zabbix || -d /var/log/zabbix ]] && found=1
        ;;
    esac
    [[ "$found" == "1" ]]
}
warn_previous_installation() {
    local component="$1" ack="" pkg_list=""
    if detect_previous_installation "$component"; then
        case "$component" in
        db) pkg_list=$(dpkg -l 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^ii|^rc/ && $2 ~ /^(postgresql|timescaledb)/ {printf "%s ", $2}' || true) ;;
        server) pkg_list=$(dpkg -l 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^ii|^rc/ && $2 ~ /^(zabbix|nginx|php.*fpm)/ {printf "%s ", $2}' || true) ;;
        proxy) pkg_list=$(dpkg -l 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^ii|^rc/ && $2 ~ /^zabbix/ {printf "%s ", $2}' || true) ;;
        esac
        echo -e "\n${AMARELO}${NEGRITO}⚠ Instalação anterior detectada no escopo ${component}.${RESET}"
        [[ -n "$pkg_list" ]] && echo -e "  ${AMARELO}Pacotes encontrados:${RESET} ${pkg_list}"
        echo -e "  O fluxo de instalação limpa pode remover vestígios antigos conforme as opções escolhidas."
        log_msg "WARN" "Instalação anterior detectada no escopo ${component}: ${pkg_list}"
        if [[ "${SAFE_MODE:-0}" == "1" ]]; then
            echo -e "\n${AMARELO}${NEGRITO}Para continuar, digite CONTINUAR. Para cancelar, digite SAIR.${RESET}"
            while true; do
                read -rp "  Confirmação: " ack
                if [[ "$ack" == "CONTINUAR" ]]; then
                    break
                elif [[ "$ack" == "SAIR" ]]; then
                    echo -e "${AMARELO}Operação cancelada pelo operador.${RESET}"
                    exit 0
                else
                    echo -e "  ${VERMELHO}Entrada inválida: \"${ack}\"${RESET} — escreva ${NEGRITO}CONTINUAR${RESET} para aceitar ou ${NEGRITO}SAIR${RESET} para cancelar."
                fi
            done
        fi
    fi
}
safe_confirm_cleanup() {
    local title="$1"
    shift
    local ack=""
    [[ "${SAFE_MODE:-0}" == "1" ]] || return 0
    echo -e "\n${VERMELHO}${NEGRITO}SAFE MODE — confirmação de limpeza destrutiva${RESET}"
    echo -e "  ${NEGRITO}${title}${RESET}"
    echo -e "  Será removido/parado dentro deste escopo:"
    printf '    - %s\n' "$@"
    echo -e "  Para confirmar, digite ${NEGRITO}LIMPAR${RESET}. Para cancelar, digite ${NEGRITO}SAIR${RESET}."
    while true; do
        read -rp "  Confirmação: " ack
        if [[ "$ack" == "LIMPAR" ]]; then
            break
        elif [[ "$ack" == "SAIR" ]]; then
            echo -e "${AMARELO}Operação cancelada pelo operador.${RESET}"
            exit 0
        else
            echo -e "  ${VERMELHO}Entrada inválida: \"${ack}\"${RESET} — escreva ${NEGRITO}LIMPAR${RESET} para confirmar ou ${NEGRITO}SAIR${RESET} para cancelar."
        fi
    done
}
confirm_execution_summary() {
    local component="$1" ack=""
    [[ "${SIMULATE_MODE:-0}" == "1" ]] && return 0
    echo -e "\n${CIANO}${NEGRITO}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CIANO}${NEGRITO}║              CONFIRMAÇÃO FINAL DO PIPELINE               ║${RESET}"
    echo -e "${CIANO}${NEGRITO}╚══════════════════════════════════════════════════════════╝${RESET}"
    printf "  %-28s %s\n" "Modo selecionado:" "$component"
    printf "  %-28s %s\n" "Instalador:" "$INSTALLER_LABEL"
    printf "  %-28s %s\n" "Safe mode:" "$([[ "${SAFE_MODE:-0}" == "1" ]] && echo SIM || echo NÃO)"
    printf "  %-28s %s\n" "Beta/experimental:" "$([[ "${EXPERIMENTAL_OK:-0}" == "1" || "${BETA_MODE:-0}" == "1" ]] && echo SIM || echo NÃO)"
    printf "  %-28s %s\n" "Limpeza/wipe:" "$([[ "${CLEAN_INSTALL:-0}" == "1" || "${WIPE_MODE:-0}" == "1" ]] && echo SIM || echo NÃO)"
    [[ -n "${ZBX_VERSION:-${ZBX_TARGET_VERSION:-}}" ]] && printf "  %-28s %s\n" "Versão Zabbix:" "${ZBX_VERSION:-${ZBX_TARGET_VERSION:-}}"
    [[ -n "${PG_VER:-}" ]] && printf "  %-28s %s\n" "PostgreSQL:" "$PG_VER"
    [[ -n "${DB_HOST:-}" ]] && printf "  %-28s %s\n" "DB Host:Port:" "${DB_HOST}:${DB_PORT:-5432}"
    [[ -n "${DB_NAME:-}" ]] && printf "  %-28s %s\n" "DB Nome/User:" "${DB_NAME} / ${DB_USER:-}"
    [[ -n "${NGINX_PORT:-}" ]] && printf "  %-28s %s\n" "Frontend:" "$([[ "${USE_HTTPS:-0}" == "1" ]] && echo "HTTPS:${NGINX_PORT}" || echo "HTTP:${NGINX_PORT}")"
    [[ -n "${INSTALL_AGENT:-}" ]] && printf "  %-28s %s\n" "Agent 2:" "$([[ "$INSTALL_AGENT" == "1" ]] && echo SIM || echo NÃO)"
    [[ -n "${USE_PSK:-}" ]] && printf "  %-28s %s\n" "PSK:" "$([[ "$USE_PSK" == "1" ]] && echo SIM || echo NÃO)"
    if [[ "$component" == "proxy" || "$component" == "Proxy" ]]; then
        [[ -n "${PROXY_MODE:-}" ]] && printf "  %-28s %s\n" "Modo Proxy:" "$([[ "${PROXY_MODE:-0}" == "0" ]] && echo "ATIVO (Proxy conecta no Server)" || echo "PASSIVO (Server conecta no Proxy)")"
        [[ -n "${ZBX_SERVER:-}" ]] && printf "  %-28s %s\n" "Server/ServerActive:" "${ZBX_SERVER}"
        [[ -n "${ZBX_HOSTNAME:-}" ]] && printf "  %-28s %s\n" "Hostname do Proxy:" "${ZBX_HOSTNAME}"
    fi
    echo -e "\n${AMARELO}${NEGRITO}Para iniciar, digite CONTINUAR. Para cancelar, digite SAIR.${RESET}"
    while true; do
        read -rp "Confirmação: " ack
        if [[ "$ack" == "CONTINUAR" ]]; then
            break
        elif [[ "$ack" == "SAIR" ]]; then
            echo -e "${AMARELO}Instalação cancelada pelo operador.${RESET}"
            exit 0
        else
            echo -e "  ${VERMELHO}Entrada inválida: \"${ack}\"${RESET} — escreva ${NEGRITO}CONTINUAR${RESET} para iniciar ou ${NEGRITO}SAIR${RESET} para cancelar."
        fi
    done
}
preflight_install_check() {
    local component="$1" disk_mb="${2:-2048}" ram_mb="${3:-1024}"
    [[ "$SIMULATE_MODE" == "1" ]] && return 0
    echo -e "\n${CIANO}${NEGRITO}>>> PRÉ-CHECK DE INSTALAÇÃO <<<${RESET}"
    [[ "$EUID" -eq 0 ]] || {
        echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} execute como root/sudo."
        exit 1
    }
    component_supported_or_die "$component"
    check_disk_space "$disk_mb"
    check_min_ram "$ram_mb"
    check_system_clock
    echo -e "\n${CIANO}${NEGRITO}▸ Ambiente de rede${RESET}"
    print_environment_context
    warn_previous_installation "$component"
    echo -e "\n${CIANO}${NEGRITO}▸ Comandos obrigatórios${RESET}"
    check_required_commands apt-get apt-cache dpkg systemctl runuser openssl ip awk sed grep gzip
    check_bootstrap_downloader
    echo -e "\n${CIANO}${NEGRITO}▸ Portas críticas${RESET}"
    case "$component" in
    db) confirm_port_if_busy 5432 db "PostgreSQL" ;;
    server)
        confirm_port_if_busy 80 server "HTTP"
        confirm_port_if_busy 443 server "HTTPS"
        confirm_port_if_busy 10051 server "Zabbix Server"
        ;;
    proxy) confirm_port_if_busy 10051 proxy "Zabbix Proxy" ;;
    esac
}
run_wipe_mode() {
    local confirm remove_db="$WIPE_DB"
    clear
    echo -e "${VERMELHO}${NEGRITO}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${VERMELHO}${NEGRITO}║                 WIPE — LIMPEZA COMPLETA                  ║${RESET}"
    echo -e "${VERMELHO}${NEGRITO}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo -e "\n${AMARELO}${NEGRITO}Esta operação não cria backup.${RESET}"
    echo -e "  Vai parar serviços Zabbix, Nginx e PostgreSQL."
    echo -e "  Vai remover pacotes e diretórios dentro do escopo Zabbix/Nginx."
    if [[ "$remove_db" != "1" ]]; then
        ask_yes_no "Remover também PostgreSQL/TimescaleDB, bancos, usuários e dados?" remove_db
    fi
    if [[ "$remove_db" == "1" ]]; then
        echo -e "  ${VERMELHO}Inclui PostgreSQL/TimescaleDB e dados em /var/lib/postgresql.${RESET}"
    else
        echo -e "  ${AMARELO}PostgreSQL/TimescaleDB e dados da BD serão preservados.${RESET}"
    fi
    ask_yes_no "Confirmar execução do wipe agora?" confirm
    [[ "$confirm" == "1" ]] || {
        echo -e "\n${AMARELO}Wipe cancelado. Nenhuma alteração feita.${RESET}"
        exit 0
    }
    safe_confirm_cleanup "Wipe completo solicitado" \
        "serviços zabbix-server/zabbix-agent2/zabbix-proxy/nginx/postgresql" \
        "/etc/zabbix /var/log/zabbix /var/lib/zabbix /run/zabbix" \
        "$([[ "$remove_db" == "1" ]] && echo "/etc/postgresql /var/lib/postgresql /var/log/postgresql /run/postgresql" || echo "PostgreSQL preservado")"

    COMPONENT="wipe"
    init_install_log "wipe" "/var/log/zabbix_wipe_$(date +%Y%m%d_%H%M%S).log"
    TOTAL_STEPS=5
    [[ "$remove_db" == "1" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 2))

    run_step "Parando serviços Zabbix, Nginx e PostgreSQL" bash -c \
        "for svc in zabbix-server zabbix-agent2 zabbix-proxy nginx postgresql; do \
             timeout 15 systemctl stop \$svc 2>/dev/null || true; \
             systemctl disable \$svc 2>/dev/null || true; \
         done; \
         pkill -9 -x zabbix_server 2>/dev/null || true; \
         pkill -9 -x zabbix_agent2 2>/dev/null || true; \
         pkill -9 -x zabbix_proxy 2>/dev/null || true; \
         pkill -9 -x nginx 2>/dev/null || true"
    run_step "Destravando processos do APT" auto_repair_apt
    run_step "Removendo pacotes Zabbix e Nginx" bash -c \
        "dpkg -l 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^ii|^rc/ && \$2 ~ /^(zabbix|nginx)/ {print \$2}' | \
         xargs -r apt-mark unhold 2>/dev/null || true; \
         dpkg -l 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^ii|^rc/ && \$2 ~ /^(zabbix|nginx)/ {print \$2}' | \
         xargs -r apt-get purge -y 2>/dev/null || true"
    if [[ "$remove_db" == "1" ]]; then
        run_step "Removendo pacotes PostgreSQL e TimescaleDB" bash -c \
            "dpkg -l 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^ii|^rc/ && \$2 ~ /^(postgresql|timescaledb)/ {print \$2}' | \
             xargs -r apt-mark unhold 2>/dev/null || true; \
             dpkg -l 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^ii|^rc/ && \$2 ~ /^(postgresql|timescaledb)/ {print \$2}' | \
             xargs -r apt-get purge -y 2>/dev/null || true"
    fi
    run_step "Removendo diretórios Zabbix no escopo do instalador" bash -c \
        "rm -rf /etc/zabbix /var/log/zabbix /var/lib/zabbix /run/zabbix 2>/dev/null || true"
    if [[ "$remove_db" == "1" ]]; then
        run_step "Removendo dados e configurações PostgreSQL/TimescaleDB" bash -c \
            "rm -rf /etc/postgresql /var/lib/postgresql /var/log/postgresql /run/postgresql 2>/dev/null || true"
    fi
    run_step "Removendo resíduos de repositórios no escopo selecionado" bash -c \
        "rm -f /tmp/zbx_repo.deb /etc/apt/sources.list.d/zabbix*.list /etc/apt/sources.list.d/zabbix*.sources 2>/dev/null || true; \
         if [[ '${remove_db}' == '1' ]]; then \
             rm -f /etc/apt/sources.list.d/pgdg.list /etc/apt/sources.list.d/timescaledb.list \
                   /etc/apt/trusted.gpg.d/timescaledb.gpg \
                   /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc 2>/dev/null || true; \
         fi"

    CURRENT_STEP=$TOTAL_STEPS
    draw_progress "Wipe concluído ✔"
    printf "\n"
    echo -e "\n${VERDE}${NEGRITO}Wipe concluído.${RESET}"
    echo -e "${NEGRITO}Log completo:${RESET} ${LOG_FILE}\n"
}
run_check_mode() {
    clear
    echo -e "${CIANO}${NEGRITO}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CIANO}${NEGRITO}║             CHECK DO AMBIENTE — SEM ALTERAÇÕES           ║${RESET}"
    echo -e "${CIANO}${NEGRITO}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo -e "\n${CIANO}${NEGRITO}▸ SISTEMA${RESET}"
    echo -e "  Sistema: ${OS_DISPLAY}"
    echo -e "  RAM:    ${RAM_MB} MB"
    echo -e "  CPU:    ${CPU_CORES} núcleo(s)"
    if [[ "$EUID" -eq 0 ]]; then
        echo -e "  Root:   ${VERDE}SIM${RESET}"
    else
        echo -e "  Root:   ${AMARELO}NÃO — necessário apenas para instalar${RESET}"
    fi

    echo -e "\n${CIANO}${NEGRITO}▸ SUPORTE DO SISTEMA${RESET}"
    validate_supported_ubuntu_any_component
    echo -e "  ${VERDE}✔ Versão reconhecida pelo instalador${RESET}"
    echo -e "  DB:     $(is_component_supported db && echo "suportado" || echo "não suportado")"
    echo -e "  Server: $(is_component_supported server && echo "suportado" || echo "não suportado")"
    echo -e "  Proxy:  $(is_component_supported proxy && echo "suportado" || echo "não suportado")"

    echo -e "\n${CIANO}${NEGRITO}▸ COMANDOS NECESSÁRIOS${RESET}"
    local missing=0 cmd
    for cmd in apt-get apt-cache dpkg curl wget openssl ip awk sed grep gzip systemctl; do
        if type -P "$cmd" >/dev/null 2>&1; then
            echo -e "  ${VERDE}✔${RESET} $cmd"
        else
            echo -e "  ${VERMELHO}✖${RESET} $cmd não encontrado"
            missing=1
        fi
    done

    echo -e "\n${CIANO}${NEGRITO}▸ DISCO${RESET}"
    check_disk_space 2048

    echo -e "\n${CIANO}${NEGRITO}▸ CONECTIVIDADE BÁSICA${RESET}"
    for url in "https://repo.zabbix.com" "https://apt.postgresql.org" "https://packagecloud.io"; do
        if _curl -fsI --max-time 10 "$url" >/dev/null 2>&1; then
            echo -e "  ${VERDE}✔${RESET} $url acessível"
        else
            echo -e "  ${AMARELO}⚠${RESET} $url não respondeu ao teste rápido"
        fi
    done

    echo -e "\n${CIANO}${NEGRITO}▸ REPOSITÓRIO ZABBIX PARA ESTE SISTEMA (${OS_LABEL} ${U_VER})${RESET}"
    local zbx_ok=0
    for zbx_ver in "7.4" "7.0" "8.0"; do
        local test_url
        test_url="$(zabbix_release_url "$zbx_ver" 2>/dev/null || true)"
        [[ -z "$test_url" ]] && continue
        if _curl -fsI --max-time 10 "$test_url" >/dev/null 2>&1; then
            echo -e "  ${VERDE}✔${RESET} Zabbix ${zbx_ver} disponível para ${OS_LABEL} ${U_VER}"
            zbx_ok=1
        else
            echo -e "  ${AMARELO}⚠${RESET} Zabbix ${zbx_ver} pode não estar publicado para ${OS_LABEL} ${U_VER}"
        fi
    done
    [[ "$zbx_ok" == "0" ]] &&
        echo -e "  ${VERMELHO}${NEGRITO}Nenhuma versão Zabbix detectada para ${OS_LABEL} ${U_VER} — verifique antes de instalar.${RESET}"

    if [[ "$missing" == "1" ]]; then
        echo -e "\n${VERMELHO}${NEGRITO}Check concluído com pendências.${RESET}"
        exit 1
    fi
    echo -e "\n${VERDE}${NEGRITO}Check concluído. Nenhuma alteração foi feita.${RESET}\n"
}
run_self_test() {
    local tmpdir fail=0 warn=0 test_file out_file script_path
    tmpdir="$(mktemp -d /tmp/zabbix_self_test.XXXXXX)"
    test_file="${tmpdir}/test.conf"
    out_file="${tmpdir}/plain.txt"
    script_path="${BASH_SOURCE[0]:-$0}"

    _self_ok() {
        printf "  ${VERDE}✔${RESET} %s\n" "$1"
    }
    _self_warn() {
        printf "  ${AMARELO}⚠${RESET} %s\n" "$1"
        warn=$((warn + 1))
    }
    _self_fail() {
        printf "  ${VERMELHO}✖${RESET} %s\n" "$1"
        fail=$((fail + 1))
    }

    echo -e "${CIANO}${NEGRITO}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CIANO}${NEGRITO}║                    SELF-TEST DO INSTALADOR               ║${RESET}"
    echo -e "${CIANO}${NEGRITO}╚══════════════════════════════════════════════════════════╝${RESET}"
    printf "  %-28s %s\n" "Instalador:" "${INSTALLER_LABEL}"
    printf "  %-28s %s\n" "Sistema detectado:" "${OS_DISPLAY:-N/D}"
    printf "  %-28s %s\n" "Root:" "$([[ "$EUID" -eq 0 ]] && echo SIM || echo NÃO)"
    echo ""

    if [[ -f "$script_path" ]] && bash -n "$script_path" 2>/dev/null; then
        _self_ok "Sintaxe Bash do arquivo atual"
    else
        _self_fail "Sintaxe Bash do arquivo atual"
    fi

    local cmd
    for cmd in bash awk sed grep tr curl wget tar gzip mktemp; do
        if type -P "$cmd" >/dev/null 2>&1; then
            _self_ok "Comando disponível: ${cmd}"
        else
            _self_fail "Comando ausente: ${cmd}"
        fi
    done
    for cmd in timeout apt-get apt-cache dpkg systemctl journalctl ss ip runuser; do
        if type -P "$cmd" >/dev/null 2>&1; then
            _self_ok "Comando operacional disponível: ${cmd}"
        elif [[ "$OS_FAMILY" == "ubuntu" || "$OS_FAMILY" == "debian" ]]; then
            _self_fail "Comando obrigatório ausente em Ubuntu/Debian: ${cmd}"
        else
            _self_warn "Comando Linux ausente neste host não suportado: ${cmd}"
        fi
    done

    printf 'DBPassword=abc=def\n# DBPassword=ignored\nDBUser=zabbix\n' >"$test_file"
    if [[ "$(conf_value "$test_file" DBPassword)" == "abc=def" && "$(conf_value "$test_file" DBUser)" == "zabbix" ]]; then
        _self_ok "conf_value preserva valores com '=' e ignora comentários"
    else
        _self_fail "conf_value não preservou valor esperado"
    fi

    printf '\033[31mERRO\033[0m\r texto\001\n' | sanitize_plain_text >"$out_file"
    if LC_ALL=C awk 'BEGIN{bad=0} /ERRO texto/{seen=1} /[\001-\010\013\014\016-\037\177]/{bad=1} END{exit !(seen && !bad)}' "$out_file"; then
        _self_ok "sanitize_plain_text remove ANSI, CR e controles perigosos"
    else
        _self_fail "sanitize_plain_text não gerou texto limpo esperado"
    fi

    if [[ "$(safe_count_matches 'nao-existe' "$test_file")" == "0" ]]; then
        _self_ok "safe_count_matches retorna 0 sem abortar quando não há match"
    else
        _self_fail "safe_count_matches falhou em grep sem match"
    fi

    local escaped
    escaped="$(json_escape 'senha "com" \ barra')"
    if [[ "$escaped" == 'senha \"com\" \\ barra' ]]; then
        _self_ok "json_escape escapa aspas e barras"
    else
        _self_fail "json_escape retornou valor inesperado"
    fi

    if ! validate_proxy_server_value "0" "0" "Server do Proxy" >/dev/null 2>&1 &&
        ! validate_proxy_server_value "127.0.0.1" "0" "Server do Proxy" >/dev/null 2>&1 &&
        ! validate_proxy_server_value "localhost" "0" "Server do Proxy" >/dev/null 2>&1 &&
        validate_proxy_server_value "10.1.30.111" "0" "Server do Proxy" >/dev/null 2>&1; then
        _self_ok "Proxy ativo rejeita destinos locais e aceita IP real"
    else
        _self_fail "Validação do Server do Proxy ativo falhou"
    fi

    case "$OS_FAMILY" in
    ubuntu | debian)
        _self_ok "Sistema reconhecido como suportável: ${OS_DISPLAY}"
        ;;
    rhel)
        _self_warn "Sistema RHEL detectado; fluxos ainda abortam de forma controlada"
        ;;
    *)
        _self_warn "Sistema não suportado detectado: ${OS_DISPLAY}"
        ;;
    esac

    if [[ "${RAM_MB:-0}" =~ ^[0-9]+$ && "${CPU_CORES:-0}" =~ ^[0-9]+$ ]]; then
        _self_ok "Detecção básica de hardware: ${RAM_MB} MB RAM, ${CPU_CORES} CPU"
    else
        _self_warn "Detecção de hardware incompleta"
    fi

    echo -e "\n${CIANO}${NEGRITO}▸ URLs oficiais${RESET}"
    printf "  %-28s %s\n" "Latest:" "https://raw.githubusercontent.com/denysg001/zabbix-unified-installer/main/AUTOMACAO-ZBX-UNIFIED.sh"
    printf "  %-28s %s\n" "v5.5 fixa:" "https://raw.githubusercontent.com/denysg001/zabbix-unified-installer/v5.5/AUTOMACAO-ZBX-UNIFIED.sh"

    rm -rf "$tmpdir"

    echo -e "\n${CIANO}${NEGRITO}▸ RESULTADO${RESET}"
    if [[ "$fail" -gt 0 ]]; then
        printf "  ${VERMELHO}${NEGRITO}%-18s${RESET} %s falha(s), %s aviso(s)\n" "FALHOU" "$fail" "$warn"
        exit 1
    fi
    if [[ "$warn" -gt 0 ]]; then
        printf "  ${AMARELO}${NEGRITO}%-18s${RESET} %s aviso(s), nenhuma falha\n" "COM AVISOS" "$warn"
    else
        printf "  ${VERDE}${NEGRITO}%-18s${RESET} Nenhuma falha encontrada\n" "OK"
    fi
    echo -e "\n${VERDE}${NEGRITO}Self-test concluído. Nenhuma alteração foi feita.${RESET}\n"
}
debug_one_service() {
    local service="$1"
    echo -e "\n${CIANO}${NEGRITO}▸ ${service}${RESET}"
    if ! timeout 10 systemctl cat "${service}.service" >/dev/null 2>&1; then
        echo -e "  ${AMARELO}⚠ Serviço não encontrado; continuando.${RESET}"
        return 0
    fi
    safe_diag_cmd systemctl status "$service" --no-pager | sed -n '1,18p' | sed 's/^/  /' || true
    echo -e "  ${AMARELO}journalctl:${RESET}"
    safe_diag_cmd journalctl -u "$service" -n 20 --no-pager | sed 's/^/    /' || true
}
run_debug_services() {
    local php_svc
    clear
    echo -e "${CIANO}${NEGRITO}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CIANO}${NEGRITO}║              DEBUG SERVICES — SEM ALTERAÇÕES             ║${RESET}"
    echo -e "${CIANO}${NEGRITO}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo -e "\n${CIANO}${NEGRITO}▸ SISTEMA${RESET}"
    echo -e "  Sistema: ${OS_DISPLAY}"
    print_environment_context
    local php_svcs
    readarray -t php_svcs < <(systemctl list-units 'php*-fpm.service' --no-legend --no-pager 2>/dev/null | awk '{print $1}' | sed 's/\.service$//' || true)
    for svc in postgresql zabbix-server nginx zabbix-proxy zabbix-agent2; do
        debug_one_service "$svc"
    done
    if [[ "${#php_svcs[@]}" -gt 0 ]]; then
        for svc in "${php_svcs[@]}"; do
            [[ -n "$svc" ]] && debug_one_service "$svc"
        done
    else
        debug_one_service "php-fpm"
    fi
    echo -e "\n${CIANO}${NEGRITO}▸ PORTAS RELACIONADAS${RESET}"
    if command -v ss >/dev/null 2>&1; then
        ss -tulnp 2>/dev/null | awk '
            NR==1 { print; next }
            {
                for (i=1; i<=NF; i++) {
                    if (match($i, /^[0-9.*\[\]:]+:([0-9]+)$/, a) || match($i, /:([0-9]+)$/, a)) {
                        p = a[1]
                        if (p==80||p==443||p==5432||p==10050||p==10051||p==8080||p==8443) { print; break }
                    }
                }
            }
        ' | sed 's/^/  /' || true
    else
        echo -e "  ${AMARELO}⚠ ss não disponível.${RESET}"
    fi
    echo -e "\n${CIANO}${NEGRITO}▸ PROCESSOS RELACIONADOS${RESET}"
    ps aux 2>/dev/null | awk 'NR==1 || /zabbix|postgres|nginx|php.*fpm/' | sed 's/^/  /' || true
    echo -e "\n${VERDE}${NEGRITO}Debug concluído. Nenhuma alteração foi feita.${RESET}\n"
}
collect_support_bundle() {
    local stamp bundle tmpdir files_dir logs_dir configs_dir f svc
    stamp=$(date +%Y%m%d_%H%M%S)
    bundle="/root/zabbix_support_bundle_${stamp}.tar.gz"
    tmpdir="$(mktemp -d /tmp/zabbix_support_bundle.XXXXXX)"
    files_dir="${tmpdir}/files"
    logs_dir="${tmpdir}/logs"
    configs_dir="${tmpdir}/configs"
    mkdir -p "$files_dir" "$logs_dir" "$configs_dir"
    chmod 700 "$tmpdir" "$files_dir" "$logs_dir" "$configs_dir" 2>/dev/null || true

    {
        echo "Zabbix Unified Installer - Support Bundle"
        echo "Gerado em: $(date -Is 2>/dev/null || date)"
        echo "Instalador: ${INSTALLER_LABEL:-AUTOMACAO-ZBX-UNIFIED}"
        echo "Sistema: ${OS_DISPLAY:-N/D}"
        echo "Kernel: $(uname -a 2>/dev/null || echo N/D)"
        echo "Hostname: $(hostname 2>/dev/null || echo N/D)"
        echo "Usuario efetivo: ${EUID}"
        echo
        echo "ATENCAO: este pacote pode conter credenciais, PSKs e dados sensiveis."
        echo "Use apenas para suporte e armazene com permissao restrita."
    } >"${tmpdir}/README_SUPORTE.txt"

    {
        echo "== Sistema =="
        timeout 10 uname -a 2>/dev/null || true
        [[ -r /etc/os-release ]] && timeout 10 sed -n '1,80p' /etc/os-release 2>/dev/null || true
        echo
        echo "== Data/hora =="
        timeout 10 date -Is 2>/dev/null || date 2>/dev/null || true
        timeout 10 timedatectl 2>/dev/null || true
        echo
        echo "== Recursos =="
        timeout 10 free -m 2>/dev/null || true
        timeout 10 df -hT 2>/dev/null || true
        echo
        echo "== Rede =="
        timeout 10 ip addr 2>/dev/null || true
        timeout 10 ip route 2>/dev/null || true
    } >"${tmpdir}/system.txt"

    {
        echo "== Servicos =="
        for svc in postgresql zabbix-server zabbix-proxy zabbix-agent2 nginx php-fpm php8.1-fpm php8.2-fpm php8.3-fpm php8.4-fpm php8.5-fpm; do
            echo
            echo "### ${svc}"
            timeout 10 systemctl status "$svc" --no-pager 2>/dev/null || true
        done
    } >"${tmpdir}/services.txt"

    {
        echo "== Portas =="
        timeout 10 ss -tulnp 2>/dev/null || true
        echo
        echo "== Processos relacionados =="
        timeout 10 ps aux 2>/dev/null | awk 'NR==1 || /zabbix|postgres|nginx|php.*fpm/' || true
    } >"${tmpdir}/ports_processes.txt"

    {
        echo "== Pacotes relacionados =="
        timeout 20 dpkg -l 2>/dev/null | awk '/^ii|^rc/ && $2 ~ /(zabbix|postgresql|timescaledb|nginx|php)/ {print}' || true
        echo
        echo "== APT sources relacionadas =="
        timeout 10 ls -la /etc/apt/sources.list.d 2>/dev/null || true
        timeout 10 grep -RHiE 'zabbix|postgresql|timescale|ondrej' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true
    } >"${tmpdir}/packages_repos.txt"

    for f in \
        /root/zabbix_install_error.json \
        /root/zabbix_install_summary.txt \
        /root/zabbix_install_summary_plain.txt \
        /root/zabbix_install_summary.json \
        /root/zabbix_doctor_report.txt \
        /var/log/zabbix-install/full.log \
        /var/log/zabbix-install/db.log \
        /var/log/zabbix-install/server.log \
        /var/log/zabbix-install/proxy.log; do
        if [[ -f "$f" ]]; then
            timeout 10 tail -n 500 "$f" >"${files_dir}/$(basename "$f").tail" 2>/dev/null || true
        fi
    done

    for f in \
        /etc/zabbix/zabbix_server.conf \
        /etc/zabbix/zabbix_proxy.conf \
        /etc/zabbix/zabbix_agent2.conf \
        /etc/zabbix/nginx.conf; do
        if [[ -f "$f" ]]; then
            timeout 10 sed -n '1,260p' "$f" >"${configs_dir}/$(basename "$f")" 2>/dev/null || true
        fi
    done

    for svc in postgresql zabbix-server zabbix-proxy zabbix-agent2 nginx; do
        timeout 15 journalctl -u "$svc" --no-pager -n 200 >"${logs_dir}/${svc}.journal.txt" 2>/dev/null || true
    done
    for f in \
        /var/log/zabbix/zabbix_server.log \
        /var/log/zabbix/zabbix_proxy.log \
        /var/log/zabbix/zabbix_agent2.log \
        /var/log/nginx/error.log \
        /var/log/nginx/access.log \
        /var/log/postgresql/*.log; do
        [[ -f "$f" ]] || continue
        timeout 10 tail -n 500 "$f" >"${logs_dir}/$(basename "$f").tail" 2>/dev/null || true
    done

    {
        echo "{"
        printf '  "created_at": "%s",\n' "$(date -Is 2>/dev/null || date)"
        printf '  "installer_version": "%s",\n' "${INSTALLER_VERSION:-unknown}"
        printf '  "host": "%s",\n' "$(hostname 2>/dev/null || echo unknown)"
        printf '  "bundle": "%s",\n' "$bundle"
        printf '  "contains_sensitive_data": true\n'
        echo "}"
    } >"${tmpdir}/manifest.json"

    if ! command -v tar >/dev/null 2>&1; then
        echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} comando tar não encontrado; não foi possível gerar o pacote."
        rm -rf "$tmpdir"
        exit 1
    fi
    tar -czf "$bundle" -C "$tmpdir" . 2>/dev/null
    chmod 600 "$bundle" 2>/dev/null || true
    rm -rf "$tmpdir"

    echo -e "\n${VERDE}${NEGRITO}Pacote de suporte gerado com sucesso.${RESET}"
    printf "  %-34s %s\n" "Arquivo:" "$bundle"
    printf "  %-34s %s\n" "Permissão:" "600"
    echo -e "  ${AMARELO}Atenção:${RESET} este pacote pode conter credenciais e PSKs."
    echo -e "  Envie este arquivo quando precisar analisar erro de instalação ou diagnóstico.\n"
}
show_dry_run_plan() {
    local component="$1"
    clear
    echo -e "${CIANO}${NEGRITO}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CIANO}${NEGRITO}║                  DRY-RUN — PLANO DE AÇÃO                ║${RESET}"
    echo -e "${CIANO}${NEGRITO}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo -e "\n${CIANO}${NEGRITO}▸ SISTEMA${RESET}"
    echo -e "  Sistema: ${OS_DISPLAY}"
    echo -e "  RAM:    ${RAM_MB} MB"
    echo -e "  CPU:    ${CPU_CORES} núcleo(s)"
    echo -e "\n${AMARELO}${NEGRITO}Nenhuma alteração será feita neste modo.${RESET}"
    echo -e "\n${CIANO}${NEGRITO}▸ COMPONENTE${RESET}"
    case "$component" in
    db)
        echo -e "  Base de Dados"
        echo -e "  Removeria vestígios de PostgreSQL/TimescaleDB se detectados."
        echo -e "  Prepararia PGDG, avaliaria TimescaleDB e instalaria PostgreSQL 17/18."
        echo -e "  Criaria base, utilizador, pg_hba.conf e tuning conforme respostas do operador."
        ;;
    server)
        echo -e "  Servidor"
        echo -e "  Removeria vestígios de Zabbix Server/Nginx se detectados."
        echo -e "  Prepararia PGDG/Zabbix, instalaria Server, Frontend, Nginx, PHP-FPM e scripts SQL."
        echo -e "  Importaria schema quando a BD estivesse vazia e configuraria frontend/serviços."
        ;;
    proxy)
        echo -e "  Proxy"
        echo -e "  Removeria vestígios de Zabbix Proxy/Agent se detectados."
        echo -e "  Prepararia repositório Zabbix, instalaria Proxy SQLite3 e Agent 2 se escolhido."
        echo -e "  Aplicaria modo ativo/passivo, PSK e tuning conforme respostas do operador."
        ;;
    esac
    echo -e "\n${CIANO}${NEGRITO}▸ VALIDAÇÕES QUE O MODO NORMAL FARÁ${RESET}"
    echo -e "  Espaço livre em disco, versão do sistema, repositórios, pacotes, serviços e portas."
    [[ "$component" == "server" ]] && echo -e "  O Server também testará resposta HTTP/HTTPS local do frontend."
    echo -e "\n${VERDE}${NEGRITO}Dry-run concluído. Nada foi instalado, removido ou alterado.${RESET}\n"
}
finish_simulation() {
    CURRENT_STEP=$TOTAL_STEPS
    draw_progress "Simulação concluída ✔"
    printf '\n\n%bSimulação concluída. Nada foi instalado, removido ou alterado.%b\n' "${VERDE}${NEGRITO}" "$RESET"
    exit 0
}
doctor_psql_with_pgpass() {
    local host="$1" port="$2" db="$3" user="$4" pass="$5" query="$6"
    type -P psql >/dev/null 2>&1 || {
        echo -e "  ${AMARELO}⚠ psql não encontrado neste host.${RESET}"
        return 1
    }
    local pgpass_file pgpass_pass psql_bin
    psql_bin="$(type -P psql 2>/dev/null || true)"
    [[ -n "$psql_bin" ]] || {
        echo -e "  ${AMARELO}⚠ binário psql não encontrado neste host.${RESET}"
        return 1
    }
    pgpass_file=$(mktemp)
    # Garante remoção do ficheiro com senha em qualquer saída (normal, ERR, Ctrl+C)
    # shellcheck disable=SC2064
    trap "rm -f '${pgpass_file}'" RETURN
    pgpass_pass=$(pgpass_escape "$pass")
    echo "${host}:${port}:*:${user}:${pgpass_pass}" >"$pgpass_file"
    chmod 0600 "$pgpass_file"
    PGPASSFILE="$pgpass_file" PGCONNECT_TIMEOUT=5 timeout 10 "$psql_bin" -h "$host" -p "$port" -U "$user" -d "$db" -tAc "$query" 2>/dev/null
}
doctor_db_connection_from_server_conf() {
    local conf="/etc/zabbix/zabbix_server.conf"
    if [[ ! -f "$conf" ]]; then
        echo -e "  ${AMARELO}⚠ ${conf} não encontrado; teste de BD ignorado.${RESET}"
        return 0
    fi
    local host port db user pass schema
    host=$(conf_value "$conf" "DBHost")
    host=${host:-localhost}
    port=$(conf_value "$conf" "DBPort")
    port=${port:-5432}
    db=$(conf_value "$conf" "DBName")
    db=${db:-zabbix}
    user=$(conf_value "$conf" "DBUser")
    user=${user:-zabbix}
    pass=$(conf_value "$conf" "DBPassword")
    echo -e "\n${CIANO}${NEGRITO}▸ TESTE REAL DA BASE DE DADOS${RESET}"
    if schema=$(doctor_psql_with_pgpass "$host" "$port" "$db" "$user" "$pass" "SELECT mandatory FROM dbversion LIMIT 1;"); then
        schema=$(echo "$schema" | xargs)
        echo -e "  ${VERDE}✔${RESET} Conexão PostgreSQL OK (${user}@${host}:${port}/${db})"
        echo -e "  ${VERDE}✔${RESET} Schema Zabbix dbversion: ${schema:-não informado}"
    else
        echo -e "  ${AMARELO}⚠${RESET} Falha ao conectar na BD com ${conf}"
        [[ "${DOCTOR_ACTIVE:-0}" == "1" ]] && DOCTOR_WARN=$((DOCTOR_WARN + 1))
    fi
}
run_doctor_mode() {
    local component="$1"
    set +e
    DOCTOR_ACTIVE=1
    DOCTOR_WARN=0
    DOCTOR_FAIL=0
    clear
    [[ "$DOCTOR_EXPORT" == "1" ]] && start_doctor_export "$component"
    echo -e "${CIANO}${NEGRITO}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CIANO}${NEGRITO}║              DOCTOR — DIAGNÓSTICO PÓS-INSTALAÇÃO         ║${RESET}"
    echo -e "${CIANO}${NEGRITO}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo -e "\n${CIANO}${NEGRITO}▸ SISTEMA${RESET}"
    echo -e "  Sistema: ${OS_DISPLAY}"
    echo -e "  RAM:    ${RAM_MB} MB"
    echo -e "  CPU:    ${CPU_CORES} núcleo(s)"
    doctor_show_last_installer_version
    echo -e "\n${CIANO}${NEGRITO}▸ COMPONENTE: ${component}${RESET}"
    LOG_FILE=""
    case "$component" in
    db)
        if postgres_is_ready "${PG_VER:-}" "${PG_CLUSTER_NAME:-main}"; then
            echo -e "  ${VERDE}✔${RESET} PostgreSQL: pronto/respondendo"
        else
            echo -e "  ${AMARELO}⚠${RESET} PostgreSQL: não respondeu ao diagnóstico local"
            echo -e "  Diagnóstico: journalctl -u postgresql -n 80 --no-pager"
            print_service_journal_tail "postgresql@${PG_VER:-17}-${PG_CLUSTER_NAME:-main}" 20
            print_service_journal_tail postgresql 20
            DOCTOR_WARN=$((DOCTOR_WARN + 1))
        fi
        if pkg_is_installed "postgresql" || pkg_is_installed "postgresql-${PG_VER:-17}"; then
            echo -e "  ${VERDE}✔${RESET} Pacote PostgreSQL instalado"
        else
            echo -e "  ${AMARELO}⚠${RESET} Pacote PostgreSQL não identificado pelo gestor de pacotes"
            DOCTOR_WARN=$((DOCTOR_WARN + 1))
        fi
        check_tcp_listen 5432 "PostgreSQL"
        if [[ -f /etc/zabbix/zabbix_agent2.conf || -f /etc/zabbix/zabbix_agent2.psk ]]; then
            validate_service_active zabbix-agent2
            echo -e "\n${CIANO}${NEGRITO}▸ AGENT 2 DA BASE DE DADOS${RESET}"
            printf "  %-18s %s\n" "Hostname:" "$(conf_value /etc/zabbix/zabbix_agent2.conf Hostname)"
            printf "  %-18s %s\n" "Server:" "$(conf_value /etc/zabbix/zabbix_agent2.conf Server)"
            printf "  %-18s %s\n" "ServerActive:" "$(conf_value /etc/zabbix/zabbix_agent2.conf ServerActive)"
            [[ -f /etc/zabbix/zabbix_agent2.psk ]] &&
                echo -e "  ${VERDE}✔${RESET} PSK configurado (/etc/zabbix/zabbix_agent2.psk)" ||
                echo -e "  ${AMARELO}⚠${RESET} PSK não configurado"
        fi
        if type -P psql >/dev/null 2>&1; then
            postgres_psql_timeout 10 -tAc "SELECT version();" 2>/dev/null | sed 's/^/  PostgreSQL: /' || true
            echo -e "\n${CIANO}${NEGRITO}▸ TIMESCALEDB${RESET}"
            local tsdb_info tsdb_db
            # Determina o nome da BD: lê do zabbix_server.conf se existir, senão usa "zabbix"
            tsdb_db="zabbix"
            [[ -f /etc/zabbix/zabbix_server.conf ]] &&
                tsdb_db=$(timeout 10 awk -F'=' '/^DBName[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2}' \
                    /etc/zabbix/zabbix_server.conf 2>/dev/null | head -1 || true)
            [[ -z "$tsdb_db" ]] && tsdb_db="zabbix"
            tsdb_info=$(postgres_psql_timeout 10 -d "$tsdb_db" -tAc \
                "SELECT extname || ' ' || extversion FROM pg_extension WHERE extname='timescaledb';" \
                2>/dev/null | xargs || true)
            if [[ -n "$tsdb_info" ]]; then
                echo -e "  ${VERDE}✔${RESET} Extensão carregada: ${tsdb_info} (BD: ${tsdb_db})"
            else
                echo -e "  ${AMARELO}⚠${RESET} Extensão timescaledb não encontrada na BD '${tsdb_db}'"
                DOCTOR_WARN=$((DOCTOR_WARN + 1))
            fi
        else
            echo -e "  ${AMARELO}⚠ psql não encontrado para diagnóstico local.${RESET}"
            DOCTOR_WARN=$((DOCTOR_WARN + 1))
        fi
        ;;
    server)
        validate_service_active zabbix-server
        validate_service_active nginx
        local php_svc
        php_svc=$(safe_diag_cmd systemctl list-units 'php*-fpm.service' --no-legend --no-pager | awk '{print $1}' | head -1 || true)
        if [[ -n "$php_svc" ]]; then
            validate_service_active "${php_svc%.service}"
        else
            echo -e "  ${AMARELO}⚠ Serviço php-fpm não detectado.${RESET}"
            DOCTOR_WARN=$((DOCTOR_WARN + 1))
        fi
        check_tcp_listen 10051 "Zabbix Server"
        NGINX_PORT=$(timeout 10 awk '/^[[:space:]]*listen[[:space:]]+[0-9]+/ { for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+/) { gsub(/[^0-9]/,"",$i); print $i; exit } }' /etc/zabbix/nginx.conf 2>/dev/null || true)
        NGINX_PORT="${NGINX_PORT:-80}"
        USE_HTTPS=0
        timeout 10 grep -qE "^[[:space:]]*listen[[:space:]]+${NGINX_PORT}[[:space:]]+ssl" /etc/zabbix/nginx.conf 2>/dev/null && USE_HTTPS=1 || true
        check_tcp_listen "$NGINX_PORT" "Frontend/Nginx"
        check_frontend_http
        doctor_db_connection_from_server_conf
        printf "  %-34s %s\n" "Versão PHP ativa:" "$(php -v 2>/dev/null | head -1 || echo N/D)"
        if [[ -f /etc/zabbix/zabbix_agent2.conf ]]; then
            echo -e "\n${CIANO}${NEGRITO}▸ AGENT 2 DO SERVIDOR${RESET}"
            validate_service_active zabbix-agent2
            printf "  %-18s %s\n" "Hostname:" "$(conf_value /etc/zabbix/zabbix_agent2.conf Hostname)"
            printf "  %-18s %s\n" "Server:" "$(conf_value /etc/zabbix/zabbix_agent2.conf Server)"
            printf "  %-18s %s\n" "ServerActive:" "$(conf_value /etc/zabbix/zabbix_agent2.conf ServerActive)"
            [[ -f /etc/zabbix/zabbix_agent2.psk ]] &&
                echo -e "  ${VERDE}✔${RESET} PSK configurado (/etc/zabbix/zabbix_agent2.psk)" ||
                echo -e "  ${AMARELO}⚠${RESET} PSK não configurado"
        fi
        ;;
    proxy)
        validate_service_active zabbix-proxy
        check_tcp_listen 10051 "Zabbix Proxy"
        [[ -f /etc/zabbix/zabbix_proxy.conf ]] && {
            echo -e "\n${CIANO}${NEGRITO}▸ PROXY CONFIG${RESET}"
            printf "  %-18s %s\n" "Server:" "$(conf_value /etc/zabbix/zabbix_proxy.conf Server)"
            printf "  %-18s %s\n" "Hostname:" "$(conf_value /etc/zabbix/zabbix_proxy.conf Hostname)"
            printf "  %-18s %s\n" "ProxyMode:" "$(conf_value /etc/zabbix/zabbix_proxy.conf ProxyMode)"
            check_proxy_server_connectivity "$(conf_value /etc/zabbix/zabbix_proxy.conf Server)" "$(conf_value /etc/zabbix/zabbix_proxy.conf ProxyMode)"
        }
        if [[ -f /etc/zabbix/zabbix_agent2.conf ]]; then
            local proxy_mode agent_server agent_server_active
            proxy_mode="$(conf_value /etc/zabbix/zabbix_proxy.conf ProxyMode)"
            agent_server="$(conf_value /etc/zabbix/zabbix_agent2.conf Server)"
            agent_server_active="$(conf_value /etc/zabbix/zabbix_agent2.conf ServerActive)"
            echo -e "\n${CIANO}${NEGRITO}▸ AGENT 2 DO PROXY${RESET}"
            validate_service_active zabbix-agent2
            printf "  %-18s %s\n" "Hostname:" "$(conf_value /etc/zabbix/zabbix_agent2.conf Hostname)"
            printf "  %-18s %s\n" "Server:" "$agent_server"
            printf "  %-18s %s\n" "ServerActive:" "$agent_server_active"
            if [[ "$proxy_mode" == "0" ]]; then
                validate_proxy_server_value "$agent_server" "$proxy_mode" "Server do Agent 2" >/dev/null 2>&1 || {
                    echo -e "  ${AMARELO}⚠${RESET} Server do Agent 2 aponta para destino local/inválido em Proxy ativo."
                    DOCTOR_WARN=$((DOCTOR_WARN + 1))
                }
                validate_proxy_server_value "$agent_server_active" "$proxy_mode" "ServerActive do Agent 2" >/dev/null 2>&1 || {
                    echo -e "  ${AMARELO}⚠${RESET} ServerActive do Agent 2 aponta para destino local/inválido em Proxy ativo."
                    DOCTOR_WARN=$((DOCTOR_WARN + 1))
                }
            fi
            [[ -f /etc/zabbix/zabbix_agent2.psk ]] &&
                echo -e "  ${VERDE}✔${RESET} PSK configurado (/etc/zabbix/zabbix_agent2.psk)" ||
                echo -e "  ${AMARELO}⚠${RESET} PSK não configurado"
        fi
        ;;
    esac
    doctor_scan_common_log_errors "$component"
    echo -e "\n${CIANO}${NEGRITO}▸ RESULTADO DO DOCTOR${RESET}"
    if [[ "$DOCTOR_FAIL" -gt 0 ]]; then
        DOCTOR_WARN=$((DOCTOR_WARN + DOCTOR_FAIL))
        printf "  ${AMARELO}${NEGRITO}%-18s${RESET} %s aviso(s)\n" "COM AVISOS" "$DOCTOR_WARN"
    elif [[ "$DOCTOR_WARN" -gt 0 ]]; then
        printf "  ${AMARELO}${NEGRITO}%-18s${RESET} %s aviso(s)\n" "COM AVISOS" "$DOCTOR_WARN"
    else
        printf "  ${VERDE}${NEGRITO}%-18s${RESET} Nenhuma falha encontrada\n" "OK"
    fi
    DOCTOR_ACTIVE=0
    echo -e "\n${VERDE}${NEGRITO}Doctor concluído. Nenhuma alteração foi feita.${RESET}\n"
}
