# shellcheck shell=bash

VALIDATION_CACHE_DIR="/tmp/zbx_validation_cache"
ERROR_JSON="/root/zabbix_install_error.json"
TSDB_TUNE_STATUS="não executado"
INSTALL_WARNINGS=()
CURRENT_STEP=0
TOTAL_STEPS=1
# Logging, progress, certificates, and diagnostic helpers.
mask_secret() {
    local s="${1:-}"
    [[ -z "$s" ]] && {
        echo ""
        return
    }
    if ((${#s} <= 8)); then
        echo "********"
    else
        echo "${s:0:4}********${s: -4}"
    fi
}
redact_known_secrets() {
    local text="${1:-}" name value masked
    for name in DB_PASS PSK_AGENT_KEY PSK_PROXY_KEY PGPASSWORD; do
        value="${!name-}"
        [[ -n "$value" && ${#value} -ge 4 ]] || continue
        masked="$(mask_secret "$value")"
        text="${text//"$value"/"$masked"}"
    done
    printf '%s' "$text"
}
write_error_json() {
    local exit_code="${1:-1}" line_no="${2:-0}" cmd="${3:-comando desconhecido}" tmp_file
    local esc_cmd esc_component esc_log
    cmd="$(redact_known_secrets "$cmd")"
    esc_cmd=${cmd//\\/\\\\}
    esc_cmd=${esc_cmd//\"/\\\"}
    esc_component=${COMPONENT:-geral}
    esc_component=${esc_component//\\/\\\\}
    esc_component=${esc_component//\"/\\\"}
    esc_log=${LOG_FILE:-}
    esc_log=${esc_log//\\/\\\\}
    esc_log=${esc_log//\"/\\\"}
    tmp_file="$(mktemp /tmp/zabbix_install_error.XXXXXX 2>/dev/null || echo /tmp/zabbix_install_error.$$)"
    {
        echo "{"
        printf '  "timestamp": "%s",\n' "$(date -Is 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"
        printf '  "installer_version": "%s",\n' "${INSTALLER_VERSION:-v5.5}"
        printf '  "component": "%s",\n' "$esc_component"
        printf '  "exit_code": %s,\n' "$exit_code"
        printf '  "line": %s,\n' "$line_no"
        printf '  "command": "%s",\n' "$esc_cmd"
        printf '  "log_file": "%s",\n' "$esc_log"
        printf '  "hint": "%s"\n' "Leia o log indicado e rode o modo --doctor; comandos de diagnóstico usam timeout para não travar."
        echo "}"
    } >"$tmp_file" 2>/dev/null || true
    install -m 600 "$tmp_file" "$ERROR_JSON" 2>/dev/null || cp "$tmp_file" "$ERROR_JSON" 2>/dev/null || true
    rm -f "$tmp_file" 2>/dev/null || true
}
print_file_guide() {
    local context="${1:-geral}"
    echo -e "\n${CIANO}${NEGRITO}▸ ONDE CONFERIR DEPOIS${RESET}"
    case "$context" in
    error)
        printf "  %-34s %s\n" "Se deu erro fatal:" "$ERROR_JSON"
        printf "  %-34s %s\n" "Log detalhado:" "${LOG_FILE:-não definido nesta etapa}"
        printf "  %-34s %s\n" "O que enviar ao suporte:" "primeiro o JSON; se pedir, envie também o log detalhado"
        ;;
    install)
        printf "  %-34s %s\n" "Resumo completo colorido:" "/root/zabbix_install_summary.txt"
        printf "  %-34s %s\n" "Resumo limpo para copiar/cat:" "/root/zabbix_install_summary_plain.txt"
        printf "  %-34s %s\n" "Resumo estruturado JSON:" "/root/zabbix_install_summary.json"
        printf "  %-34s %s\n" "Se algo falhar depois:" "$ERROR_JSON"
        printf "  %-34s %s\n" "Log detalhado:" "${LOG_FILE:-não definido nesta etapa}"
        ;;
    doctor)
        printf "  %-34s %s\n" "Relatório do Doctor:" "/root/zabbix_doctor_report.txt"
        printf "  %-34s %s\n" "Se o Doctor apontar problema:" "envie este relatório primeiro"
        printf "  %-34s %s\n" "Se houve erro fatal:" "$ERROR_JSON"
        ;;
    esac
}
safe_count_matches() {
    local pattern="$1" file="$2" count
    count=$(timeout 10 grep -iE -c "$pattern" "$file" 2>/dev/null || echo 0)
    count=$(printf '%s' "$count" | awk 'NR==1{gsub(/[^0-9]/,""); print ($0=="" ? 0 : $0)}')
    printf '%s\n' "${count:-0}"
}
sanitize_plain_text() {
    local tmp
    tmp="$(mktemp /tmp/zabbix_sanitize.XXXXXX 2>/dev/null || echo /tmp/zabbix_sanitize.$$)"
    LC_ALL=C awk '{
        gsub(/\033\[[0-9;?]*[ -\/]*[@-~]/, "")
        gsub(/\r/, "")
        gsub(/[\001-\010\013\014\016-\037\177]/, "")
        print
    }' >"$tmp" 2>/dev/null || true
    if command -v iconv >/dev/null 2>&1; then
        iconv -f UTF-8 -t UTF-8 -c "$tmp" 2>/dev/null || cat "$tmp" 2>/dev/null || true
    else
        cat "$tmp" 2>/dev/null || true
    fi
    rm -f "$tmp" 2>/dev/null || true
}
log_msg() {
    local level="$1"
    shift
    local message="$*"
    [[ -n "${LOG_FILE:-}" ]] && printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$message" >>"$LOG_FILE" 2>/dev/null || true
    [[ -n "${FULL_LOG:-}" ]] && printf '[%s] [%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "${COMPONENT:-geral}" "$message" >>"$FULL_LOG" 2>/dev/null || true
}
init_install_log() {
    local component="$1" legacy_path="$2"
    LOG_DIR="/var/log/zabbix-install"
    FULL_LOG="${LOG_DIR}/full.log"
    COMPONENT_LOG="${LOG_DIR}/${component}.log"
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    chmod 700 "$LOG_DIR" 2>/dev/null || true
    : >"$COMPONENT_LOG" 2>/dev/null || true
    touch "$FULL_LOG" 2>/dev/null || true
    chmod 600 "$COMPONENT_LOG" "$FULL_LOG" 2>/dev/null || true
    LOG_FILE="$legacy_path"
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/$(basename "$legacy_path")"
    ln -sf "$LOG_FILE" "$COMPONENT_LOG" 2>/dev/null || true
    log_msg "INFO" "Log organizado: LOG_FILE=${LOG_FILE}; COMPONENT_LOG=${COMPONENT_LOG}; FULL_LOG=${FULL_LOG}"
}
check_tcp_listen() {
    local port="$1" label="$2"
    if command -v ss >/dev/null 2>&1; then
        if timeout 10 ss -ltn 2>/dev/null | awk -v p="$port" '$4 ~ "(^|:)" p "$" { found=1 } END { exit !found }'; then
            echo -e "  ${VERDE}✔${RESET} ${label}: porta ${port}/TCP em escuta"
            log_msg "OK" "${label}: porta ${port}/TCP em escuta"
        else
            echo -e "  ${AMARELO}⚠${RESET} ${label}: porta ${port}/TCP não apareceu em escuta"
            log_msg "WARN" "${label}: porta ${port}/TCP não apareceu em escuta"
            [[ "${DOCTOR_ACTIVE:-0}" == "1" ]] && DOCTOR_WARN=$((DOCTOR_WARN + 1))
        fi
    else
        echo -e "  ${AMARELO}⚠${RESET} ss não disponível para validar porta ${port}/TCP (${label})"
        log_msg "WARN" "ss não disponível para validar porta ${port}/TCP (${label})"
        [[ "${DOCTOR_ACTIVE:-0}" == "1" ]] && DOCTOR_WARN=$((DOCTOR_WARN + 1))
    fi
}
check_frontend_http() {
    local proto="http"
    [[ "${USE_HTTPS:-0}" == "1" ]] && proto="https"
    local url="${proto}://127.0.0.1:${NGINX_PORT:-80}/"
    local attempt tmp_body http_code
    tmp_body=$(mktemp)
    for attempt in 1 2 3; do
        http_code=$(_curl -k -L -sS --max-time 10 -o "$tmp_body" -w "%{http_code}" "$url" 2>/dev/null || true)
        if [[ "$http_code" =~ ^[23][0-9][0-9]$ ]]; then
            echo -e "  ${VERDE}✔${RESET} Frontend Zabbix: resposta local OK (${url})"
            if grep -qiE 'zabbix|zbx_session|frontends|dashboard|signin|login' "$tmp_body" 2>/dev/null; then
                echo -e "  ${VERDE}✔${RESET} Frontend Zabbix: conteúdo da aplicação detectado"
                log_msg "OK" "Frontend respondeu em ${url} e conteúdo Zabbix foi detectado"
            else
                echo -e "  ${AMARELO}⚠${RESET} Frontend respondeu HTTP ${http_code}, mas não foi possível confirmar conteúdo Zabbix"
                log_msg "WARN" "Frontend respondeu em ${url}, mas conteúdo Zabbix não foi confirmado"
                [[ "${DOCTOR_ACTIVE:-0}" == "1" ]] && DOCTOR_WARN=$((DOCTOR_WARN + 1))
            fi
            rm -f "$tmp_body"
            return 0
        fi
        [[ $attempt -lt 3 ]] && sleep 5
    done
    rm -f "$tmp_body"
    echo -e "  ${AMARELO}⚠${RESET} Frontend Zabbix: sem resposta HTTP local em ${url} (3 tentativas)"
    log_msg "WARN" "Frontend sem resposta HTTP local em ${url}"
    [[ "${DOCTOR_ACTIVE:-0}" == "1" ]] && DOCTOR_WARN=$((DOCTOR_WARN + 1))
}
print_service_journal_tail() {
    local service="$1" lines="${2:-20}"
    command -v journalctl >/dev/null 2>&1 || return 0
    echo -e "  ${AMARELO}Últimas ${lines} linhas de ${service}:${RESET}"
    safe_diag_cmd journalctl -u "$service" -n "$lines" --no-pager | sed 's/^/    /' || true
}
validate_service_active() {
    local service="$1"
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo -e "  ${VERDE}✔${RESET} ${service}: ativo"
        log_msg "OK" "Serviço ${service} ativo"
    else
        echo -e "  ${AMARELO}⚠${RESET} ${service}: não está ativo — diagnóstico: journalctl -u ${service} -n 30 --no-pager"
        log_msg "WARN" "Serviço ${service} não está ativo"
        print_service_journal_tail "$service" 20
        [[ "${DOCTOR_ACTIVE:-0}" == "1" ]] && DOCTOR_WARN=$((DOCTOR_WARN + 1))
    fi
}
wait_for_service_active() {
    local service="$1" timeout_s="${2:-30}" waited=0
    log_msg "INFO" "Aguardando serviço ${service} ficar ativo por até ${timeout_s}s"
    while ((waited < timeout_s)); do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            echo -e "  ${VERDE}✔${RESET} ${service}: ativo após ${waited}s"
            log_msg "OK" "Serviço ${service} ativo após ${waited}s"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    echo -e "\n${VERMELHO}${NEGRITO}ERRO:${RESET} ${service} não ficou ativo em ${timeout_s}s."
    echo -e "  Diagnóstico sugerido: journalctl -u ${service} -n 80 --no-pager"
    log_msg "ERROR" "Serviço ${service} não ficou ativo em ${timeout_s}s"
    print_service_journal_tail "$service" 30
    return 1
}
postgres_is_ready() {
    local pg_ver="${1:-${PG_VER:-}}" cluster="${2:-${PG_CLUSTER_NAME:-main}}"
    if command -v pg_isready >/dev/null 2>&1 && timeout 5 pg_isready -q -h /var/run/postgresql -p 5432 2>/dev/null; then
        return 0
    fi
    if [[ -n "$pg_ver" ]] && systemctl is-active --quiet "postgresql@${pg_ver}-${cluster}" 2>/dev/null; then
        return 0
    fi
    if systemctl is-active --quiet postgresql 2>/dev/null; then
        return 0
    fi
    return 1
}
post_validate_installation() {
    local component="$1"
    _CRITICAL_SERVICES_OK=1

    _validate_critical() {
        local svc="$1"
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo -e "  ${VERDE}✔${RESET} ${svc}: ativo"
            log_msg "OK" "Serviço ${svc} ativo"
        else
            echo -e "  ${VERMELHO}${NEGRITO}✖${RESET} ${svc}: não está ativo"
            log_msg "WARN" "Serviço crítico ${svc} não está ativo"
            print_service_journal_tail "$svc" 20
            _CRITICAL_SERVICES_OK=0
        fi
    }

    echo -e "\n${CIANO}${NEGRITO}▸ PÓS-VALIDAÇÃO AUTOMÁTICA${RESET}"
    log_msg "INFO" "Iniciando pós-validação do componente ${component}"
    case "$component" in
    db)
        if postgres_is_ready "${PG_VER:-}" "${PG_CLUSTER_NAME:-main}"; then
            echo -e "  ${VERDE}✔${RESET} PostgreSQL: pronto"
            log_msg "OK" "PostgreSQL pronto"
        else
            echo -e "  ${VERMELHO}${NEGRITO}✖${RESET} PostgreSQL: não está pronto"
            log_msg "WARN" "PostgreSQL não está pronto"
            print_service_journal_tail "postgresql@${PG_VER:-17}-${PG_CLUSTER_NAME:-main}" 20
            print_service_journal_tail postgresql 20
            _CRITICAL_SERVICES_OK=0
        fi
        check_tcp_listen 5432 "PostgreSQL"
        [[ "${INSTALL_AGENT:-0}" == "1" ]] && _validate_critical zabbix-agent2
        ;;
    server)
        _validate_critical zabbix-server
        _validate_critical nginx
        if [[ -n "${PHP_VER:-}" ]]; then
            _validate_critical "php${PHP_VER}-fpm"
        else
            echo -e "  ${AMARELO}⚠${RESET} PHP_VER não definido — validação do php-fpm ignorada"
            log_msg "WARN" "PHP_VER não definido; validação php-fpm ignorada"
        fi
        [[ "${INSTALL_AGENT:-0}" == "1" ]] && _validate_critical zabbix-agent2
        check_tcp_listen 10051 "Zabbix Server"
        check_tcp_listen "${NGINX_PORT:-80}" "Frontend Nginx"
        check_frontend_http
        doctor_db_connection_from_server_conf
        ;;
    proxy)
        _validate_critical zabbix-proxy
        [[ "${INSTALL_AGENT:-0}" == "1" ]] && _validate_critical zabbix-agent2
        check_tcp_listen 10051 "Zabbix Proxy"
        check_proxy_server_connectivity "${ZBX_SERVER:-}" "${PROXY_MODE:-0}"
        ;;
    esac
}
draw_progress() {
    local msg="${1:-}" pct filled empty bar="" i
    [[ $TOTAL_STEPS -le 0 ]] && TOTAL_STEPS=1
    pct=$((CURRENT_STEP * 100 / TOTAL_STEPS))
    ((pct > 100)) && pct=100
    filled=$((pct / 2))
    empty=$((50 - filled))
    ((filled > 50)) && filled=50
    ((empty < 0)) && empty=0
    for ((i = 0; i < filled; i++)); do bar+="█"; done
    for ((i = 0; i < empty; i++)); do bar+="░"; done
    printf "\r  ${VERDE}[%s]${RESET} ${NEGRITO}%3d%%${RESET}  %-45s" "$bar" "$pct" "$msg"
}
run_step() {
    local msg="$1"
    shift
    if [[ "${SIMULATE_MODE:-0}" == "1" ]]; then
        CURRENT_STEP=$((CURRENT_STEP + 1))
        draw_progress "[SIMULAÇÃO] $msg"
        printf "\n  [SIMULAÇÃO] Executaria etapa: %s\n" "$msg"
        return 0
    fi
    local is_apt=0
    if [[ "$1" == "apt-get" || "$1" == "dpkg" || "$1" == "auto_repair_apt" ]]; then
        is_apt=1
    elif [[ "$1" == "bash" && "${*}" =~ (apt-get|dpkg) ]]; then
        is_apt=1
    fi
    local max_retries count=0 success=0
    if [[ "$is_apt" -eq 1 ]]; then
        max_retries=3
    else
        max_retries=1
    fi
    while [ $count -lt $max_retries ]; do
        draw_progress "$msg"
        if "$@" >>"$LOG_FILE" 2>&1; then
            success=1
            break
        else
            count=$((count + 1))
            [[ $is_apt -eq 1 ]] && {
                auto_repair_apt
                sleep 2
            }
        fi
    done
    if [ $success -eq 1 ]; then
        CURRENT_STEP=$((CURRENT_STEP + 1))
        draw_progress "✔ $msg"
        printf "\n"
    else
        local safe_command
        safe_command="$(redact_known_secrets "$*")"
        echo -e "\n${VERMELHO}${NEGRITO}✖ FALHA CRÍTICA PERSISTENTE${RESET}"
        echo -e "  ${NEGRITO}Etapa:${RESET} ${msg}"
        echo -e "  ${NEGRITO}Comando/Função:${RESET} ${safe_command}"
        [[ -n "${LOG_FILE:-}" ]] && echo -e "  ${NEGRITO}Log:${RESET} ${LOG_FILE}"
        echo -e "\n${AMARELO}${NEGRITO}Diagnóstico sugerido:${RESET}"
        [[ -n "${LOG_FILE:-}" ]] && echo -e "  tail -n 120 ${LOG_FILE}"
        echo -e "  journalctl -xe --no-pager"
        write_error_json "run_step" "$msg" "$safe_command" || true
        exit 1
    fi
}
add_install_warning() {
    local msg="$1"
    INSTALL_WARNINGS+=("$msg")
    log_msg "WARN" "$msg"
}
start_certificate_export() {
    local component="$1"
    local summary_file="/root/zabbix_install_summary.txt"
    local plain_file="/root/zabbix_install_summary_plain.txt"
    local stamp history_file plain_history_file safe_component
    safe_component="${component//[^a-zA-Z0-9_-]/_}"
    stamp=$(date +%Y%m%d_%H%M%S)
    history_file="/root/zabbix_install_summary_${safe_component}_${stamp}.txt"
    plain_history_file="/root/zabbix_install_summary_plain_${safe_component}_${stamp}.txt"

    install -m 600 /dev/null "$summary_file" 2>/dev/null || {
        echo -e "${AMARELO}⚠ Não foi possível criar ${summary_file}; certificado ficará apenas no terminal.${RESET}"
        return 0
    }
    chmod 600 "$summary_file" 2>/dev/null || true
    install -m 600 /dev/null "$plain_file" 2>/dev/null || true
    install -m 600 /dev/null "$history_file" 2>/dev/null || true
    install -m 600 /dev/null "$plain_history_file" 2>/dev/null || true
    chmod 600 "$plain_file" 2>/dev/null || true
    chmod 600 "$history_file" "$plain_history_file" 2>/dev/null || true
    exec > >(tee "$summary_file" "$history_file" >(sanitize_plain_text >"$plain_file") >(sanitize_plain_text >"$plain_history_file")) 2>&1

    echo -e "${CIANO}${NEGRITO}▸ EXPORTAÇÃO DO CERTIFICADO${RESET}"
    printf "  %-34s %s\n" "Arquivo:" "$summary_file"
    printf "  %-34s %s\n" "Arquivo limpo:" "$plain_file"
    printf "  %-34s %s\n" "Histórico:" "$history_file"
    printf "  %-34s %s\n" "Histórico limpo:" "$plain_history_file"
    printf "  %-34s %s\n" "Permissão:" "600"
    printf "  %-34s %s\n" "Componente:" "$component"
    printf "  %-34s %s\n" "Instalador:" "$INSTALLER_LABEL"
    print_file_guide install
    echo ""
}
start_doctor_export() {
    local component="${1:-geral}"
    local report_file="/root/zabbix_doctor_report.txt"
    local stamp history_file safe_component
    safe_component="${component//[^a-zA-Z0-9_-]/_}"
    stamp=$(date +%Y%m%d_%H%M%S)
    history_file="/root/zabbix_doctor_report_${safe_component}_${stamp}.txt"
    install -m 600 /dev/null "$report_file" 2>/dev/null || {
        echo -e "${AMARELO}⚠ Não foi possível criar ${report_file}; Doctor ficará apenas no terminal.${RESET}"
        return 0
    }
    install -m 600 /dev/null "$history_file" 2>/dev/null || true
    chmod 600 "$report_file" 2>/dev/null || true
    chmod 600 "$history_file" 2>/dev/null || true
    exec > >(tee >(sanitize_plain_text >"$report_file") >(sanitize_plain_text >"$history_file")) 2>&1
    echo -e "${CIANO}${NEGRITO}▸ EXPORTAÇÃO DO DOCTOR${RESET}"
    printf "  %-34s %s\n" "Arquivo:" "$report_file"
    printf "  %-34s %s\n\n" "Histórico:" "$history_file"
    print_file_guide doctor
    echo ""
}
json_escape() {
    local s="${1:-}"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/}
    printf '%s' "$s"
}
json_bool() {
    [[ "${1:-0}" == "1" ]] && printf 'true' || printf 'false'
}
service_json_status() {
    local svc="$1"
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        printf 'active'
    else
        printf 'inactive'
    fi
}
print_install_warnings() {
    echo -e "\n${CIANO}${NEGRITO}▸ AVISOS DA INSTALAÇÃO${RESET}"
    if [[ "${#INSTALL_WARNINGS[@]}" -eq 0 ]]; then
        echo -e "  ${VERDE}Nenhum aviso registrado.${RESET}"
        return 0
    fi
    local warning
    for warning in "${INSTALL_WARNINGS[@]}"; do
        echo -e "  ${AMARELO}⚠${RESET} ${warning}"
    done
}
write_install_summary_json() {
    local component="$1" json_file="/root/zabbix_install_summary.json" tmp_file
    local arch frontend_url tsdb_active tsdb_version psk_id psk_secret db_password
    arch=$(dpkg --print-architecture 2>/dev/null || uname -m 2>/dev/null || echo "unknown")
    frontend_url=""
    [[ -n "${HOST_IP:-}" && -n "${NGINX_PORT:-}" ]] && frontend_url="$([[ "${USE_HTTPS:-0}" == "1" ]] && echo "https" || echo "http")://${HOST_IP}:${NGINX_PORT}"
    tsdb_active="false"
    [[ -n "${TSDB_EXT_VER:-}" && "${TSDB_EXT_VER:-N/D}" != "N/D" ]] && tsdb_active="true"
    tsdb_version="${TSDB_EXT_VER:-${TSDB_PKG_VER:-}}"
    psk_id="${PSK_AGENT_ID:-${PSK_PROXY_ID:-}}"
    psk_secret="${PSK_AGENT_KEY:-${PSK_PROXY_KEY:-}}"
    db_password="${DB_PASS:-}"
    tmp_file="$(mktemp /tmp/zabbix_install_summary_json.XXXXXX)"
    {
        echo "{"
        printf '  "component": "%s",\n' "$(json_escape "$component")"
        printf '  "installer_version": "%s",\n' "$(json_escape "$INSTALLER_VERSION")"
        printf '  "distro": "%s",\n' "$(json_escape "$OS_LABEL")"
        printf '  "distro_version": "%s",\n' "$(json_escape "$U_VER")"
        printf '  "codename": "%s",\n' "$(json_escape "$U_CODENAME")"
        printf '  "architecture": "%s",\n' "$(json_escape "$arch")"
        printf '  "zabbix_version": "%s",\n' "$(json_escape "${ZBX_VERSION:-${ZBX_TARGET_VERSION:-}}")"
        printf '  "postgresql_version": "%s",\n' "$(json_escape "${PG_VER:-}")"
        printf '  "timescaledb_version": "%s",\n' "$(json_escape "$tsdb_version")"
        printf '  "timescaledb_active": %s,\n' "$tsdb_active"
        printf '  "timescaledb_tune_status": "%s",\n' "$(json_escape "${TSDB_TUNE_STATUS:-não executado}")"
        printf '  "db_host": "%s",\n' "$(json_escape "${DB_HOST:-${HOST_IP:-}}")"
        printf '  "db_port": "%s",\n' "$(json_escape "${DB_PORT:-5432}")"
        printf '  "db_name": "%s",\n' "$(json_escape "${DB_NAME:-}")"
        printf '  "db_user": "%s",\n' "$(json_escape "${DB_USER:-}")"
        printf '  "db_password": "%s",\n' "$(json_escape "$db_password")"
        printf '  "frontend_url": "%s",\n' "$(json_escape "$frontend_url")"
        printf '  "psk_identity": "%s",\n' "$(json_escape "$psk_id")"
        printf '  "psk_secret": "%s",\n' "$(json_escape "$psk_secret")"
        printf '  "log_file": "%s",\n' "$(json_escape "${LOG_FILE:-}")"
        printf '  "full_log": "%s",\n' "$(json_escape "${FULL_LOG:-}")"
        printf '  "health_check_ok": %s,\n' "$(json_bool "${_CRITICAL_SERVICES_OK:-0}")"
        echo '  "services": {'
        printf '    "postgresql": "%s",\n' "$(service_json_status postgresql)"
        printf '    "zabbix_server": "%s",\n' "$(service_json_status zabbix-server)"
        printf '    "zabbix_proxy": "%s",\n' "$(service_json_status zabbix-proxy)"
        printf '    "zabbix_agent2": "%s",\n' "$(service_json_status zabbix-agent2)"
        printf '    "nginx": "%s"\n' "$(service_json_status nginx)"
        echo '  },'
        echo '  "warnings": ['
        local i
        for i in "${!INSTALL_WARNINGS[@]}"; do
            printf '    "%s"%s\n' "$(json_escape "${INSTALL_WARNINGS[$i]}")" "$([[ "$i" -lt $((${#INSTALL_WARNINGS[@]} - 1)) ]] && echo "," || echo "")"
        done
        echo '  ]'
        echo "}"
    } >"$tmp_file"
    install -m 600 "$tmp_file" "$json_file" 2>/dev/null || cp "$tmp_file" "$json_file"
    chmod 600 "$json_file" 2>/dev/null || true
    rm -f "$tmp_file"
    printf "  %-34s %s\n" "JSON estruturado:" "$json_file"
}
doctor_show_last_installer_version() {
    local cert="/root/zabbix_install_summary_plain.txt"
    local latest installer
    echo -e "\n${CIANO}${NEGRITO}▸ ÚLTIMO CERTIFICADO SALVO${RESET}"
    if [[ -f "$cert" ]]; then
        installer=$(awk -F: '/Instalador:/{sub(/^[[:space:]]+/, "", $2); print $2; exit}' "$cert" 2>/dev/null || true)
        printf "  %-34s %s\n" "Arquivo:" "$cert"
        printf "  %-34s %s\n" "Instalador:" "${installer:-não informado no certificado}"
        return 0
    fi
    latest=$(ls -1t /root/zabbix_install_summary_plain_*_*.txt 2>/dev/null | head -1 || true)
    if [[ -n "$latest" ]]; then
        installer=$(awk -F: '/Instalador:/{sub(/^[[:space:]]+/, "", $2); print $2; exit}' "$latest" 2>/dev/null || true)
        printf "  %-34s %s\n" "Arquivo:" "$latest"
        printf "  %-34s %s\n" "Instalador:" "${installer:-não informado no certificado}"
    else
        echo -e "  ${AMARELO}⚠ Nenhum certificado salvo encontrado.${RESET}"
    fi
}
doctor_scan_common_log_errors() {
    local component="$1" files=() file pattern count
    local -a patterns=(
        "database is down"
        "connection refused"
        "permission denied"
        "version does not match current requirements"
        "unsupported database"
        "cannot connect to the database"
        "PSK identity mismatch"
        "psk mismatch"
        "TLS handshake failed"
        "TLS error"
        "certificate verify failed"
        "too many clients already"
        "too many connections"
        "database is not available"
    )
    case "$component" in
    db) files=(/var/log/postgresql/*.log) ;;
    server) files=(/var/log/zabbix/zabbix_server.log /var/log/nginx/error.log) ;;
    proxy) files=(/var/log/zabbix/zabbix_proxy.log /var/log/zabbix/zabbix_agent2.log) ;;
    *) files=(/var/log/zabbix/*.log /var/log/postgresql/*.log /var/log/nginx/error.log) ;;
    esac
    echo -e "\n${CIANO}${NEGRITO}▸ ERROS COMUNS NOS LOGS${RESET}"
    local found=0
    for file in "${files[@]}"; do
        [[ -f "$file" ]] || continue
        for pattern in "${patterns[@]}"; do
            count=$(safe_count_matches "$pattern" "$file")
            if [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]]; then
                found=1
                DOCTOR_WARN=$((DOCTOR_WARN + 1))
                printf "  ${AMARELO}⚠${RESET} %-42s %s ocorrência(s) em %s\n" "$pattern" "$count" "$file"
            fi
        done
    done
    [[ "$found" == "0" ]] && echo -e "  ${VERDE}✔ Nenhum padrão crítico conhecido encontrado nos logs verificados.${RESET}"
    return 0
}
