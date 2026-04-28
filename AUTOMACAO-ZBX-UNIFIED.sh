#!/bin/bash

# ==============================================================================
# ZABBIX — INSTALADOR UNIFICADO (DB + Server + Proxy) — v5.5
# ==============================================================================
# Componentes disponíveis (um por execução):
#   1) BASE DE DADOS  — PostgreSQL + TimescaleDB        (DB v1.5)
#   2) SERVIDOR       — Zabbix Server + Frontend + Nginx (Server v2.3)
#   3) PROXY          — Zabbix Proxy + Agent 2           (Proxy v10.8)
# ==============================================================================
# Historico completo: CHANGELOG.md
# Politica de versoes: README.md
# ==============================================================================
set -Eeuo pipefail

VALIDATION_CACHE_DIR="/tmp/zbx_validation_cache"
ERROR_JSON="/root/zabbix_install_error.json"
TSDB_TUNE_STATUS="não executado"

write_error_json() {
    local exit_code="${1:-1}" line_no="${2:-0}" cmd="${3:-comando desconhecido}" tmp_file
    local esc_cmd esc_component esc_log
    esc_cmd=${cmd//\\/\\\\}; esc_cmd=${esc_cmd//\"/\\\"}
    esc_component=${COMPONENT:-geral}; esc_component=${esc_component//\\/\\\\}; esc_component=${esc_component//\"/\\\"}
    esc_log=${LOG_FILE:-}; esc_log=${esc_log//\\/\\\\}; esc_log=${esc_log//\"/\\\"}
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
    } > "$tmp_file" 2>/dev/null || true
    install -m 600 "$tmp_file" "$ERROR_JSON" 2>/dev/null || cp "$tmp_file" "$ERROR_JSON" 2>/dev/null || true
    rm -f "$tmp_file" 2>/dev/null || true
}

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
    }' > "$tmp" 2>/dev/null || true
    if command -v iconv >/dev/null 2>&1; then
        iconv -f UTF-8 -t UTF-8 -c "$tmp" 2>/dev/null || cat "$tmp" 2>/dev/null || true
    else
        cat "$tmp" 2>/dev/null || true
    fi
    rm -f "$tmp" 2>/dev/null || true
}

curl() {
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

wget() {
    command wget --timeout=10 --tries=3 "$@"
}

psql() {
    local psql_bin
    psql_bin="$(type -P psql 2>/dev/null || true)"
    [[ -n "$psql_bin" ]] || { echo "psql não encontrado" >&2; return 127; }
    PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}" timeout "${PSQL_TIMEOUT:-900}" "$psql_bin" "$@"
}

on_error() {
    local exit_code="$?"
    local line_no="${BASH_LINENO[0]:-${LINENO}}"
    local cmd="${BASH_COMMAND:-comando desconhecido}"
    echo -e "\n\e[31m\e[1mERRO FATAL:\e[0m linha ${line_no}, código ${exit_code}." >&2
    echo -e "\e[33mComando:\e[0m ${cmd}" >&2
    [[ -n "${LOG_FILE:-}" ]] && echo -e "\e[36mLog:\e[0m ${LOG_FILE}" >&2
    if [[ -n "${LOG_FILE:-}" ]]; then
        printf '[%s] [FATAL] linha %s, código %s — %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$line_no" "$exit_code" "$cmd" \
            >> "$LOG_FILE" 2>/dev/null || true
    fi
    write_error_json "$exit_code" "$line_no" "$cmd"
    echo -e "\e[36mErro estruturado:\e[0m ${ERROR_JSON}" >&2
    print_file_guide error >&2
    exit "${exit_code}"
}
trap on_error ERR

# Trap EXIT empilhável: evita que rotinas diferentes sobrescrevam a limpeza umas das outras.
EXIT_TRAP_COMMANDS=()
run_exit_traps() {
    local _cmd
    for _cmd in "${EXIT_TRAP_COMMANDS[@]}"; do
        eval "${_cmd}" >/dev/null 2>&1 || true
    done
}
add_exit_trap() {
    EXIT_TRAP_COMMANDS+=("$1")
    trap run_exit_traps EXIT
}

log_msg() {
    local level="$1"; shift
    local message="$*"
    [[ -n "${LOG_FILE:-}" ]] && printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$message" >> "$LOG_FILE" 2>/dev/null || true
    [[ -n "${FULL_LOG:-}" ]] && printf '[%s] [%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "${COMPONENT:-geral}" "$message" >> "$FULL_LOG" 2>/dev/null || true
}

init_install_log() {
    local component="$1" legacy_path="$2"
    LOG_DIR="/var/log/zabbix-install"
    FULL_LOG="${LOG_DIR}/full.log"
    COMPONENT_LOG="${LOG_DIR}/${component}.log"
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    chmod 700 "$LOG_DIR" 2>/dev/null || true
    : > "$COMPONENT_LOG" 2>/dev/null || true
    touch "$FULL_LOG" 2>/dev/null || true
    chmod 600 "$COMPONENT_LOG" "$FULL_LOG" 2>/dev/null || true
    LOG_FILE="$legacy_path"
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/$(basename "$legacy_path")"
    ln -sf "$LOG_FILE" "$COMPONENT_LOG" 2>/dev/null || true
    log_msg "INFO" "Log organizado: LOG_FILE=${LOG_FILE}; COMPONENT_LOG=${COMPONENT_LOG}; FULL_LOG=${FULL_LOG}"
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
    echo "$$" > "$LOCK_FILE"
    add_exit_trap "rm -f '$LOCK_FILE'"
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
            [[ "${DOCTOR_ACTIVE:-0}" == "1" ]] && DOCTOR_WARN=$(( DOCTOR_WARN + 1 ))
        fi
    else
        echo -e "  ${AMARELO}⚠${RESET} ss não disponível para validar porta ${port}/TCP (${label})"
        log_msg "WARN" "ss não disponível para validar porta ${port}/TCP (${label})"
        [[ "${DOCTOR_ACTIVE:-0}" == "1" ]] && DOCTOR_WARN=$(( DOCTOR_WARN + 1 ))
    fi
}

check_frontend_http() {
    local proto="http"
    [[ "${USE_HTTPS:-0}" == "1" ]] && proto="https"
    local url="${proto}://127.0.0.1:${NGINX_PORT:-80}/"
    local attempt tmp_body http_code
    tmp_body=$(mktemp)
    for attempt in 1 2 3; do
        http_code=$(curl -k -L -sS --max-time 10 -o "$tmp_body" -w "%{http_code}" "$url" 2>/dev/null || true)
        if [[ "$http_code" =~ ^[23][0-9][0-9]$ ]]; then
            echo -e "  ${VERDE}✔${RESET} Frontend Zabbix: resposta local OK (${url})"
            if grep -qiE 'zabbix|zbx_session|frontends|dashboard|signin|login' "$tmp_body" 2>/dev/null; then
                echo -e "  ${VERDE}✔${RESET} Frontend Zabbix: conteúdo da aplicação detectado"
                log_msg "OK" "Frontend respondeu em ${url} e conteúdo Zabbix foi detectado"
            else
                echo -e "  ${AMARELO}⚠${RESET} Frontend respondeu HTTP ${http_code}, mas não foi possível confirmar conteúdo Zabbix"
                log_msg "WARN" "Frontend respondeu em ${url}, mas conteúdo Zabbix não foi confirmado"
                [[ "${DOCTOR_ACTIVE:-0}" == "1" ]] && DOCTOR_WARN=$(( DOCTOR_WARN + 1 ))
            fi
            rm -f "$tmp_body"
            return 0
        fi
        [[ $attempt -lt 3 ]] && sleep 5
    done
    rm -f "$tmp_body"
    echo -e "  ${AMARELO}⚠${RESET} Frontend Zabbix: sem resposta HTTP local em ${url} (3 tentativas)"
    log_msg "WARN" "Frontend sem resposta HTTP local em ${url}"
    [[ "${DOCTOR_ACTIVE:-0}" == "1" ]] && DOCTOR_WARN=$(( DOCTOR_WARN + 1 ))
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
        [[ "${DOCTOR_ACTIVE:-0}" == "1" ]] && DOCTOR_WARN=$(( DOCTOR_WARN + 1 ))
    fi
}

wait_for_service_active() {
    local service="$1" timeout_s="${2:-30}" waited=0
    log_msg "INFO" "Aguardando serviço ${service} ficar ativo por até ${timeout_s}s"
    while (( waited < timeout_s )); do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            echo -e "  ${VERDE}✔${RESET} ${service}: ativo após ${waited}s"
            log_msg "OK" "Serviço ${service} ativo após ${waited}s"
            return 0
        fi
        sleep 2
        waited=$(( waited + 2 ))
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

_CRITICAL_SERVICES_OK=1

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

# ------------------------------------------------------------------------------
# 1. ESTÉTICA E CORES
# ------------------------------------------------------------------------------
VERDE="\e[32m"; AMARELO="\e[33m"; VERMELHO="\e[31m"
CIANO="\e[36m"; NEGRITO="\e[1m"; RESET="\e[0m"
INSTALLER_VERSION="v5.5"
INSTALLER_LABEL="AUTOMACAO-ZBX-UNIFIED ${INSTALLER_VERSION}"

clear() { printf '\033c' 2>/dev/null || :; }

CHECK_ONLY=0
DRY_RUN=0
DOCTOR_MODE=0
DOCTOR_EXPORT=0
SIMULATE_MODE=0
WIPE_MODE=0
WIPE_DB=0
LIST_VERSIONS=0
LIST_SUPPORTED_OS=0
REPO_CHECK=0
SAFE_MODE=0
DEBUG_SERVICES=0
COLLECT_SUPPORT_BUNDLE=0
SELF_TEST_MODE=0
REQUESTED_COMPONENT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check|-c) CHECK_ONLY=1; shift ;;
        --dry-run|-n) DRY_RUN=1; shift ;;
        --doctor|-d) DOCTOR_MODE=1; shift ;;
        --doctor-export) DOCTOR_MODE=1; DOCTOR_EXPORT=1; shift ;;
        --export) DOCTOR_EXPORT=1; shift ;;
        --list-versions) LIST_VERSIONS=1; shift ;;
        --list-supported-os) LIST_SUPPORTED_OS=1; shift ;;
        --repo-check) REPO_CHECK=1; shift ;;
        --safe) SAFE_MODE=1; shift ;;
        --debug-services) DEBUG_SERVICES=1; shift ;;
        --collect-support-bundle) COLLECT_SUPPORT_BUNDLE=1; shift ;;
        --self-test) SELF_TEST_MODE=1; shift ;;
        --simulate|-s) SIMULATE_MODE=1; shift ;;
        --wipe) WIPE_MODE=1; shift ;;
        --wipe-db) WIPE_MODE=1; WIPE_DB=1; shift ;;
        --mode)
            if [[ -z "${2:-}" ]]; then
                echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} --mode requer um valor: db, server ou proxy."
                exit 1
            fi
            case "$2" in
                db|database|bd) REQUESTED_COMPONENT="db" ;;
                server|servidor) REQUESTED_COMPONENT="server" ;;
                proxy) REQUESTED_COMPONENT="proxy" ;;
                *)
                    echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} modo inválido em --mode: $2"
                    echo "Use: --mode db, --mode server ou --mode proxy."
                    exit 1
                    ;;
            esac
            shift 2
            ;;
        db|database|bd)
            REQUESTED_COMPONENT="db"; shift ;;
        server|servidor)
            REQUESTED_COMPONENT="server"; shift ;;
        proxy)
            REQUESTED_COMPONENT="proxy"; shift ;;
        --help|-h)
            cat << EOF
Uso: $0 [componente] [opções]

Componentes opcionais:
  db            Instala Base de Dados PostgreSQL + TimescaleDB
  server        Instala Zabbix Server + Frontend + Nginx
  proxy         Instala Zabbix Proxy + Agent 2

Opções:
  --check, -c   Valida o ambiente sem instalar, remover ou alterar ficheiros.
  --dry-run, -n Mostra o plano do componente escolhido sem instalar ou alterar ficheiros.
  --simulate, -s Responde ao questionário e simula o pipeline sem executar ações.
  --doctor, -d  Diagnostica uma instalação existente do componente escolhido.
  --doctor-export Exporta o diagnóstico para /root/zabbix_doctor_report.txt.
  --list-versions Lista versões suportadas e sai sem alterar nada.
  --list-supported-os Lista sistemas suportados/experimentais/indisponíveis.
  --repo-check  Valida repositórios e pacotes oficiais do componente sem instalar.
  --safe        Exige confirmação extra antes de limpezas destrutivas.
  --debug-services Diagnostica serviços/portas/processos sem instalar nada.
  --collect-support-bundle Coleta diagnóstico em um .tar.gz para suporte.
  --self-test   Valida o próprio instalador sem instalar nada.
  --mode <modo> Executa direto: db, server ou proxy.
  --wipe        Limpeza completa de Zabbix/Nginx, com confirmação.
  --wipe-db     Limpeza completa incluindo PostgreSQL/TimescaleDB e dados da BD.
  --help,  -h   Mostra esta ajuda.

Exemplos:
  $0            Menu interativo
  $0 db         Vai direto para o componente Base de Dados
  $0 --mode db  Vai direto para o componente Base de Dados sem mostrar menu
  $0 server     Vai direto para o componente Servidor
  $0 proxy      Vai direto para o componente Proxy
  $0 --check    Somente valida ambiente
  $0 server -n  Mostra o plano do Server sem executar
  $0 server -s  Pergunta tudo e simula o pipeline do Server
  $0 server -d  Diagnostica uma instalação existente do Server
  $0 server --doctor-export Exporta diagnóstico do Server
  $0 --list-versions Lista matriz de compatibilidade
  $0 --list-supported-os Lista sistemas suportados
  $0 server --repo-check Valida repositórios/pacotes do Server sem instalar
  $0 --debug-services Diagnostica serviços sem instalar
  $0 --collect-support-bundle Gera pacote único para análise de problemas
  $0 --self-test Valida funções internas e dependências básicas
  $0 --wipe     Remove instalações anteriores no escopo Zabbix/Nginx
  $0 --wipe-db  Remove também PostgreSQL/TimescaleDB e dados da BD

Atenção: em modo normal, este instalador é destrutivo por design e remove vestígios de instalações anteriores do componente escolhido.
EOF
            exit 0
            ;;
        *)
            echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} Opção desconhecida: $1"
            echo "Use --help para ver as opções disponíveis."
            exit 1
            ;;
    esac
done

[[ "$DOCTOR_EXPORT" == "1" ]] && DOCTOR_MODE=1

if [[ "$CHECK_ONLY" != "1" && "$DRY_RUN" != "1" && "$SIMULATE_MODE" != "1" && "$LIST_VERSIONS" != "1" && "$LIST_SUPPORTED_OS" != "1" && "$DEBUG_SERVICES" != "1" && "$SELF_TEST_MODE" != "1" && "$EUID" -ne 0 ]]; then
    echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} O instalador precisa de permissões de root (sudo)."
    exit 1
fi

# ------------------------------------------------------------------------------
# 2. DETEÇÃO DO SISTEMA
# ------------------------------------------------------------------------------
U_VER=$(lsb_release -rs 2>/dev/null || { [[ -r /etc/os-release ]] && awk -F= '$1=="VERSION_ID"{gsub(/"/,"",$2); print $2}' /etc/os-release || true; })
U_CODENAME=$(lsb_release -cs 2>/dev/null || { [[ -r /etc/os-release ]] && awk -F= '$1=="VERSION_CODENAME"{gsub(/"/,"",$2); print $2}' /etc/os-release || true; })
OS_ID=$(awk -F= '$1=="ID"{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null || true)
OS_PRETTY=$(awk -F= '$1=="PRETTY_NAME"{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null || true)
case "$OS_ID" in
    ubuntu)
        OS_FAMILY="ubuntu"
        OS_LABEL="Ubuntu"
        ;;
    debian)
        OS_FAMILY="debian"
        OS_LABEL="Debian"
        ;;
    almalinux|rocky|rocky-linux|rhel|centos)
        OS_FAMILY="rhel"
        OS_LABEL="${OS_ID^}"
        ;;
    *)
        OS_FAMILY="unsupported"
        OS_LABEL="${OS_ID:-sistema desconhecido}"
        ;;
esac
OS_DISPLAY="${OS_PRETTY:-${OS_LABEL} ${U_VER} (${U_CODENAME})}"
RAM_MB=""
if command -v free >/dev/null 2>&1; then
    RAM_MB=$(free -m 2>/dev/null | awk '/^Mem/{print $2}' || true)
fi
if [[ -z "${RAM_MB:-}" ]] && command -v sysctl >/dev/null 2>&1; then
    RAM_MB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 ))
fi
CPU_CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)

# Fuso horário do sistema — usado como padrão em todos os componentes.
# Ordem: timedatectl (systemd) → /etc/timezone (fallback) → America/Sao_Paulo (último recurso)
SYS_TIMEZONE=$(timedatectl show --property=Timezone --value 2>/dev/null | awk 'NF{print; exit}' || true)
if [[ -z "${SYS_TIMEZONE}" ]]; then
    SYS_TIMEZONE=$(cat /etc/timezone 2>/dev/null | tr -d '[:space:]' || true)
fi
[[ -z "${SYS_TIMEZONE}" ]] && SYS_TIMEZONE="America/Sao_Paulo"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
mkdir -p "$VALIDATION_CACHE_DIR" 2>/dev/null || true
chmod 700 "$VALIDATION_CACHE_DIR" 2>/dev/null || true

clear() { printf '\033c' 2>/dev/null || :; }
INSTALL_WARNINGS=()

# ------------------------------------------------------------------------------
# 3. FUNÇÕES COMPARTILHADAS
# ------------------------------------------------------------------------------
auto_repair_apt() {
    local timeout=15
    local waited=0

    apt_process_running() {
        pgrep -x "apt" >/dev/null 2>&1 || \
        pgrep -x "apt-get" >/dev/null 2>&1 || \
        pgrep -x "dpkg" >/dev/null 2>&1 || \
        pgrep -x "unattended-upgrades" >/dev/null 2>&1
    }

    while apt_process_running; do
        if (( waited >= timeout )); then
            [[ -n "${LOG_FILE:-}" ]] && echo "APT ocupado ha ${timeout}s; tentando liberar apt-daily..." >> "$LOG_FILE" 2>/dev/null || true
            systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
            systemctl kill --kill-who=all apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
            break
        fi
        sleep 2
        waited=$(( waited + 2 ))
    done

    if ! apt_process_running; then
        rm -f /var/lib/dpkg/lock-frontend \
              /var/lib/dpkg/lock \
              /var/lib/apt/lists/lock \
              /var/cache/apt/archives/lock 2>/dev/null || true
    else
        [[ -n "${LOG_FILE:-}" ]] && echo "APT/dpkg ainda em execucao; locks preservados." >> "$LOG_FILE" 2>/dev/null || true
    fi

    dpkg --configure -a 2>/dev/null | { [[ -n "${LOG_FILE:-}" ]] && tee -a "$LOG_FILE" || cat; } 2>/dev/null || true
    apt-get install -f -y 2>/dev/null | { [[ -n "${LOG_FILE:-}" ]] && tee -a "$LOG_FILE" || cat; } 2>/dev/null || true
}

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
            1) printf '%s\n' "America/Sao_Paulo"; return 0 ;;
            2) printf '%s\n' "UTC"; return 0 ;;
            3|"") printf '%s\n' "$current"; return 0 ;;
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
        grep -qE '^[# ]*en_US\.UTF-8 UTF-8' /etc/locale.gen 2>/dev/null && \
            sed -i 's/^[# ]*en_US\.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
        grep -qE '^[# ]*pt_BR\.UTF-8 UTF-8' /etc/locale.gen 2>/dev/null && \
            sed -i 's/^[# ]*pt_BR\.UTF-8 UTF-8/pt_BR.UTF-8 UTF-8/' /etc/locale.gen
        grep -qE '^en_US\.UTF-8 UTF-8' /etc/locale.gen 2>/dev/null || echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
        grep -qE '^pt_BR\.UTF-8 UTF-8' /etc/locale.gen 2>/dev/null || echo 'pt_BR.UTF-8 UTF-8' >> /etc/locale.gen
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

# set_config: formato param=value (Zabbix conf)
# Valor vazio → comenta a linha (Zabbix 7.4 rejeita "param=" mesmo vazio)
set_config() {
    local file=$1 param=$2 value=$3
    if [ ! -f "$file" ]; then
        mkdir -p "$(dirname "$file")" 2>/dev/null || true
        touch "$file" 2>/dev/null || {
            echo "Arquivo de configuração não encontrado e não foi possível criar: ${file}" >&2
            return 1
        }
        [[ -n "$value" ]] && echo "${param}=${value}" >> "$file"
        return
    fi
    if [[ -z "$value" ]]; then
        if grep -qE "^[[:space:]]*${param}=" "$file"; then
            sed -i "s|^[[:space:]]*${param}=.*|# ${param}=|g" "$file"
        fi
        return
    fi
    # Escapa metacaracteres do sed (\  e  &) na string de substituição para que
    # senhas com esses caracteres sejam gravadas literalmente e não corrompidas.
    local escaped_value="${value//\\/\\\\}"
    escaped_value="${escaped_value//&/\\&}"
    escaped_value="${escaped_value//|/\\|}"
    if [[ $(safe_count_matches "^[[:space:]]*${param}=" "$file") -gt 1 ]]; then
        sed -i "0,/^[[:space:]]*${param}=/! { /^[[:space:]]*${param}=/d }" "$file"
    fi
    if grep -qE "^[[:space:]]*${param}=" "$file"; then
        sed -i "s|^[[:space:]]*${param}=.*|${param}=${escaped_value}|" "$file"
    elif grep -qE "^#[[:space:]]*${param}=" "$file"; then
        sed -i "0,/^#[[:space:]]*${param}=/{s|^#[[:space:]]*${param}=.*|${param}=${escaped_value}|}" "$file"
    else
        echo "${param}=${value}" >> "$file"
    fi
}

CURRENT_STEP=0; TOTAL_STEPS=1

draw_progress() {
    local msg="${1:-}" pct filled empty bar="" i
    [[ $TOTAL_STEPS -le 0 ]] && TOTAL_STEPS=1
    pct=$(( CURRENT_STEP * 100 / TOTAL_STEPS ))
    (( pct > 100 )) && pct=100
    filled=$(( pct / 2 )); empty=$(( 50 - filled ))
    (( filled > 50 )) && filled=50
    (( empty < 0 )) && empty=0
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty;  i++)); do bar+="░"; done
    printf "\r  ${VERDE}[%s]${RESET} ${NEGRITO}%3d%%${RESET}  %-45s" "$bar" "$pct" "$msg"
}

run_step() {
    local msg="$1"; shift
    if [[ "${SIMULATE_MODE:-0}" == "1" ]]; then
        CURRENT_STEP=$(( CURRENT_STEP + 1 ))
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
    max_retries=$([[ $is_apt -eq 1 ]] && echo 3 || echo 1)
    while [ $count -lt $max_retries ]; do
        draw_progress "$msg"
        if "$@" >>"$LOG_FILE" 2>&1; then success=1; break
        else count=$((count+1)); [[ $is_apt -eq 1 ]] && { auto_repair_apt; sleep 2; }; fi
    done
    if [ $success -eq 1 ]; then
        CURRENT_STEP=$(( CURRENT_STEP + 1 )); draw_progress "✔ $msg"
        printf "\n"
    else
        echo -e "\n${VERMELHO}${NEGRITO}✖ FALHA CRÍTICA PERSISTENTE${RESET}"
        echo -e "  ${NEGRITO}Etapa:${RESET} ${msg}"
        echo -e "  ${NEGRITO}Comando/Função:${RESET} $*"
        [[ -n "${LOG_FILE:-}" ]] && echo -e "  ${NEGRITO}Log:${RESET} ${LOG_FILE}"
        echo -e "\n${AMARELO}${NEGRITO}Diagnóstico sugerido:${RESET}"
        [[ -n "${LOG_FILE:-}" ]] && echo -e "  tail -n 120 ${LOG_FILE}"
        echo -e "  journalctl -xe --no-pager"
        exit 1
    fi
}

ask_yes_no() {
    local question="$1" var_name="$2"
    echo -e "\n${AMARELO}${NEGRITO}${question}${RESET}"
    echo -e "  1) Sim   2) Não"
    while true; do
        read -rp "  Escolha (1 ou 2): " choice
        case "$choice" in
            1) printf -v "$var_name" "1"; break ;;
            2) printf -v "$var_name" "0"; break ;;
            *) echo -e "  ${VERMELHO}Opção inválida.${RESET}" ;;
        esac
    done
}

APT_FLAGS=(-y -o "Dpkg::Options::=--force-confdef" -o "Dpkg::Options::=--force-confold" -o "Dpkg::Options::=--force-confmiss")

# ----------------------------------------------------------------------------
# 3.1 HARDENING / VALIDAÇÕES COMPARTILHADAS
# ----------------------------------------------------------------------------
add_install_warning() {
    local msg="$1"
    INSTALL_WARNINGS+=("$msg")
    log_msg "WARN" "$msg"
}

pkg_update() {
    case "$OS_FAMILY" in
        ubuntu|debian) apt-get update ;;
        rhel) dnf makecache ;;
        *) echo "Sistema não suportado para atualização de repositórios: ${OS_DISPLAY}" >&2; return 1 ;;
    esac
}

pkg_install() {
    case "$OS_FAMILY" in
        ubuntu|debian) apt-get install "${APT_FLAGS[@]}" "$@" ;;
        rhel) dnf install -y "$@" ;;
        *) echo "Sistema não suportado para instalação de pacotes: ${OS_DISPLAY}" >&2; return 1 ;;
    esac
}

pkg_purge() {
    case "$OS_FAMILY" in
        ubuntu|debian) apt-get purge -y "$@" ;;
        rhel) dnf remove -y "$@" ;;
        *) echo "Sistema não suportado para remoção de pacotes: ${OS_DISPLAY}" >&2; return 1 ;;
    esac
}

pkg_is_installed() {
    local pkg="$1"
    case "$OS_FAMILY" in
        ubuntu|debian) dpkg -s "$pkg" >/dev/null 2>&1 ;;
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

mask_secret() {
    local s="${1:-}"
    [[ -z "$s" ]] && { echo ""; return; }
    if (( ${#s} <= 8 )); then
        echo "********"
    else
        echo "${s:0:4}********${s: -4}"
    fi
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
    exec > >(tee "$summary_file" "$history_file" >(sanitize_plain_text > "$plain_file") >(sanitize_plain_text > "$plain_history_file")) 2>&1

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
        [[ "${DOCTOR_ACTIVE:-0}" == "1" ]] && DOCTOR_WARN=$(( DOCTOR_WARN + 1 ))
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
        host="$entry"; port="10051"
        if [[ "$entry" == *":"* && "$entry" != *"]"* ]]; then
            host="${entry%:*}"
            port="${entry##*:}"
        fi
        total=$(( total + 1 ))
        if test_tcp_connectivity "$host" "$port" 5; then
            printf "  %-34s ${VERDE}%s${RESET}\n" "${host}:${port}" "OK"
            ok=1
        else
            printf "  %-34s ${AMARELO}%s${RESET}\n" "${host}:${port}" "sem conexão TCP"
        fi
    done
    [[ "$total" -gt 0 && "$ok" == "0" ]] && \
        echo -e "  ${AMARELO}⚠ Nenhum destino respondeu agora. Verifique rota/firewall/porta 10051 no Server.${RESET}"
    [[ "$total" -gt 0 && "$ok" == "0" && "${DOCTOR_ACTIVE:-0}" == "1" ]] && DOCTOR_WARN=$(( DOCTOR_WARN + 1 ))
    return 0
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
    exec > >(tee >(sanitize_plain_text > "$report_file") >(sanitize_plain_text > "$history_file")) 2>&1
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
    [[ "${TSDB_AVAILABLE:-0}" == "1" || "${USE_TIMESCALE:-0}" == "1" ]] && tsdb_active="true"
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
    } > "$tmp_file"
    install -m 600 "$tmp_file" "$json_file" 2>/dev/null || cp "$tmp_file" "$json_file"
    chmod 600 "$json_file" 2>/dev/null || true
    rm -f "$tmp_file"
    printf "  %-34s %s\n" "JSON estruturado:" "$json_file"
}

doctor_show_last_installer_version() {
    local cert="/root/zabbix_install_summary_plain.txt"
    local hist latest installer
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

show_supported_versions() {
    clear
    echo -e "${CIANO}${NEGRITO}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CIANO}${NEGRITO}║                  VERSÕES SUPORTADAS                      ║${RESET}"
    echo -e "${CIANO}${NEGRITO}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo -e "\n${CIANO}${NEGRITO}▸ Ubuntu por componente${RESET}"
    printf "  %-18s %s\n" "Database:" "18.04, 20.04, 22.04, 24.04, 26.04"
    printf "  %-18s %s\n" "Server:" "20.04, 22.04, 24.04, 26.04"
    printf "  %-18s %s\n" "Proxy:" "16.04, 18.04, 20.04, 22.04, 24.04, 26.04"
    echo -e "\n${CIANO}${NEGRITO}▸ Debian por componente${RESET}"
    printf "  %-18s %s\n" "Database:" "12 (bookworm), 13 (trixie)"
    printf "  %-18s %s\n" "Server:" "12 (bookworm), 13 (trixie)"
    printf "  %-18s %s\n" "Proxy:" "12 (bookworm), 13 (trixie)"
    echo -e "\n${CIANO}${NEGRITO}▸ Zabbix${RESET}"
    printf "  %-18s %s\n" "Estável:" "7.0 LTS, 7.4"
    printf "  %-18s %s\n" "Beta:" "8.0 quando disponível no repositório oficial"
    echo -e "\n${CIANO}${NEGRITO}▸ PostgreSQL${RESET}"
    printf "  %-18s %s\n" "Padrão atual:" "17"
    printf "  %-18s %s\n" "Alternativo:" "18 quando suportado pelo ambiente/repositório"
    echo -e "\n${CIANO}${NEGRITO}▸ Schema Zabbix detectado por dbversion.mandatory${RESET}"
    printf "  %-18s %s\n" "7000000-7039999:" "Zabbix 7.0"
    printf "  %-18s %s\n" "7040000-7050032:" "Zabbix 7.4"
    printf "  %-18s %s\n" ">=7050033:" "Zabbix 8.0"
    echo -e "\n${VERDE}${NEGRITO}Consulta concluída. Nenhuma alteração foi feita.${RESET}\n"
}

show_supported_os() {
    clear
    echo -e "${CIANO}${NEGRITO}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CIANO}${NEGRITO}║              SISTEMAS SUPORTADOS / STATUS                ║${RESET}"
    echo -e "${CIANO}${NEGRITO}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo -e "\n${CIANO}${NEGRITO}▸ SUPORTADO${RESET}"
    printf "  %-18s %-18s %s\n" "Ubuntu" "18.04" "DB e Proxy"
    printf "  %-18s %-18s %s\n" "Ubuntu" "20.04/22.04/24.04" "DB, Server e Proxy"
    printf "  %-18s %-18s %s\n" "Ubuntu" "26.04" "DB, Server e Proxy quando repos oficiais estiverem publicados"
    printf "  %-18s %-18s %s\n" "Debian" "12 bookworm" "DB, Server e Proxy"
    printf "  %-18s %-18s %s\n" "Debian" "13 trixie" "DB, Server e Proxy"
    echo -e "\n${AMARELO}${NEGRITO}▸ EXPERIMENTAL / PREPARADO${RESET}"
    printf "  %-18s %-18s %s\n" "AlmaLinux/Rocky" "8/9/10" "detectado como rhel, mas instalação bloqueada nesta versão"
    echo -e "\n${VERMELHO}${NEGRITO}▸ INDISPONÍVEL${RESET}"
    printf "  %-18s %-18s %s\n" "Debian" "11 bullseye" "sem pacotes oficiais necessários do Zabbix para esta matriz"
    printf "  %-18s %-18s %s\n" "Outros" "-" "não suportados"
    echo -e "\n${CIANO}${NEGRITO}▸ OBSERVAÇÃO${RESET}"
    echo -e "  A validação final consulta os repositórios oficiais no momento da execução:"
    echo -e "  Zabbix, PGDG/PostgreSQL, TimescaleDB/packagecloud, PHP/Nginx e dependências."
    echo -e "\n${VERDE}${NEGRITO}Consulta concluída. Nenhuma alteração foi feita.${RESET}\n"
}

supported_versions_for_component() {
    local component="$1"
    case "${OS_FAMILY}:${component}" in
        ubuntu:db)     echo "18.04 20.04 22.04 24.04 26.04" ;;
        ubuntu:server) echo "20.04 22.04 24.04 26.04" ;;
        ubuntu:proxy)  echo "16.04 18.04 20.04 22.04 24.04 26.04" ;;
        debian:db|debian:server|debian:proxy) echo "12 13" ;;
        rhel:db|rhel:server|rhel:proxy) echo "" ;;
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
    [[ -n "$version" ]] || { echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} versão Zabbix não definida para validar ${package}."; exit 1; }
    index_url="$(zabbix_packages_index_url "$version" 2>/dev/null || true)"
    if [[ -z "$index_url" ]]; then
        echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} não há índice Zabbix conhecido para ${OS_DISPLAY} + Zabbix ${version}."
        exit 1
    fi
    cache_file="${VALIDATION_CACHE_DIR}/zabbix_${OS_FAMILY}_${U_CODENAME}_${version}_$(dpkg --print-architecture 2>/dev/null || echo amd64).Packages"
    if [[ -s "$cache_file" && $(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) )) -lt 1800 ]]; then
        package_index="$(cat "$cache_file" 2>/dev/null || true)"
    elif ! package_index="$(curl -fsL --max-time 25 "$index_url" 2>/dev/null | timeout 10 gzip -dc 2>/dev/null)"; then
        echo -e "\n${VERMELHO}${NEGRITO}ERRO:${RESET} não foi possível consultar o índice oficial do Zabbix antes de alterar o APT."
        echo -e "  URL testada: ${index_url}"
        echo -e "  Sistema: ${OS_DISPLAY}"
        exit 1
    else
        printf '%s\n' "$package_index" > "$cache_file" 2>/dev/null || true
    fi
    if ! grep -q "^Package: ${package}$" <<< "$package_index"; then
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
        amd64|arm64)
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
        [[ "$ack" == "CONTINUAR" ]] || { echo -e "${AMARELO}Operação cancelada pelo operador.${RESET}"; exit 0; }
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
    local label="$1" url="$2"; shift 2
    local package_index pkg missing=0 optional=0 cache_key cache_file
    if [[ "${1:-}" == "--optional" ]]; then
        optional=1
        shift
    fi
    echo -e "  ${CIANO}Consultando:${RESET} ${url}"
    cache_key="$(printf '%s' "$url" | sed 's/[^a-zA-Z0-9_.-]/_/g')"
    cache_file="${VALIDATION_CACHE_DIR}/${cache_key}"
    if [[ -s "$cache_file" && $(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) )) -lt 1800 ]]; then
        package_index="$(cat "$cache_file" 2>/dev/null || true)"
    elif ! package_index="$(curl -fsL --max-time 30 "$url" 2>/dev/null | timeout 10 gzip -dc 2>/dev/null)"; then
        echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} não foi possível ler índice oficial: ${label}"
        echo -e "  URL: ${url}"
        exit 1
    else
        printf '%s\n' "$package_index" > "$cache_file" 2>/dev/null || true
    fi
    for pkg in "$@"; do
        if grep -q "^Package: ${pkg}$" <<< "$package_index"; then
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
            zbx_ver="7.4"; pg_ver="17"
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
            zbx_ver="7.4"; pg_ver="17"; php_ver="$(default_php_for_system)"
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

timescale_repo_os() {
    case "$OS_FAMILY" in
        ubuntu|debian) echo "$OS_FAMILY" ;;
        *) return 1 ;;
    esac
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

install_optional_packages() {
    local pkg
    for pkg in "$@"; do
        if check_package_available "$pkg" "$pkg" 1; then
            apt-get install "${APT_FLAGS[@]}" "$pkg" || \
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
    (( ${#secret} >= 12 )) && score=$(( score + 1 ))
    [[ "$secret" =~ [a-z] ]] && score=$(( score + 1 ))
    [[ "$secret" =~ [A-Z] ]] && score=$(( score + 1 ))
    [[ "$secret" =~ [0-9] ]] && score=$(( score + 1 ))
    [[ "$secret" =~ [^a-zA-Z0-9] ]] && score=$(( score + 1 ))
    if (( score < 3 )); then
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
    if ! curl -fsI --max-time 15 "$REPO_URL" >/dev/null 2>&1; then
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
    IFS='.' read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if (( octet < 0 || octet > 255 )); then
            echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} ${label} inválido: ${value}"
            echo -e "  Cada octeto IPv4 deve estar entre 0 e 255."
            exit 1
        fi
    done
}

check_disk_space() {
    local min_mb="${1:-2048}"
    local avail_mb
    avail_mb=$(df -Pm / | awk 'NR==2 {print $4}')
    if [[ -z "${avail_mb:-}" || ! "$avail_mb" =~ ^[0-9]+$ ]]; then
        echo -e "${AMARELO}⚠ Não foi possível verificar espaço livre em disco.${RESET}"
        return 0
    fi
    if (( avail_mb < min_mb )); then
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
    if (( RAM_MB < min_mb )); then
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
    [[ "$missing" == "0" ]] || { echo -e "\n${VERMELHO}${NEGRITO}ERRO:${RESET} comandos obrigatórios ausentes."; exit 1; }
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
    [[ -z "$info" ]] && { echo -e "  ${VERDE}✔ Porta ${port}/TCP livre (${label})${RESET}"; return 0; }
    case "$component:$port" in
        db:5432) [[ "$info" =~ postgres|postmaster ]] && allowed=1 ;;
        server:80|server:443) [[ "$info" =~ nginx|apache2|php-fpm|zabbix ]] && allowed=1 ;;
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
    [[ "$ok" == "1" ]] || { echo -e "${VERMELHO}Instalação abortada pelo operador.${RESET}"; exit 1; }
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
    IFS=. read -r a b _ <<< "$ip_addr"
    [[ "$a" == "10" ]] && return 0
    [[ "$a" == "172" && "$b" -ge 16 && "$b" -le 31 ]] && return 0
    [[ "$a" == "192" && "$b" == "168" ]] && return 0
    return 1
}

print_environment_context() {
    local ip_addr env_label
    ip_addr=$(primary_ipv4)
    [[ -z "$ip_addr" ]] && { echo -e "  ${AMARELO}⚠ IP principal não detectado.${RESET}"; return 0; }
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
            db)     pkg_list=$(dpkg -l 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^ii|^rc/ && $2 ~ /^(postgresql|timescaledb)/ {printf "%s ", $2}' || true) ;;
            server) pkg_list=$(dpkg -l 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^ii|^rc/ && $2 ~ /^(zabbix|nginx|php.*fpm)/ {printf "%s ", $2}' || true) ;;
            proxy)  pkg_list=$(dpkg -l 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^ii|^rc/ && $2 ~ /^zabbix/ {printf "%s ", $2}' || true) ;;
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
    local title="$1"; shift
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
    [[ "$EUID" -eq 0 ]] || { echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} execute como root/sudo."; exit 1; }
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
        db)     confirm_port_if_busy 5432 db "PostgreSQL" ;;
        server) confirm_port_if_busy 80 server "HTTP"; confirm_port_if_busy 443 server "HTTPS"; confirm_port_if_busy 10051 server "Zabbix Server" ;;
        proxy)  confirm_port_if_busy 10051 proxy "Zabbix Proxy" ;;
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
    [[ "$confirm" == "1" ]] || { echo -e "\n${AMARELO}Wipe cancelado. Nenhuma alteração feita.${RESET}"; exit 0; }
    safe_confirm_cleanup "Wipe completo solicitado" \
        "serviços zabbix-server/zabbix-agent2/zabbix-proxy/nginx/postgresql" \
        "/etc/zabbix /var/log/zabbix /var/lib/zabbix /run/zabbix" \
        "$([[ "$remove_db" == "1" ]] && echo "/etc/postgresql /var/lib/postgresql /var/log/postgresql /run/postgresql" || echo "PostgreSQL preservado")"

    COMPONENT="wipe"
    init_install_log "wipe" "/var/log/zabbix_wipe_$(date +%Y%m%d_%H%M%S).log"
    TOTAL_STEPS=5
    [[ "$remove_db" == "1" ]] && TOTAL_STEPS=$(( TOTAL_STEPS + 2 ))

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

    CURRENT_STEP=$TOTAL_STEPS; draw_progress "Wipe concluído ✔"; printf "\n"
    echo -e "\n${VERDE}${NEGRITO}Wipe concluído.${RESET}"
    echo -e "${NEGRITO}Log completo:${RESET} ${LOG_FILE}\n"
}


validate_supported_ubuntu_any_component() {
    validate_supported_system_any_component
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
        if curl -fsI --max-time 10 "$url" >/dev/null 2>&1; then
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
        if curl -fsI --max-time 10 "$test_url" >/dev/null 2>&1; then
            echo -e "  ${VERDE}✔${RESET} Zabbix ${zbx_ver} disponível para ${OS_LABEL} ${U_VER}"
            zbx_ok=1
        else
            echo -e "  ${AMARELO}⚠${RESET} Zabbix ${zbx_ver} pode não estar publicado para ${OS_LABEL} ${U_VER}"
        fi
    done
    [[ "$zbx_ok" == "0" ]] && \
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
        warn=$(( warn + 1 ))
    }
    _self_fail() {
        printf "  ${VERMELHO}✖${RESET} %s\n" "$1"
        fail=$(( fail + 1 ))
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

    printf 'DBPassword=abc=def\n# DBPassword=ignored\nDBUser=zabbix\n' > "$test_file"
    if [[ "$(conf_value "$test_file" DBPassword)" == "abc=def" && "$(conf_value "$test_file" DBUser)" == "zabbix" ]]; then
        _self_ok "conf_value preserva valores com '=' e ignora comentários"
    else
        _self_fail "conf_value não preservou valor esperado"
    fi

    printf '\033[31mERRO\033[0m\r texto\001\n' | sanitize_plain_text > "$out_file"
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

    case "$OS_FAMILY" in
        ubuntu|debian)
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
    } > "${tmpdir}/README_SUPORTE.txt"

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
    } > "${tmpdir}/system.txt"

    {
        echo "== Servicos =="
        for svc in postgresql zabbix-server zabbix-proxy zabbix-agent2 nginx php-fpm php8.1-fpm php8.2-fpm php8.3-fpm php8.4-fpm php8.5-fpm; do
            echo
            echo "### ${svc}"
            timeout 10 systemctl status "$svc" --no-pager 2>/dev/null || true
        done
    } > "${tmpdir}/services.txt"

    {
        echo "== Portas =="
        timeout 10 ss -tulnp 2>/dev/null || true
        echo
        echo "== Processos relacionados =="
        timeout 10 ps aux 2>/dev/null | awk 'NR==1 || /zabbix|postgres|nginx|php.*fpm/' || true
    } > "${tmpdir}/ports_processes.txt"

    {
        echo "== Pacotes relacionados =="
        timeout 20 dpkg -l 2>/dev/null | awk '/^ii|^rc/ && $2 ~ /(zabbix|postgresql|timescaledb|nginx|php)/ {print}' || true
        echo
        echo "== APT sources relacionadas =="
        timeout 10 ls -la /etc/apt/sources.list.d 2>/dev/null || true
        timeout 10 grep -RHiE 'zabbix|postgresql|timescale|ondrej' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true
    } > "${tmpdir}/packages_repos.txt"

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
            timeout 10 tail -n 500 "$f" > "${files_dir}/$(basename "$f").tail" 2>/dev/null || true
        fi
    done

    for f in \
        /etc/zabbix/zabbix_server.conf \
        /etc/zabbix/zabbix_proxy.conf \
        /etc/zabbix/zabbix_agent2.conf \
        /etc/zabbix/nginx.conf; do
        if [[ -f "$f" ]]; then
            timeout 10 sed -n '1,260p' "$f" > "${configs_dir}/$(basename "$f")" 2>/dev/null || true
        fi
    done

    for svc in postgresql zabbix-server zabbix-proxy zabbix-agent2 nginx; do
        timeout 15 journalctl -u "$svc" --no-pager -n 200 > "${logs_dir}/${svc}.journal.txt" 2>/dev/null || true
    done
    for f in \
        /var/log/zabbix/zabbix_server.log \
        /var/log/zabbix/zabbix_proxy.log \
        /var/log/zabbix/zabbix_agent2.log \
        /var/log/nginx/error.log \
        /var/log/nginx/access.log \
        /var/log/postgresql/*.log; do
        [[ -f "$f" ]] || continue
        timeout 10 tail -n 500 "$f" > "${logs_dir}/$(basename "$f").tail" 2>/dev/null || true
    done

    {
        echo "{"
        printf '  "created_at": "%s",\n' "$(date -Is 2>/dev/null || date)"
        printf '  "installer_version": "%s",\n' "${INSTALLER_VERSION:-unknown}"
        printf '  "host": "%s",\n' "$(hostname 2>/dev/null || echo unknown)"
        printf '  "bundle": "%s",\n' "$bundle"
        printf '  "contains_sensitive_data": true\n'
        echo "}"
    } > "${tmpdir}/manifest.json"

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
    printf "\n\n${VERDE}${NEGRITO}Simulação concluída. Nada foi instalado, removido ou alterado.${RESET}\n"
    exit 0
}

conf_value() {
    local file="$1" key="$2"
    # Usa index() para dividir apenas no primeiro = — suporta valores com = (base64, tokens)
    awk -v k="$key" '
        $0 ~ /^[[:space:]]*#/ { next }
        {
            idx = index($0, "=")
            if (idx > 0) {
                param = substr($0, 1, idx-1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", param)
                if (param == k) {
                    val = substr($0, idx+1)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
                    print val
                }
            }
        }
    ' "$file" 2>/dev/null | tail -1
}

doctor_psql_with_pgpass() {
    local host="$1" port="$2" db="$3" user="$4" pass="$5" query="$6"
    type -P psql >/dev/null 2>&1 || { echo -e "  ${AMARELO}⚠ psql não encontrado neste host.${RESET}"; return 1; }
    local pgpass_file pgpass_pass psql_bin
    psql_bin="$(type -P psql 2>/dev/null || true)"
    [[ -n "$psql_bin" ]] || { echo -e "  ${AMARELO}⚠ binário psql não encontrado neste host.${RESET}"; return 1; }
    pgpass_file=$(mktemp)
    # Garante remoção do ficheiro com senha em qualquer saída (normal, ERR, Ctrl+C)
    # shellcheck disable=SC2064
    trap "rm -f '${pgpass_file}'" RETURN
    pgpass_pass=$(pgpass_escape "$pass")
    echo "${host}:${port}:*:${user}:${pgpass_pass}" > "$pgpass_file"
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
    host=$(conf_value "$conf" "DBHost"); host=${host:-localhost}
    port=$(conf_value "$conf" "DBPort"); port=${port:-5432}
    db=$(conf_value "$conf" "DBName"); db=${db:-zabbix}
    user=$(conf_value "$conf" "DBUser"); user=${user:-zabbix}
    pass=$(conf_value "$conf" "DBPassword")
    echo -e "\n${CIANO}${NEGRITO}▸ TESTE REAL DA BASE DE DADOS${RESET}"
    if schema=$(doctor_psql_with_pgpass "$host" "$port" "$db" "$user" "$pass" "SELECT mandatory FROM dbversion LIMIT 1;"); then
        schema=$(echo "$schema" | xargs)
        echo -e "  ${VERDE}✔${RESET} Conexão PostgreSQL OK (${user}@${host}:${port}/${db})"
        echo -e "  ${VERDE}✔${RESET} Schema Zabbix dbversion: ${schema:-não informado}"
    else
        echo -e "  ${AMARELO}⚠${RESET} Falha ao conectar na BD com ${conf}"
        [[ "${DOCTOR_ACTIVE:-0}" == "1" ]] && DOCTOR_WARN=$(( DOCTOR_WARN + 1 ))
    fi
}

doctor_scan_common_log_errors() {
    local component="$1" files=() patterns file pattern count
    patterns="database is down|connection refused|permission denied|version does not match current requirements|unsupported database|cannot connect to the database|PSK identity mismatch|psk mismatch|TLS handshake failed|TLS error|certificate verify failed|too many clients already|too many connections|database is not available"
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
        while IFS= read -r pattern; do
            [[ -n "$pattern" ]] || continue
            count=$(safe_count_matches "$pattern" "$file")
            if [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]]; then
                found=1
                DOCTOR_WARN=$(( DOCTOR_WARN + 1 ))
                printf "  ${AMARELO}⚠${RESET} %-42s %s ocorrência(s) em %s\n" "$pattern" "$count" "$file"
            fi
        done < <(echo "$patterns" | tr '|' '\n')
    done
    [[ "$found" == "0" ]] && echo -e "  ${VERDE}✔ Nenhum padrão crítico conhecido encontrado nos logs verificados.${RESET}"
    return 0
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
                DOCTOR_WARN=$(( DOCTOR_WARN + 1 ))
            fi
            if pkg_is_installed "postgresql" || pkg_is_installed "postgresql-${PG_VER:-17}"; then
                echo -e "  ${VERDE}✔${RESET} Pacote PostgreSQL instalado"
            else
                echo -e "  ${AMARELO}⚠${RESET} Pacote PostgreSQL não identificado pelo gestor de pacotes"
                DOCTOR_WARN=$(( DOCTOR_WARN + 1 ))
            fi
            check_tcp_listen 5432 "PostgreSQL"
            if [[ -f /etc/zabbix/zabbix_agent2.conf || -f /etc/zabbix/zabbix_agent2.psk ]]; then
                validate_service_active zabbix-agent2
                echo -e "\n${CIANO}${NEGRITO}▸ AGENT 2 DA BASE DE DADOS${RESET}"
                printf "  %-18s %s\n" "Hostname:" "$(conf_value /etc/zabbix/zabbix_agent2.conf Hostname)"
                printf "  %-18s %s\n" "Server:" "$(conf_value /etc/zabbix/zabbix_agent2.conf Server)"
                printf "  %-18s %s\n" "ServerActive:" "$(conf_value /etc/zabbix/zabbix_agent2.conf ServerActive)"
                [[ -f /etc/zabbix/zabbix_agent2.psk ]] && \
                    echo -e "  ${VERDE}✔${RESET} PSK configurado (/etc/zabbix/zabbix_agent2.psk)" || \
                    echo -e "  ${AMARELO}⚠${RESET} PSK não configurado"
            fi
            if type -P psql >/dev/null 2>&1; then
                safe_diag_cmd postgres_psql -tAc "SELECT version();" | sed 's/^/  PostgreSQL: /' || true
                echo -e "\n${CIANO}${NEGRITO}▸ TIMESCALEDB${RESET}"
                local tsdb_info tsdb_db
                # Determina o nome da BD: lê do zabbix_server.conf se existir, senão usa "zabbix"
                tsdb_db="zabbix"
                [[ -f /etc/zabbix/zabbix_server.conf ]] && \
                    tsdb_db=$(timeout 10 awk -F'=' '/^DBName[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2}' \
                        /etc/zabbix/zabbix_server.conf 2>/dev/null | head -1 || true)
                [[ -z "$tsdb_db" ]] && tsdb_db="zabbix"
                tsdb_info=$(safe_diag_cmd postgres_psql -d "$tsdb_db" -tAc \
                    "SELECT extname || ' ' || extversion FROM pg_extension WHERE extname='timescaledb';" \
                    | xargs || true)
                if [[ -n "$tsdb_info" ]]; then
                    echo -e "  ${VERDE}✔${RESET} Extensão carregada: ${tsdb_info} (BD: ${tsdb_db})"
                else
                    echo -e "  ${AMARELO}⚠${RESET} Extensão timescaledb não encontrada na BD '${tsdb_db}'"
                    DOCTOR_WARN=$(( DOCTOR_WARN + 1 ))
                fi
            else
                echo -e "  ${AMARELO}⚠ psql não encontrado para diagnóstico local.${RESET}"
                DOCTOR_WARN=$(( DOCTOR_WARN + 1 ))
            fi
            ;;
        server)
            validate_service_active zabbix-server
            validate_service_active nginx
            local php_svc
            php_svc=$(safe_diag_cmd systemctl list-units 'php*-fpm.service' --no-legend --no-pager | awk '{print $1}' | head -1 || true)
            [[ -n "$php_svc" ]] && validate_service_active "${php_svc%.service}" || { echo -e "  ${AMARELO}⚠ Serviço php-fpm não detectado.${RESET}"; DOCTOR_WARN=$(( DOCTOR_WARN + 1 )); }
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
                [[ -f /etc/zabbix/zabbix_agent2.psk ]] && \
                    echo -e "  ${VERDE}✔${RESET} PSK configurado (/etc/zabbix/zabbix_agent2.psk)" || \
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
                echo -e "\n${CIANO}${NEGRITO}▸ AGENT 2 DO PROXY${RESET}"
                validate_service_active zabbix-agent2
                printf "  %-18s %s\n" "Hostname:" "$(conf_value /etc/zabbix/zabbix_agent2.conf Hostname)"
                printf "  %-18s %s\n" "Server:" "$(conf_value /etc/zabbix/zabbix_agent2.conf Server)"
                printf "  %-18s %s\n" "ServerActive:" "$(conf_value /etc/zabbix/zabbix_agent2.conf ServerActive)"
                [[ -f /etc/zabbix/zabbix_agent2.psk ]] && \
                    echo -e "  ${VERDE}✔${RESET} PSK configurado (/etc/zabbix/zabbix_agent2.psk)" || \
                    echo -e "  ${AMARELO}⚠${RESET} PSK não configurado"
            fi
            ;;
    esac
    doctor_scan_common_log_errors "$component"
    echo -e "\n${CIANO}${NEGRITO}▸ RESULTADO DO DOCTOR${RESET}"
    if [[ "$DOCTOR_FAIL" -gt 0 ]]; then
        DOCTOR_WARN=$(( DOCTOR_WARN + DOCTOR_FAIL ))
        printf "  ${AMARELO}${NEGRITO}%-18s${RESET} %s aviso(s)\n" "COM AVISOS" "$DOCTOR_WARN"
    elif [[ "$DOCTOR_WARN" -gt 0 ]]; then
        printf "  ${AMARELO}${NEGRITO}%-18s${RESET} %s aviso(s)\n" "COM AVISOS" "$DOCTOR_WARN"
    else
        printf "  ${VERDE}${NEGRITO}%-18s${RESET} Nenhuma falha encontrada\n" "OK"
    fi
    DOCTOR_ACTIVE=0
    echo -e "\n${VERDE}${NEGRITO}Doctor concluído. Nenhuma alteração foi feita.${RESET}\n"
}

[[ "$LIST_VERSIONS" == "1" ]] && { show_supported_versions; exit 0; }
[[ "$LIST_SUPPORTED_OS" == "1" ]] && { show_supported_os; exit 0; }
[[ "$SELF_TEST_MODE" == "1" ]] && { run_self_test; exit 0; }
validate_supported_ubuntu_any_component
[[ "$COLLECT_SUPPORT_BUNDLE" == "1" ]] && { collect_support_bundle; exit 0; }
[[ "$DEBUG_SERVICES" == "1" ]] && { run_debug_services; exit 0; }
[[ "$WIPE_MODE" == "1" ]] && { run_wipe_mode; exit 0; }
[[ "$CHECK_ONLY" == "1" ]] && { run_check_mode; exit 0; }


# ------------------------------------------------------------------------------
# 4. BANNER + SELEÇÃO DE COMPONENTE
# ------------------------------------------------------------------------------
clear
echo -e "${VERMELHO}${NEGRITO}"
cat << "EOF"
███████╗ █████╗ ██████╗ ██████╗ ██╗██╗  ██╗
╚══███╔╝██╔══██╗██╔══██╗██╔══██╗██║╚██╗██╔╝
  ███╔╝ ███████║██████╔╝██████╔╝██║ ╚███╔╝
 ███╔╝  ██╔══██║██╔══██╗██╔══██╗██║ ██╔██╗
███████╗██║  ██║██████╔╝██████╔╝██║██╔╝ ██╗
╚══════╝╚═╝  ╚═╝╚═════╝ ╚═════╝ ╚═╝╚═╝  ╚═╝
EOF
echo -e "        INSTALADOR UNIFICADO — Enterprise Suite ${INSTALLER_VERSION}${RESET}"
echo -e "        ${CIANO}Zabbix Unified Installer — By Denys Gonçalves${RESET}"
echo -e "        ${VERDE}Sistema detetado: ${OS_DISPLAY}${RESET}"
echo -e "        ${CIANO}Hardware: ${RAM_MB} MB RAM | ${CPU_CORES} núcleos CPU${RESET}\n"

echo -e "${CIANO}${NEGRITO}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${CIANO}${NEGRITO}║           SELECIONE O COMPONENTE A INSTALAR              ║${RESET}"
echo -e "${CIANO}${NEGRITO}╚══════════════════════════════════════════════════════════╝${RESET}"
echo -e "  ${AMARELO}1)${RESET} Instalar ${NEGRITO}Database${RESET} — PostgreSQL ${VERDE}17/18${RESET} + TimescaleDB"
echo -e "  ${AMARELO}2)${RESET} Instalar ${NEGRITO}Server${RESET}   — Zabbix Server + Frontend + Nginx"
echo -e "  ${AMARELO}3)${RESET} Instalar ${NEGRITO}Proxy${RESET}    — Zabbix Proxy + Agent 2"
echo -e "  ${AMARELO}4)${RESET} ${VERMELHO}Sair${RESET}"
echo ""
COMPONENT="${REQUESTED_COMPONENT:-}"
if [[ -n "$COMPONENT" ]]; then
    echo -e "  ${VERDE}Componente selecionado por parâmetro: ${NEGRITO}${COMPONENT}${RESET}"
else
    while true; do
        read -rp "  Escolha (1, 2, 3 ou 4): " COMP_OPT
        case "$COMP_OPT" in
            1) COMPONENT="db";     break ;;
            2) COMPONENT="server"; break ;;
            3) COMPONENT="proxy";  break ;;
            4) echo -e "\n${AMARELO}Saindo sem executar alterações.${RESET}"; exit 0 ;;
            *) echo -e "  ${VERMELHO}Opção inválida.${RESET}" ;;
        esac
    done
fi
if [[ "$DRY_RUN" == "1" ]]; then
    show_dry_run_plan "$COMPONENT"
    exit 0
fi
if [[ "$REPO_CHECK" == "1" ]]; then
    run_repo_check "$COMPONENT"
    exit 0
fi
if [[ "$DOCTOR_MODE" == "1" ]]; then
    run_doctor_mode "$COMPONENT"
    exit 0
fi
if [[ "$SIMULATE_MODE" == "1" ]]; then
    echo -e "  ${AMARELO}${NEGRITO}MODO SIMULAÇÃO:${RESET} o questionário será mantido, mas o pipeline não executará ações reais."
else
acquire_install_lock
fi

# ==============================================================================
# 5. COMPONENTES
# ==============================================================================
case "$COMPONENT" in

# ══════════════════════════════════════════════════════════════════════════════
# COMPONENTE 1 — BASE DE DADOS (PostgreSQL + TimescaleDB) — DB v1.5
# ══════════════════════════════════════════════════════════════════════════════
db)
    component_supported_or_die "db"

    if [[ "$SIMULATE_MODE" == "1" ]]; then
        LOG_FILE=""
    else
        init_install_log "db" "/var/log/zabbix_db_install_$(date +%Y%m%d_%H%M%S).log"
    fi
    log_msg "INFO" "Log iniciado para componente DB em ${LOG_FILE}"

    # Função exclusiva do PostgreSQL: formato "param = value"
    set_pg_config() {
        local file=$1 param=$2 value=$3
        local escaped_value="${value//\\/\\\\}"
        escaped_value="${escaped_value//&/\\&}"
        escaped_value="${escaped_value//|/\\|}"
        if [ ! -f "$file" ]; then
            echo "Arquivo de configuração PostgreSQL não encontrado: ${file}" >&2
            return 1
        fi
        if grep -qE "^[[:space:]]*${param}[[:space:]]*=" "$file"; then
            sed -i "s|^[[:space:]]*${param}[[:space:]]*=.*|${param} = ${escaped_value}|" "$file"
        elif grep -qE "^#[[:space:]]*${param}[[:space:]]*=" "$file"; then
            sed -i "0,/^#[[:space:]]*${param}[[:space:]]*=/{s|^#[[:space:]]*${param}[[:space:]]*=.*|${param} = ${escaped_value}|}" "$file"
        else
            echo "${param} = ${value}" >> "$file"
        fi
    }

    calc_pg_auto_tuning() {
        local ram=$RAM_MB
        if   (( ram >= 16384 )); then PG_MAX_CONN="500"
        elif (( ram >=  8192 )); then PG_MAX_CONN="300"
        elif (( ram >=  4096 )); then PG_MAX_CONN="200"
        else                          PG_MAX_CONN="100"
        fi
        local sb=$(( ram * 25 / 100 ))
        (( sb <  128 )) && sb=128; (( sb > 8192 )) && sb=8192
        PG_SHARED_BUF="${sb}MB"
        local wm=$(( ram * 25 / 100 / PG_MAX_CONN ))
        (( wm <  4 )) && wm=4; (( wm > 64 )) && wm=64
        PG_WORK_MEM="${wm}MB"
        local mm=$(( ram / 8 ))
        (( mm <   64 )) && mm=64; (( mm > 2048 )) && mm=2048
        PG_MAINT_MEM="${mm}MB"
        local ec=$(( ram * 75 / 100 ))
        (( ec < 256 )) && ec=256
        PG_EFF_CACHE="${ec}MB"
        local wb=$(( sb * 3 / 100 ))
        (( wb <  8 )) && wb=8; (( wb > 64 )) && wb=64
        PG_WAL_BUFS="${wb}MB"
        PG_CKPT="0.9"; PG_STATS="100"; PG_RAND_COST="1.1"
    }

    # Variáveis de estado
    PG_VER="17"; USE_TSDB_TUNE="1"; ZBX_TARGET_VERSION="7.4"; ZBX_AGENT_VERSION="7.4"
    ZBX_SERVER_IPS=()
    DB_NAME="zabbix"; DB_USER="zabbix"; DB_PASS=""
    UPDATE_SYSTEM="0"; CLEAN_INSTALL=0; USE_TUNING="0"
    INSTALL_AGENT="0"; USE_PSK="0"; AG_SERVER=""; AG_SERVER_ACTIVE=""
    AG_HOSTNAME=""; AG_ALLOWKEY="0"; PSK_AGENT_ID=""; PSK_AGENT_KEY=""
    PG_MAX_CONN="200"; PG_SHARED_BUF="256MB"; PG_WORK_MEM="8MB"
    PG_MAINT_MEM="128MB"; PG_EFF_CACHE="768MB"; PG_WAL_BUFS="16MB"
    PG_CKPT="0.9"; PG_STATS="100"; PG_RAND_COST="1.1"
    PG_CLUSTER_NAME="main"; PG_CONF_FILE=""; PG_HBA_FILE=""
    DB_TIMEZONE="${SYS_TIMEZONE:-America/Sao_Paulo}"

    # Detectar IP local primário para listen_addresses (apenas a interface de saída)
    # listen_addresses = IPs DESTA máquina onde o PostgreSQL escuta
    # pg_hba.conf      = IPs do Zabbix Server que têm permissão de ligar
    PG_LOCAL_IP=""
    if command -v ip >/dev/null 2>&1; then
        PG_LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true)
    fi
    if [[ -n "$PG_LOCAL_IP" ]]; then
        PG_LISTEN_ADDR="'localhost,${PG_LOCAL_IP}'"
    else
        PG_LISTEN_ADDR="'*'"   # fallback se deteção falhar
    fi

    # Banner BD
    clear
    echo -e "${VERMELHO}${NEGRITO}"
    cat << "EOF"
██████╗  █████╗ ████████╗ █████╗ ██████╗  █████╗ ███████╗███████╗
██╔══██╗██╔══██╗╚══██╔══╝██╔══██╗██╔══██╗██╔══██╗██╔════╝██╔════╝
██║  ██║███████║   ██║   ███████║██████╔╝███████║███████╗█████╗
██║  ██║██╔══██║   ██║   ██╔══██║██╔══██╗██╔══██║╚════██║██╔══╝
██████╔╝██║  ██║   ██║   ██║  ██║██████╔╝██║  ██║███████║███████╗
╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚═╝  ╚═╝╚═════╝ ╚═╝  ╚═╝╚══════╝╚══════╝
EOF
    echo -e "        PostgreSQL + TimescaleDB — Instalador Enterprise v1.5${RESET}"
    echo -e "        ${VERDE}Sistema detetado: ${OS_DISPLAY} ✔${RESET}"
    echo -e "        ${CIANO}Hardware detetado: ${RAM_MB} MB RAM | ${CPU_CORES} núcleos de CPU${RESET}\n"

    # Questionário
    m_clean() {
        local Z_LIST
        Z_LIST=$(dpkg -l 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^ii|^rc/ && $2 ~ /(postgresql|timescaledb)/ {print $2}' || true)
        if [[ -n "$Z_LIST" ]]; then
            echo -e "\n${VERMELHO}${NEGRITO}⚠  Instalação anterior detetada:${RESET}"
            echo -e "${VERMELHO}   $(echo "$Z_LIST" | tr '\n' ' ')${RESET}"
            echo -e "${AMARELO}   Será removida completamente antes de instalar.${RESET}"
            CLEAN_INSTALL=1
        else
            CLEAN_INSTALL=0
        fi
    }

    m_update() {
        echo -e "\n${CIANO}${NEGRITO}>>> ATUALIZAÇÃO DO SISTEMA <<<${RESET}"
        echo -e "  Recomenda-se atualizar o SO antes de instalar o PostgreSQL."
        ask_yes_no "Fazer upgrade seguro dos pacotes do sistema?" UPDATE_SYSTEM
    }

    m_versions() {
        echo -e "\n${CIANO}${NEGRITO}>>> VERSÕES E TABELA DE COMPATIBILIDADE <<<${RESET}"
        echo -e ""
        echo -e "${AMARELO}${NEGRITO}Versão Zabbix alvo deste ambiente:${RESET}"
        echo -e "   1) ${NEGRITO}7.0 LTS${RESET}"
        echo -e "   2) ${NEGRITO}7.4 Current${RESET} ${VERDE}(recomendado se o Server for 7.4)${RESET}"
        while true; do
            read -rp "   Escolha (1 ou 2): " zbx_target_opt
            case "$zbx_target_opt" in
                1) ZBX_TARGET_VERSION="7.0"; break ;;
                2) ZBX_TARGET_VERSION="7.4"; break ;;
                *) echo -e "   ${VERMELHO}Opção inválida.${RESET}" ;;
            esac
        done
        ZBX_AGENT_VERSION="$ZBX_TARGET_VERSION"
        echo -e ""
        echo -e "  ${NEGRITO}Zabbix 7.x suporta (documentação oficial):${RESET}"
        echo -e "  ┌─────────────────┬─────────────────────────────────────────┐"
        echo -e "  │  PostgreSQL     │  TimescaleDB compatível                 │"
        echo -e "  ├─────────────────┼─────────────────────────────────────────┤"
        echo -e "  │  ${VERDE}17 (Estável)${RESET}   │  ${VERDE}2.13 – 2.26 ✔ (Totalmente suportado)${RESET}   │"
        echo -e "  │  ${AMARELO}18 (Recente)${RESET}   │  ${AMARELO}2.x   ⚠ (Pode ser experimental)${RESET}      │"
        echo -e "  └─────────────────┴─────────────────────────────────────────┘"
        echo -e "  ${CIANO}Zabbix 7.0 / 7.4: PostgreSQL 13–18 + TimescaleDB 2.13+${RESET}"
        echo -e "  ${CIANO}Zabbix 8.0 LTS  : PostgreSQL 15–18 + TimescaleDB 2.20+ (mínimos mais altos)${RESET}"
        echo -e ""
        echo -e "${AMARELO}${NEGRITO}Versão do PostgreSQL a instalar:${RESET}"
        echo -e "   1) PostgreSQL 17 ${VERDE}(Recomendado — TimescaleDB totalmente suportado)${RESET}"
        echo -e "   2) PostgreSQL 18 ${AMARELO}(Mais recente — verificar compatibilidade TimescaleDB)${RESET}"
        while true; do
            read -rp "   Escolha (1 ou 2): " pg_opt
            case "$pg_opt" in
                1) PG_VER="17"; break ;;
                2) PG_VER="18"
                   echo -e "\n   ${AMARELO}${NEGRITO}⚠  ATENÇÃO: PostgreSQL 18 + TimescaleDB pode ser experimental.${RESET}"
                   break ;;
                *) echo -e "   ${VERMELHO}Opção inválida.${RESET}" ;;
            esac
        done
    }

    m_zbxserver_ip() {
        echo -e "\n${CIANO}${NEGRITO}>>> ACESSO REMOTO AO BANCO DE DADOS <<<${RESET}"
        echo -e "  O IP ou rede do Zabbix Server será adicionado ao pg_hba.conf"
        echo -e "  para autorizar a conexão remota com autenticação scram-sha-256."
        echo -e ""
        echo -e "  ${AMARELO}Formatos aceites:${RESET}"
        echo -e "    IP único:     ${NEGRITO}192.168.1.100${RESET}      → adiciona /32 automaticamente"
        echo -e "    CIDR/Rede:    ${NEGRITO}192.168.1.0/24${RESET}     → aceita a sub-rede inteira"
        echo -e "    Qualquer IP:  ${NEGRITO}0.0.0.0/0${RESET}          → sem restrição de origem ⚠"
        echo -e ""
        ZBX_SERVER_IPS=()
        local idx=1
        while true; do
            echo -e "  ${AMARELO}${NEGRITO}Entrada ${idx}:${RESET} IP ou CIDR do Zabbix Server"
            local entry
            while true; do
                read -rp "   Preencher: " entry
                [[ -n "$entry" ]] && break
                echo -e "   ${VERMELHO}Campo obrigatório.${RESET}"
            done
            validate_ipv4_cidr "$entry" "IP/CIDR do Zabbix Server"
            ZBX_SERVER_IPS+=("$entry")
            idx=$(( idx + 1 ))
            local mais
            ask_yes_no "Adicionar mais um IP/CIDR ao pg_hba.conf?" mais
            [[ "$mais" == "0" ]] && break
        done
        echo -e "\n  ${VERDE}Entradas configuradas:${RESET}"
        for e in "${ZBX_SERVER_IPS[@]}"; do
            [[ "$e" =~ / ]] && echo -e "    ✔  $e" || echo -e "    ✔  ${e}/32"
        done
    }

    m_dbcreds() {
        echo -e "\n${CIANO}${NEGRITO}>>> CREDENCIAIS DA BASE DE DADOS <<<${RESET}"
        echo -e "\n${AMARELO}Nome da Base de Dados${RESET} (Padrão Zabbix: zabbix)"
        read -rp "   Valor Recomendado [zabbix]: " DB_NAME; DB_NAME=${DB_NAME:-zabbix}
        validate_identifier "$DB_NAME" "Nome da base de dados"
        echo -e "\n${AMARELO}Utilizador da Base de Dados${RESET}"
        echo -e "   1) Gerar utilizador aleatório ${CIANO}(ex: zbx_f3a2b1c9)${RESET} — mais seguro"
        echo -e "   2) Usar o nome padrão ${CIANO}'zabbix'${RESET}          — convencional"
        echo -e "   3) Definir manualmente"
        while true; do
            read -rp "   Escolha (1, 2 ou 3): " u_opt
            case "$u_opt" in
                1) DB_USER="zbx_$(openssl rand -hex 4)"
                   echo -e "   ${VERDE}Utilizador gerado: ${NEGRITO}${DB_USER}${RESET}"; break ;;
                2) DB_USER="zabbix"
                   echo -e "   ${VERDE}Utilizador: ${NEGRITO}${DB_USER}${RESET}"; break ;;
                3) while true; do
                       read -rp "   Nome do utilizador: " DB_USER
                       [[ -n "$DB_USER" ]] && break
                       echo -e "   ${VERMELHO}Campo obrigatório.${RESET}"
                   done; break ;;
                *) echo -e "   ${VERMELHO}Opção inválida.${RESET}" ;;
            esac
        done
        echo -e "\n${AMARELO}Senha do Utilizador${RESET}"
        echo -e "   A senha é sempre gerada automaticamente (32 caracteres hex)."
        DB_PASS=$(openssl rand -hex 16)
        echo -e "   ${VERDE}Senha gerada: ${NEGRITO}${DB_PASS}${RESET}"
        local redef
        ask_yes_no "Redefinir a senha manualmente?" redef
        if [[ "$redef" == "1" ]]; then
            while true; do
                read -rsp "   Nova senha: " DB_PASS; echo
                [[ -n "$DB_PASS" ]] && break
                echo -e "   ${VERMELHO}Campo obrigatório.${RESET}"
            done
            warn_weak_secret "$DB_PASS" "Senha da base de dados"
        fi
    }

    m_agent() {
        echo -e "\n${CIANO}${NEGRITO}>>> ZABBIX AGENT 2 (nesta máquina BD) <<<${RESET}"
        echo -e "  Opcional: instala o Agent 2 no host da base de dados para cadastro posterior"
        echo -e "  no Zabbix Server, mantendo a mesma lógica usada nas camadas Server e Proxy."
        ask_yes_no "Instalar e configurar o Zabbix Agent 2 neste host de BD?" INSTALL_AGENT
        if [[ "$INSTALL_AGENT" == "1" ]]; then
            ZBX_AGENT_VERSION="$ZBX_TARGET_VERSION"
            echo -e "\n${CIANO}O Agent 2 usará o repositório Zabbix ${ZBX_AGENT_VERSION}, conforme a versão alvo escolhida.${RESET}"
            local default_server="${ZBX_SERVER_IPS[0]:-127.0.0.1}"
            echo -e "\n${AMARELO}Server${RESET} (escuta passiva autorizada)"
            read -rp "   Valor recomendado [${default_server}]: " AG_SERVER; AG_SERVER=${AG_SERVER:-$default_server}
            validate_zabbix_identity "$AG_SERVER" "Server do Agente"
            echo -e "\n${AMARELO}ServerActive${RESET} (envio ativo para o Server)"
            read -rp "   Valor recomendado [${default_server}]: " AG_SERVER_ACTIVE; AG_SERVER_ACTIVE=${AG_SERVER_ACTIVE:-$default_server}
            validate_zabbix_identity "$AG_SERVER_ACTIVE" "ServerActive do Agente"
            echo -e "\n${AMARELO}Hostname do Agente${RESET} (nome que será cadastrado no frontend)"
            while true; do
                read -rp "   Preencher [DB-$(hostname)]: " AG_HOSTNAME
                AG_HOSTNAME=${AG_HOSTNAME:-DB-$(hostname)}
                [[ -n "$AG_HOSTNAME" ]] && break
            done
            validate_zabbix_identity "$AG_HOSTNAME" "Hostname do Agente"
            echo -e "${VERMELHO}${NEGRITO}⚠ ATENÇÃO:${RESET} AllowKey=system.run[*] permite execução remota de comandos pelo Zabbix."
            echo -e "${AMARELO}Use apenas em ambiente controlado e preferencialmente com PSK/TLS.${RESET}"
            ask_yes_no "   Habilitar AllowKey=system.run[*] neste agente?" AG_ALLOWKEY

            ask_yes_no "Configurar criptografia PSK para o Agent 2 da BD?" USE_PSK
            if [[ "$USE_PSK" == "1" ]]; then
                while true; do
                    read -rp "   Identidade PSK do Agente (ex: AGENT-DB-01): " PSK_AGENT_ID
                    [[ -n "$PSK_AGENT_ID" ]] && break
                    echo -e "   ${VERMELHO}Campo obrigatório.${RESET}"
                done
                validate_zabbix_identity "$PSK_AGENT_ID" "PSK Identity do Agente"
            fi
        else
            USE_PSK="0"; AG_ALLOWKEY="0"; PSK_AGENT_ID=""
        fi
    }

    m_tsdb_tune() {
        echo -e "\n${CIANO}${NEGRITO}>>> OTIMIZAÇÃO AUTOMÁTICA DO TIMESCALEDB <<<${RESET}"
        echo -e "  O comando ${NEGRITO}timescaledb-tune${RESET} analisa o hardware desta máquina"
        echo -e "  e ajusta automaticamente o postgresql.conf."
        echo -e "  ${CIANO}Hardware detetado: ${NEGRITO}${RAM_MB} MB RAM${RESET} ${CIANO}|${RESET} ${NEGRITO}${CPU_CORES} núcleos${RESET}"
        ask_yes_no "Executar timescaledb-tune (recomendado)?" USE_TSDB_TUNE
    }

    m_max_connections() {
        echo -e "\n${CIANO}${NEGRITO}>>> MAX_CONNECTIONS (CONEXÕES SIMULTÂNEAS AO POSTGRESQL) <<<${RESET}"
        echo -e "  Define o número máximo de conexões simultâneas aceites pelo PostgreSQL."
        echo -e ""
        echo -e "  ${NEGRITO}Por que isto é crítico com uploads grandes?${RESET}"
        echo -e "  Quando importa templates ou imagens grandes pelo Frontend Zabbix,"
        echo -e "  o PHP-FPM abre múltiplas conexões ao mesmo tempo para processar o upload."
        echo -e "  Se ${NEGRITO}max_connections${RESET} for baixo demais e ${NEGRITO}upload_max_filesize${RESET} for alto,"
        echo -e "  o PostgreSQL começa a rejeitar ligações com o erro:"
        echo -e "  ${VERMELHO}FATAL: sorry, too many clients already${RESET}"
        echo -e ""
        echo -e "  ${NEGRITO}Regra prática:${RESET}"
        echo -e "  ${AMARELO}•${RESET} Zabbix Server normal (sem uploads grandes): ${VERDE}200${RESET} é suficiente"
        echo -e "  ${AMARELO}•${RESET} Upload PHP até 64M  → mínimo ${VERDE}300${RESET} recomendado"
        echo -e "  ${AMARELO}•${RESET} Upload PHP até 128M → mínimo ${VERDE}400${RESET} recomendado"
        echo -e "  ${AMARELO}•${RESET} Upload PHP 200M+    → ${VERDE}500${RESET} ou mais"
        echo -e ""
        echo -e "  ${AMARELO}Atenção:${RESET} cada conexão consome ~5–10MB de RAM."
        echo -e "  Hardware detetado: ${NEGRITO}${RAM_MB} MB RAM${RESET} → sugestão automática: ${VERDE}${PG_MAX_CONN}${RESET}"
        echo -e ""
        read -rp "  max_connections [${PG_MAX_CONN}]: " _v
        PG_MAX_CONN=${_v:-$PG_MAX_CONN}
        if [[ ! "$PG_MAX_CONN" =~ ^[0-9]+$ || "$PG_MAX_CONN" -lt 10 ]]; then
            echo -e "${VERMELHO}ERRO:${RESET} max_connections inválido: ${PG_MAX_CONN}"; exit 1
        fi
    }

    m_pgtuning() {
        ask_yes_no "Aplicar Tuning Manual de Performance do PostgreSQL?" USE_TUNING
        if [[ "$USE_TUNING" == "1" ]]; then
            calc_pg_auto_tuning
            echo -e "\n${CIANO}${NEGRITO}>>> ASSISTENTE DE TUNING DO POSTGRESQL <<<${RESET}"
            echo -e "  ${NEGRITO}Hardware detetado: ${RAM_MB} MB RAM | ${CPU_CORES} núcleos${RESET}"
            echo -e "  Valores calculados automaticamente para este hardware:\n"
            printf "    %-34s ${VERDE}%s${RESET}\n" "shared_buffers (25% RAM):"      "$PG_SHARED_BUF"
            printf "    %-34s ${VERDE}%s${RESET}\n" "work_mem:"                      "$PG_WORK_MEM"
            printf "    %-34s ${VERDE}%s${RESET}\n" "maintenance_work_mem (12.5%):"  "$PG_MAINT_MEM"
            printf "    %-34s ${VERDE}%s${RESET}\n" "effective_cache_size (75%):"    "$PG_EFF_CACHE"
            printf "    %-34s ${VERDE}%s${RESET}\n" "wal_buffers:"                   "$PG_WAL_BUFS"
            printf "    %-34s ${VERDE}%s${RESET}\n" "checkpoint_completion_target:"  "$PG_CKPT"
            printf "    %-34s ${VERDE}%s${RESET}\n" "default_statistics_target:"     "$PG_STATS"
            printf "    %-34s ${VERDE}%s${RESET}\n" "random_page_cost (SSD):"        "$PG_RAND_COST"
            echo ""
            local use_auto
            ask_yes_no "Usar estes valores calculados automaticamente?" use_auto
            if [[ "$use_auto" == "0" ]]; then
                echo -e "\n  Prima [ENTER] para usar o valor calculado entre [colchetes].\n"

                echo -e "${AMARELO}1. shared_buffers${RESET} (25% da RAM | Padrão PG: 128MB)"
                echo -e "   Cache de dados em memória. Regra geral: 25% da RAM total."
                read -rp "   Valor calculado [${PG_SHARED_BUF}]: " _v; PG_SHARED_BUF=${_v:-$PG_SHARED_BUF}

                echo -e "\n${AMARELO}3. work_mem${RESET} (Padrão PG: 4MB)"
                echo -e "   Memória por operação de ordenação/hash. Multiplica por conexões ativas."
                read -rp "   Valor calculado [${PG_WORK_MEM}]: " _v; PG_WORK_MEM=${_v:-$PG_WORK_MEM}

                echo -e "\n${AMARELO}4. maintenance_work_mem${RESET} (12.5% da RAM | Padrão PG: 64MB)"
                echo -e "   Memória para VACUUM, CREATE INDEX, etc."
                read -rp "   Valor calculado [${PG_MAINT_MEM}]: " _v; PG_MAINT_MEM=${_v:-$PG_MAINT_MEM}

                echo -e "\n${AMARELO}5. effective_cache_size${RESET} (75% da RAM | Padrão PG: 4GB)"
                echo -e "   Estimativa do cache disponível ao PostgreSQL (SO + PG). Ajuda o planeador."
                read -rp "   Valor calculado [${PG_EFF_CACHE}]: " _v; PG_EFF_CACHE=${_v:-$PG_EFF_CACHE}

                echo -e "\n${AMARELO}6. wal_buffers${RESET} (3% de shared_buffers | Padrão PG: auto)"
                echo -e "   Buffer de memória para o Write-Ahead Log. Melhora escrita em disco."
                read -rp "   Valor calculado [${PG_WAL_BUFS}]: " _v; PG_WAL_BUFS=${_v:-$PG_WAL_BUFS}

                echo -e "\n${AMARELO}7. checkpoint_completion_target${RESET} (Padrão PG: 0.9)"
                echo -e "   Fracção do intervalo de checkpoint para distribuir a escrita. 0.9 é ideal."
                read -rp "   Valor calculado [${PG_CKPT}]: " _v; PG_CKPT=${_v:-$PG_CKPT}

                echo -e "\n${AMARELO}8. default_statistics_target${RESET} (Padrão PG: 100)"
                echo -e "   Detalhe das estatísticas do planeador. Mais alto = queries mais eficientes."
                read -rp "   Valor calculado [${PG_STATS}]: " _v; PG_STATS=${_v:-$PG_STATS}

                echo -e "\n${AMARELO}9. random_page_cost${RESET} (SSD: 1.1 | HDD: 4.0 | Padrão PG: 4.0)"
                echo -e "   Custo estimado de acesso aleatório. Use 1.1 para SSD, 4.0 para HDD."
                read -rp "   Valor calculado [${PG_RAND_COST}]: " _v; PG_RAND_COST=${_v:-$PG_RAND_COST}
            fi
            validate_size "$PG_SHARED_BUF" "shared_buffers"
            validate_size "$PG_WORK_MEM" "work_mem"
            validate_size "$PG_MAINT_MEM" "maintenance_work_mem"
            validate_size "$PG_EFF_CACHE" "effective_cache_size"
            validate_size "$PG_WAL_BUFS" "wal_buffers"
            validate_decimal_range "$PG_CKPT" "checkpoint_completion_target" "0" "1"
            validate_int_range "$PG_STATS" "default_statistics_target" 1 10000
            validate_decimal_range "$PG_RAND_COST" "random_page_cost" "0" "100"
        fi
    }

    m_timezone() {
        DB_TIMEZONE="$(select_timezone_value "$DB_TIMEZONE" "Será aplicado ao PostgreSQL (postgresql.conf) e à base de dados Zabbix.")"
        echo -e "   ${VERDE}Fuso configurado: ${NEGRITO}${DB_TIMEZONE}${RESET}"
    }

    m_clean; m_update; m_versions; m_zbxserver_ip; m_dbcreds; m_agent; m_max_connections; m_tsdb_tune; m_pgtuning; m_timezone

    # Menu de revisão
    while true; do
        clear
        echo -e "${CIANO}${NEGRITO}╔══════════════════════════════════════════════════════════╗${RESET}"
        echo -e "${CIANO}${NEGRITO}║           REVISÃO FINAL — CAMADA DE BASE DE DADOS        ║${RESET}"
        echo -e "${CIANO}${NEGRITO}╚══════════════════════════════════════════════════════════╝${RESET}"
        echo -e "  ${AMARELO}1)${RESET} Limpeza:              $([[ "$CLEAN_INSTALL" == "1" ]] && echo -e "${VERMELHO}INSTALAÇÃO ANTERIOR DETETADA — será removida${RESET}" || echo "Sistema limpo")"
        echo -e "  ${AMARELO}2)${RESET} Atualização:          $([[ "$UPDATE_SYSTEM" == "1" ]] && echo -e "${VERDE}ATIVADA${RESET}" || echo "NÃO")"
        echo -e "  ${AMARELO}3)${RESET} Versão Zabbix alvo:   ${VERDE}${ZBX_TARGET_VERSION}${RESET}"
        echo -e "  ${AMARELO}4)${RESET} Versão PostgreSQL:    ${VERDE}${PG_VER}${RESET}"
        echo -e "  ${AMARELO}5)${RESET} PG listen_addresses:  ${CIANO}${PG_LISTEN_ADDR}${RESET}  ${AMARELO}← esta máquina BD${RESET}"
        echo -e "  ${AMARELO}6)${RESET} Acesso Remoto (IPs):  ${NEGRITO}$(IFS=', '; echo "${ZBX_SERVER_IPS[*]:-<não definido>}")${RESET}  ${AMARELO}← Zabbix Server (pg_hba.conf)${RESET}"
        echo -e "  ${AMARELO}7)${RESET} BD / Utilizador:      ${CIANO}${DB_NAME}${RESET} / ${CIANO}${DB_USER}${RESET}"
        echo -e "  ${AMARELO}8)${RESET} Senha BD:             ${CIANO}$(mask_secret "$DB_PASS")${RESET}"
        echo -e "  ${AMARELO}9)${RESET} Zabbix Agent 2:       $([[ "$INSTALL_AGENT" == "1" ]] && echo -e "${VERDE}INSTALAR (${AG_HOSTNAME} | Zabbix ${ZBX_AGENT_VERSION})${RESET}" || echo "NÃO")"
        echo -e "  ${AMARELO}10)${RESET} PSK Agent:           $([[ "$USE_PSK" == "1" ]] && echo -e "${VERDE}ATIVO (${PSK_AGENT_ID})${RESET}" || echo "INATIVO")"
        echo -e "  ${AMARELO}11)${RESET} max_connections:     ${VERDE}${PG_MAX_CONN}${RESET}  ${AMARELO}← aumentar se usar uploads grandes no PHP${RESET}"
        echo -e "  ${AMARELO}12)${RESET} timescaledb-tune:    $([[ "$USE_TSDB_TUNE" == "1" ]] && echo -e "${VERDE}SIM (RAM/CPU automático)${RESET}" || echo "NÃO")"
        echo -e "  ${AMARELO}13)${RESET} Tuning PostgreSQL:   $([[ "$USE_TUNING" == "1" ]] && echo -e "${VERDE}SIM (shared_buffers: ${PG_SHARED_BUF})${RESET}" || echo "NÃO (padrão de fábrica)")"
        echo -e "  ${AMARELO}14)${RESET} Fuso Horário:        ${CIANO}${DB_TIMEZONE}${RESET}"
        echo -e "  ${AMARELO}15)${RESET} ${VERMELHO}Abortar Instalação${RESET}"
        echo -e "\n  ${VERDE}${NEGRITO}0) [ TUDO PRONTO - INICIAR INSTALAÇÃO ]${RESET}"
        echo -e "${CIANO}------------------------------------------------------------${RESET}"
        read -rp "Insira o número da secção a alterar ou 0 para executar: " rev_opt
        case $rev_opt in
            2) m_update ;; 3|4) m_versions ;; 5|6) m_zbxserver_ip ;; 7|8) m_dbcreds ;;
            9|10) m_agent ;; 11) m_max_connections ;; 12) m_tsdb_tune ;; 13) m_pgtuning ;;
            14) m_timezone ;;
            15) echo -e "${VERMELHO}Instalação abortada pelo utilizador.${RESET}"; exit 1 ;; 0) break ;;
        esac
    done

    # Pipeline
    confirm_execution_summary "DB"
    validate_compatibility_matrix "db"
    echo -e "\n${CIANO}${NEGRITO}A processar pipeline... Não cancele a operação!${RESET}\n"
    preflight_install_check "db" 4096 1024
    TOTAL_STEPS=20  # +1 para apt-mark hold
    [[ "$CLEAN_INSTALL" == "1" ]] && TOTAL_STEPS=$(( TOTAL_STEPS + 3 ))
    [[ "$UPDATE_SYSTEM" == "1" ]] && TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))
    [[ "$INSTALL_AGENT" == "1" ]] && TOTAL_STEPS=$(( TOTAL_STEPS + 9 ))
    [[ "$USE_PSK" == "1" && "$INSTALL_AGENT" == "1" ]] && TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))
    _IS_CONTAINER=0; systemd-detect-virt -c -q 2>/dev/null && _IS_CONTAINER=1 || true
    [[ "$_IS_CONTAINER" == "0" ]] && TOTAL_STEPS=$(( TOTAL_STEPS + 2 ))  # timedatectl + NTP
    [[ "$SIMULATE_MODE" == "1" ]] && echo -e "\n${CIANO}${NEGRITO}SIMULAÇÃO DO PIPELINE — BASE DE DADOS${RESET}\n"

    if [[ "$CLEAN_INSTALL" == "1" ]]; then
        safe_confirm_cleanup "Limpeza da camada DB" \
            "serviços postgresql e zabbix-agent2" \
            "pacotes PostgreSQL/TimescaleDB" \
            "/etc/postgresql /var/lib/postgresql /var/log/postgresql /run/postgresql"
        run_step "Parando serviços PostgreSQL e TimescaleDB" bash -c \
            "timeout 15 systemctl stop postgresql 2>/dev/null || \
             systemctl kill --kill-who=all postgresql 2>/dev/null || true; \
             systemctl disable postgresql 2>/dev/null || true; \
             timeout 15 systemctl stop zabbix-agent2 2>/dev/null || true; \
             systemctl disable zabbix-agent2 2>/dev/null || true; \
             pkill -9 -x postgres 2>/dev/null || true"
        run_step "Purge completo de PostgreSQL e TimescaleDB" bash -c \
            "dpkg -l 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^ii|^rc/ && \$2 ~ /(postgresql|timescaledb|zabbix-agent2)/ {print \$2}' | \
             xargs -r apt-mark unhold 2>/dev/null || true; \
             dpkg -l 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^ii|^rc/ && \$2 ~ /(postgresql|timescaledb)/ {print \$2}' | \
             xargs -r apt-get purge -y 2>/dev/null || true; apt-get autoremove -y 2>/dev/null || true"
        run_step "Remoção de dados e configurações anteriores" bash -c \
            "rm -rf /etc/postgresql /var/lib/postgresql /var/log/postgresql /run/postgresql 2>/dev/null || true; rm -f /tmp/zbx_repo.deb /etc/apt/sources.list.d/zabbix*.list /etc/apt/sources.list.d/zabbix*.sources /etc/apt/sources.list.d/pgdg.list /etc/apt/sources.list.d/timescaledb.list /etc/apt/trusted.gpg.d/timescaledb.gpg /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc 2>/dev/null || true"
    fi

    # Em containers LXC o relógio é gerido pelo host — tentar alterar causa erro fatal.
    # systemd-detect-virt -c retorna 0 (verdadeiro) se for qualquer container (LXC, Docker, etc).
    if ! systemd-detect-virt -c -q 2>/dev/null; then
        run_step "Ajustando relógio (${DB_TIMEZONE})" timedatectl set-timezone "${DB_TIMEZONE}"
        run_step "Ativando motor NTP" systemctl enable --now systemd-timesyncd
    else
        echo -e "\n  ${AMARELO}⚠ Ambiente de container (LXC) detectado. Pulando configuração de NTP (gerido pelo Host).${RESET}"
    fi
    run_step "Destravando processos do APT" auto_repair_apt
    run_step "Atualizando caches locais" apt-get update
    [[ "$SIMULATE_MODE" != "1" ]] && validate_packages_available \
        curl wget ca-certificates gnupg apt-transport-https lsb-release locales

    [[ "$INSTALL_AGENT" == "1" ]] && \
        run_step "Removendo instalação anterior do Zabbix Agent 2 da BD" bash -c \
            "timeout 15 systemctl stop zabbix-agent2 2>/dev/null || true; \
             systemctl disable zabbix-agent2 2>/dev/null || true; \
             pkill -9 -x zabbix_agent2 2>/dev/null || true; \
             apt-mark unhold zabbix-agent2 2>/dev/null || true; \
             apt-get purge -y zabbix-agent2 2>/dev/null || true; \
             rm -rf /etc/zabbix /var/lib/zabbix /var/log/zabbix /run/zabbix 2>/dev/null || true"

    [[ "$UPDATE_SYSTEM" == "1" ]] && \
        run_step "Realizando upgrade seguro dos pacotes do sistema" apt-get upgrade "${APT_FLAGS[@]}"

    run_step "Instalando dependências base" apt-get install "${APT_FLAGS[@]}" \
        curl wget ca-certificates gnupg apt-transport-https lsb-release locales

    run_step "Gerando locales en_US.UTF-8 e pt_BR.UTF-8" ensure_utf8_locales

    if [[ "$INSTALL_AGENT" == "1" ]]; then
        if [[ "$ZBX_AGENT_VERSION" == "7.4" ]]; then
            REPO_URL="$(zabbix_release_url "7.4")"
        else
            REPO_URL="$(zabbix_release_url "7.0")"
        fi
        ZBX_VERSION="$ZBX_AGENT_VERSION"
        run_step "Validando URL do repositório Zabbix ${ZBX_AGENT_VERSION} para Agent 2" check_zabbix_repo_url
        [[ "$SIMULATE_MODE" != "1" ]] && validate_official_zabbix_package zabbix-agent2 "$ZBX_AGENT_VERSION"
        run_step "Baixando repositório oficial Zabbix ${ZBX_AGENT_VERSION}" wget -q "$REPO_URL" -O /tmp/zbx_repo.deb
        run_step "Registando repositório Zabbix para Agent 2" dpkg --force-confmiss -i /tmp/zbx_repo.deb
        run_step "Sincronizando repositório Zabbix" apt-get update
        run_step "Verificando acesso ao repositório Zabbix ${ZBX_AGENT_VERSION}" verify_zabbix_repo_active zabbix-agent2
        run_step "Instalando Zabbix Agent 2" apt-get install "${APT_FLAGS[@]}" zabbix-agent2
    fi

    setup_pgdg_repo() {
        install -d /usr/share/postgresql-common/pgdg
        curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
            https://www.postgresql.org/media/keys/ACCC4CF8.asc
        echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
https://apt.postgresql.org/pub/repos/apt ${U_CODENAME}-pgdg main" \
            > /etc/apt/sources.list.d/pgdg.list
    }
    run_step "Adicionando repositório PGDG (PostgreSQL oficial)" setup_pgdg_repo

    # ------------------------------------------------------------------
    # Verifica se o repositório packagecloud tem pacotes para esta
    # versão do Ubuntu ANTES de tentar adicionar ou instalar.
    # Ubuntu 26.04 (resolute) pode ainda não ter pacotes publicados.
    # Se não estiver disponível, a instalação continua sem TimescaleDB
    # e o utilizador é avisado — sem abortar o script.
    # ------------------------------------------------------------------
    TSDB_AVAILABLE=1
    check_tsdb_repo_availability() {
        local tsdb_os
        tsdb_os="$(timescale_repo_os)"
        echo -e "\n  ${CIANO}Verificando disponibilidade do repositório TimescaleDB para ${OS_LABEL} ${U_VER} (${U_CODENAME})...${RESET}"
        if ! curl -fsL --max-time 15 \
            "https://packagecloud.io/timescale/timescaledb/${tsdb_os}/dists/${U_CODENAME}/Release" \
            >/dev/null 2>&1; then
            TSDB_AVAILABLE=0
            add_install_warning "TimescaleDB indisponível para ${OS_LABEL} ${U_VER} (${U_CODENAME}) com PostgreSQL ${PG_VER}; instalação continuará sem TimescaleDB."
            echo -e "\n  ${AMARELO}${NEGRITO}⚠ TimescaleDB indisponível para ${OS_LABEL} ${U_VER} (${U_CODENAME}).${RESET}"
            echo -e "  ${AMARELO}  O repositório packagecloud ainda não publicou pacotes para esta versão.${RESET}"
            echo -e "  ${AMARELO}  A instalação continuará SEM TimescaleDB.${RESET}"
            echo -e "  ${AMARELO}  Pode instalar manualmente quando os pacotes forem publicados:${RESET}"
            echo -e "  ${AMARELO}  https://packagecloud.io/timescale/timescaledb${RESET}"
        else
            echo -e "  ${VERDE}✔ Repositório TimescaleDB disponível para ${U_CODENAME}.${RESET}"
        fi
    }
    run_step "Verificando repositório TimescaleDB para ${OS_LABEL} ${U_VER}" check_tsdb_repo_availability

    if [[ "$TSDB_AVAILABLE" == "1" ]]; then
        setup_tsdb_repo() {
            # --batch --yes: evita prompt "File exists. Overwrite?" em reinstalações
            curl -fsSL https://packagecloud.io/timescale/timescaledb/gpgkey \
                | gpg --batch --yes --dearmor -o /etc/apt/trusted.gpg.d/timescaledb.gpg
            echo "deb https://packagecloud.io/timescale/timescaledb/$(timescale_repo_os)/ ${U_CODENAME} main" \
                > /etc/apt/sources.list.d/timescaledb.list
        }
        run_step "Adicionando repositório TimescaleDB" setup_tsdb_repo
    fi

    TSDB_REPO_LABEL=""
    [[ "$TSDB_AVAILABLE" == "1" ]] && TSDB_REPO_LABEL=" + TimescaleDB"
    run_step "Sincronizando repositórios PGDG${TSDB_REPO_LABEL}" apt-get update
    [[ "$SIMULATE_MODE" != "1" ]] && check_package_available "postgresql-${PG_VER}" "PostgreSQL ${PG_VER}"
    [[ "$SIMULATE_MODE" != "1" ]] && check_package_available "postgresql-client-${PG_VER}" "PostgreSQL Client ${PG_VER}" 1 || true

    if [[ "$SIMULATE_MODE" != "1" && "$TSDB_AVAILABLE" == "1" ]]; then
        draw_progress "Verificando disponibilidade do pacote TimescaleDB..."
        if ! apt-cache show "timescaledb-2-postgresql-${PG_VER}" >/dev/null 2>&1; then
            echo -e "\n\n  ${AMARELO}${NEGRITO}⚠ Pacote 'timescaledb-2-postgresql-${PG_VER}' não encontrado no repositório.${RESET}"
            [[ "$PG_VER" == "18" ]] && echo -e "  ${AMARELO}  PostgreSQL 18 + TimescaleDB pode ainda ser experimental.${RESET}"
            echo -e "  ${AMARELO}  Continuando instalação SEM TimescaleDB.${RESET}"
            add_install_warning "Pacote timescaledb-2-postgresql-${PG_VER} não encontrado; instalação continuará sem TimescaleDB."
            TSDB_AVAILABLE=0
        else
            echo -e "\r  ${VERDE}[██████████████████████████████████████████████████]${RESET} ${NEGRITO}100%${RESET}  ✔ Pacote TimescaleDB disponível              "
        fi
    fi

    run_step "Instalando PostgreSQL ${PG_VER}" \
        apt-get install "${APT_FLAGS[@]}" "postgresql-${PG_VER}"

    if [[ "$TSDB_AVAILABLE" == "1" ]]; then
        run_step "Instalando TimescaleDB para PostgreSQL ${PG_VER}" \
            apt-get install "${APT_FLAGS[@]}" "timescaledb-2-postgresql-${PG_VER}"
    fi

    ensure_postgres_cluster() {
        local detected cluster_conf cluster_hba cluster_list
        detected=""
        if command -v pg_lsclusters >/dev/null 2>&1; then
            cluster_list="$(timeout 10 pg_lsclusters --no-header 2>/dev/null || true)"
            detected="$(awk -v v="$PG_VER" '$1==v {print $2; exit}' <<<"$cluster_list" 2>/dev/null || true)"
        fi

        if [[ -z "$detected" ]]; then
            if ! command -v pg_createcluster >/dev/null 2>&1; then
                echo "Comando pg_createcluster não encontrado. Reinstale postgresql-common/postgresql-${PG_VER}." >&2
                return 1
            fi
            if [[ -d "/etc/postgresql/${PG_VER}/main" || -d "/var/lib/postgresql/${PG_VER}/main" ]]; then
                if [[ "$CLEAN_INSTALL" == "1" ]]; then
                    echo -e "  ${AMARELO}Restos de cluster PostgreSQL ${PG_VER}/main encontrados após limpeza; removendo para recriar.${RESET}"
                    rm -rf "/etc/postgresql/${PG_VER}/main" "/var/lib/postgresql/${PG_VER}/main" "/var/log/postgresql/postgresql-${PG_VER}-main.log"
                else
                    echo "Restos de cluster PostgreSQL ${PG_VER}/main encontrados, mas nenhum cluster válido foi listado por pg_lsclusters." >&2
                    echo "Para proteger dados existentes, o instalador não apagou esses diretórios sem confirmação de limpeza." >&2
                    echo "Rode novamente escolhendo instalação limpa/limpeza da camada DB para apagar e recriar tudo." >&2
                    return 1
                fi
            fi
            echo -e "  ${AMARELO}Cluster PostgreSQL ${PG_VER}/main não encontrado; criando cluster padrão.${RESET}"
            timeout 90 pg_createcluster --start "$PG_VER" main >/dev/null
            detected="main"
        fi

        PG_CLUSTER_NAME="$detected"
        PG_CONF_FILE="/etc/postgresql/${PG_VER}/${PG_CLUSTER_NAME}/postgresql.conf"
        PG_HBA_FILE="/etc/postgresql/${PG_VER}/${PG_CLUSTER_NAME}/pg_hba.conf"
        cluster_conf="$PG_CONF_FILE"
        cluster_hba="$PG_HBA_FILE"

        if [[ ! -f "$cluster_conf" || ! -f "$cluster_hba" ]]; then
            echo "Cluster PostgreSQL ${PG_VER}/${PG_CLUSTER_NAME} existe, mas os arquivos de configuração não foram encontrados:" >&2
            echo "  ${cluster_conf}" >&2
            echo "  ${cluster_hba}" >&2
            echo "Execute uma limpeza DB pelo instalador ou recrie o cluster PostgreSQL antes de continuar." >&2
            return 1
        fi

        if command -v pg_ctlcluster >/dev/null 2>&1; then
            timeout 30 pg_ctlcluster "$PG_VER" "$PG_CLUSTER_NAME" start 2>/dev/null || true
        fi
        timeout 20 systemctl start "postgresql@${PG_VER}-${PG_CLUSTER_NAME}" 2>/dev/null || \
            timeout 20 systemctl start postgresql 2>/dev/null || true

        echo -e "  ${VERDE}Cluster PostgreSQL ativo/validado: ${PG_VER}/${PG_CLUSTER_NAME}${RESET}"
        echo -e "  ${CIANO}Config:${RESET} ${PG_CONF_FILE}"
    }
    run_step "Validando/criando cluster PostgreSQL ${PG_VER}" ensure_postgres_cluster

    if [[ "$TSDB_AVAILABLE" == "0" ]]; then
        # Sem TimescaleDB — não adiciona shared_preload_libraries
        true
    else
        set_preload_manual() {
            local PG_CONF="${PG_CONF_FILE:-/etc/postgresql/${PG_VER}/${PG_CLUSTER_NAME}/postgresql.conf}"
            local lib="timescaledb"
            if [[ ! -f "$PG_CONF" ]]; then
                echo "Arquivo postgresql.conf não encontrado para TimescaleDB: ${PG_CONF}" >&2
                return 1
            fi
            if grep -qE "^[[:space:]]*shared_preload_libraries[[:space:]]*=.*${lib}" "$PG_CONF" 2>/dev/null; then
                return 0
            elif grep -qE "^[[:space:]]*shared_preload_libraries[[:space:]]*=" "$PG_CONF" 2>/dev/null; then
                sed -i "s|^[[:space:]]*shared_preload_libraries[[:space:]]*=\s*'\([^']*\)'|shared_preload_libraries = '\1,${lib}'|" "$PG_CONF"
            else
                sed -i "0,/^#[[:space:]]*shared_preload_libraries/{s|^#[[:space:]]*shared_preload_libraries.*|shared_preload_libraries = '${lib}'|}" "$PG_CONF" 2>/dev/null || \
                echo "shared_preload_libraries = '${lib}'" >> "$PG_CONF"
            fi
        }

        apply_safe_pg_tuning_for_container() {
            local PG_CONF="${PG_CONF_FILE:-/etc/postgresql/${PG_VER}/${PG_CLUSTER_NAME}/postgresql.conf}"
            local max_workers ts_workers parallel_workers
            if [[ ! -f "$PG_CONF" ]]; then
                echo "Arquivo postgresql.conf não encontrado para tuning seguro: ${PG_CONF}" >&2
                return 1
            fi
            calc_pg_auto_tuning
            max_workers=$(( CPU_CORES + 4 ))
            (( max_workers < 8 )) && max_workers=8
            (( max_workers > 16 )) && max_workers=16
            ts_workers="$CPU_CORES"
            (( ts_workers < 2 )) && ts_workers=2
            (( ts_workers > 8 )) && ts_workers=8
            parallel_workers="$CPU_CORES"
            (( parallel_workers < 2 )) && parallel_workers=2
            (( parallel_workers > 8 )) && parallel_workers=8

            set_pg_config "$PG_CONF" "shared_buffers" "$PG_SHARED_BUF"
            set_pg_config "$PG_CONF" "effective_cache_size" "$PG_EFF_CACHE"
            set_pg_config "$PG_CONF" "maintenance_work_mem" "$PG_MAINT_MEM"
            set_pg_config "$PG_CONF" "work_mem" "$PG_WORK_MEM"
            set_pg_config "$PG_CONF" "wal_buffers" "$PG_WAL_BUFS"
            set_pg_config "$PG_CONF" "max_worker_processes" "$max_workers"
            set_pg_config "$PG_CONF" "timescaledb.max_background_workers" "$ts_workers"
            set_pg_config "$PG_CONF" "max_parallel_workers" "$parallel_workers"
            set_pg_config "$PG_CONF" "max_parallel_workers_per_gather" "2"
            set_pg_config "$PG_CONF" "checkpoint_completion_target" "$PG_CKPT"
            set_pg_config "$PG_CONF" "default_statistics_target" "$PG_STATS"
            set_pg_config "$PG_CONF" "random_page_cost" "$PG_RAND_COST"
        }

        run_tsdb_tune() {
            TSDB_TUNE_STATUS="não executado"
            # Garante que o PostgreSQL está iniciado antes do tune
            timeout 20 systemctl start "postgresql@${PG_VER}-${PG_CLUSTER_NAME}" 2>/dev/null || \
                timeout 20 systemctl start postgresql 2>/dev/null || true
            if [[ "${_IS_CONTAINER:-0}" == "1" ]]; then
                TSDB_TUNE_STATUS="ignorado em container/LXC; tuning seguro aplicado pelo instalador"
                echo -e "  ${AMARELO}⚠ Ambiente de container/LXC detectado — ignorando timescaledb-tune para evitar RAM do host.${RESET}"
                set_preload_manual || true
                apply_safe_pg_tuning_for_container || true
                add_install_warning "timescaledb-tune ignorado em container/LXC; aplicado tuning seguro baseado na RAM detectada (${RAM_MB} MB)."
                return 0
            fi
            # Tenta timescaledb-tune. Se falhar por qualquer razão (ambiente,
            # restrições de recursos, etc.) aplica shared_preload_libraries
            # manualmente e continua sem abortar.
            if timeout 60 timescaledb-tune --pg-version "${PG_VER}" --quiet --yes 2>/dev/null; then
                TSDB_TUNE_STATUS="aplicado por timescaledb-tune"
                echo -e "  ${VERDE}timescaledb-tune aplicado com sucesso.${RESET}"
            else
                TSDB_TUNE_STATUS="fallback manual: shared_preload_libraries='timescaledb'"
                echo -e "  ${AMARELO}⚠ timescaledb-tune não disponível neste ambiente — aplicando shared_preload_libraries manualmente.${RESET}"
                set_preload_manual || true
                add_install_warning "timescaledb-tune falhou ou não respondeu; aplicado fallback manual shared_preload_libraries='timescaledb'."
            fi
            return 0
        }

        if [[ "$USE_TSDB_TUNE" == "1" ]]; then
            run_step "Executando timescaledb-tune (otimização baseada na RAM/CPU)" run_tsdb_tune
        else
            run_step "Configurando shared_preload_libraries = 'timescaledb'" set_preload_manual
        fi
        if [[ "${_IS_CONTAINER:-0}" == "1" ]]; then
            echo -e "  ${CIANO}Normalizando tuning PostgreSQL para limites do container/LXC (${RAM_MB} MB RAM).${RESET}"
            apply_safe_pg_tuning_for_container || true
        fi
    fi

    configure_postgres() {
        local PG_CONF="${PG_CONF_FILE:-/etc/postgresql/${PG_VER}/${PG_CLUSTER_NAME}/postgresql.conf}"
        set_pg_config "$PG_CONF" "listen_addresses" "$PG_LISTEN_ADDR"
        set_pg_config "$PG_CONF" "timezone" "'${DB_TIMEZONE}'"
        # max_connections é sempre aplicado — configurado como questão independente
        set_pg_config "$PG_CONF" "max_connections" "$PG_MAX_CONN"
        if [[ "$USE_TUNING" == "1" ]]; then
            set_pg_config "$PG_CONF" "shared_buffers"                "$PG_SHARED_BUF"
            set_pg_config "$PG_CONF" "work_mem"                      "$PG_WORK_MEM"
            set_pg_config "$PG_CONF" "maintenance_work_mem"          "$PG_MAINT_MEM"
            set_pg_config "$PG_CONF" "effective_cache_size"          "$PG_EFF_CACHE"
            set_pg_config "$PG_CONF" "wal_buffers"                   "$PG_WAL_BUFS"
            set_pg_config "$PG_CONF" "checkpoint_completion_target"  "$PG_CKPT"
            set_pg_config "$PG_CONF" "default_statistics_target"     "$PG_STATS"
            set_pg_config "$PG_CONF" "random_page_cost"              "$PG_RAND_COST"
        fi
    }
    run_step "Configurando postgresql.conf (listen_addresses + tuning)" configure_postgres

    configure_pg_hba() {
        local PG_HBA="${PG_HBA_FILE:-/etc/postgresql/${PG_VER}/${PG_CLUSTER_NAME}/pg_hba.conf}"
        if [[ ! -f "$PG_HBA" ]]; then
            echo "Arquivo pg_hba.conf não encontrado: ${PG_HBA}" >&2
            return 1
        fi
        sed -i "/^host[[:space:]]\+${DB_NAME}[[:space:]]\+${DB_USER}/d" "$PG_HBA" 2>/dev/null || true
        for entry in "${ZBX_SERVER_IPS[@]}"; do
            if [[ "$entry" == "0.0.0.0" || "$entry" == "0.0.0.0/0" ]]; then
                echo "host    ${DB_NAME}    ${DB_USER}    0.0.0.0/0               scram-sha-256" >> "$PG_HBA"
                echo "host    ${DB_NAME}    ${DB_USER}    ::0/0                   scram-sha-256" >> "$PG_HBA"
            elif [[ "$entry" =~ / ]]; then
                echo "host    ${DB_NAME}    ${DB_USER}    ${entry}    scram-sha-256" >> "$PG_HBA"
            else
                echo "host    ${DB_NAME}    ${DB_USER}    ${entry}/32             scram-sha-256" >> "$PG_HBA"
            fi
        done
    }
    run_step "Configurando pg_hba.conf (acesso remoto para ${#ZBX_SERVER_IPS[@]} entrada(s))" configure_pg_hba
    restart_postgres_cluster() {
        if command -v pg_ctlcluster >/dev/null 2>&1; then
            timeout 45 pg_ctlcluster "$PG_VER" "$PG_CLUSTER_NAME" restart
        else
            timeout 45 systemctl restart "postgresql@${PG_VER}-${PG_CLUSTER_NAME}" 2>/dev/null || \
                timeout 45 systemctl restart postgresql
        fi
    }
    wait_for_postgres_ready() {
        local timeout_s="${1:-30}" waited=0 cluster_service="postgresql@${PG_VER}-${PG_CLUSTER_NAME}"
        log_msg "INFO" "Aguardando PostgreSQL ${PG_VER}/${PG_CLUSTER_NAME} responder por até ${timeout_s}s"
        while (( waited < timeout_s )); do
            if command -v pg_isready >/dev/null 2>&1 && timeout 5 pg_isready -q -h /var/run/postgresql -p 5432 2>/dev/null; then
                echo -e "  ${VERDE}✔${RESET} PostgreSQL ${PG_VER}/${PG_CLUSTER_NAME}: pronto após ${waited}s"
                log_msg "OK" "PostgreSQL ${PG_VER}/${PG_CLUSTER_NAME} pronto após ${waited}s"
                return 0
            fi
            if systemctl is-active --quiet "$cluster_service" 2>/dev/null || systemctl is-active --quiet postgresql 2>/dev/null; then
                echo -e "  ${VERDE}✔${RESET} PostgreSQL ${PG_VER}/${PG_CLUSTER_NAME}: serviço ativo após ${waited}s"
                log_msg "OK" "PostgreSQL ${PG_VER}/${PG_CLUSTER_NAME} serviço ativo após ${waited}s"
                return 0
            fi
            sleep 2
            waited=$(( waited + 2 ))
        done
        echo -e "\n${VERMELHO}${NEGRITO}ERRO:${RESET} PostgreSQL ${PG_VER}/${PG_CLUSTER_NAME} não ficou pronto em ${timeout_s}s."
        echo -e "  Diagnóstico sugerido: journalctl -u ${cluster_service} -n 80 --no-pager"
        log_msg "ERROR" "PostgreSQL ${PG_VER}/${PG_CLUSTER_NAME} não ficou pronto em ${timeout_s}s"
        print_service_journal_tail "$cluster_service" 30
        print_service_journal_tail postgresql 30
        return 1
    }
    run_step "Reiniciando PostgreSQL ${PG_VER}/${PG_CLUSTER_NAME}" restart_postgres_cluster
    wait_for_postgres_ready 30

    create_db_and_user() {
        validate_identifier "$DB_USER" "Nome do utilizador da BD"
        validate_identifier "$DB_NAME" "Nome da base de dados"
        local DB_PASS_SQL DB_USER_IDENT DB_NAME_IDENT
        DB_PASS_SQL=$(sql_quote_literal "$DB_PASS")
        DB_USER_IDENT=$(sql_quote_ident "$DB_USER")
        DB_NAME_IDENT=$(sql_quote_ident "$DB_NAME")
        postgres_psql_timeout 45 -tc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" \
            | awk '$1==1{found=1} END{exit !found}' 2>/dev/null || \
            postgres_psql_timeout 45 -c "CREATE USER ${DB_USER_IDENT} WITH PASSWORD ${DB_PASS_SQL};"
        postgres_psql_timeout 45 -c "ALTER USER ${DB_USER_IDENT} WITH PASSWORD ${DB_PASS_SQL};"
        postgres_psql_timeout 45 -tc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" \
            | awk '$1==1{found=1} END{exit !found}' 2>/dev/null || \
            postgres_psql_timeout 45 -c "CREATE DATABASE ${DB_NAME_IDENT} OWNER ${DB_USER_IDENT} ENCODING 'UTF8' \
                LC_COLLATE='en_US.UTF-8' LC_CTYPE='en_US.UTF-8' TEMPLATE template0;"
        postgres_psql_timeout 45 -c "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME_IDENT} TO ${DB_USER_IDENT};"
        postgres_psql_timeout 45 -d "${DB_NAME}" -c "GRANT ALL ON SCHEMA public TO ${DB_USER_IDENT};"
        postgres_psql_timeout 45 -d "${DB_NAME}" -c "ALTER SCHEMA public OWNER TO ${DB_USER_IDENT};"
        postgres_psql_timeout 45 -d "${DB_NAME}" -c \
            "ALTER DATABASE ${DB_NAME_IDENT} SET timezone TO '${DB_TIMEZONE}';"
    }
    run_step "Criando utilizador '${DB_USER}' e base de dados '${DB_NAME}'" create_db_and_user

    if [[ "$TSDB_AVAILABLE" == "1" ]]; then
        enable_timescaledb() {
            local DB_NAME_IDENT
            DB_NAME_IDENT=$(sql_quote_ident "$DB_NAME")
            postgres_psql_timeout 45 -d "${DB_NAME}" -c \
                "ALTER DATABASE ${DB_NAME_IDENT} SET timescaledb.telemetry_level=off;"
            postgres_psql_timeout 45 -d "${DB_NAME}" -c \
                "CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;"
        }
        run_step "Ativando extensão TimescaleDB na BD '${DB_NAME}'" enable_timescaledb
    else
        echo -e "\n  ${AMARELO}ℹ TimescaleDB não instalado — extensão ignorada.${RESET}"
    fi
    run_step "Reiniciando PostgreSQL ${PG_VER}/${PG_CLUSTER_NAME} (configuração final)" restart_postgres_cluster
    wait_for_postgres_ready 30

    AG_F="/etc/zabbix/zabbix_agent2.conf"
    if [[ "$INSTALL_AGENT" == "1" && ( -f "$AG_F" || "$SIMULATE_MODE" == "1" ) ]]; then
        apply_db_agent_config() {
            set_config "$AG_F" "Server"       "$AG_SERVER"
            set_config "$AG_F" "ServerActive" "$AG_SERVER_ACTIVE"
            set_config "$AG_F" "Hostname"     "$AG_HOSTNAME"
            [[ "$AG_ALLOWKEY" == "1" ]] && set_config "$AG_F" "AllowKey" "system.run[*]"
        }
        run_step "Configurando Zabbix Agent 2 da BD" apply_db_agent_config
    fi

    if [[ "$USE_PSK" == "1" && "$INSTALL_AGENT" == "1" ]]; then
        if [[ "$SIMULATE_MODE" == "1" ]]; then
            PSK_AGENT_KEY="<gerado-na-instalação-real>"
        else
            PSK_AGENT_KEY=$(openssl rand -hex 32)
        fi
        apply_db_agent_psk() {
            echo "$PSK_AGENT_KEY" > /etc/zabbix/zabbix_agent2.psk
            chown zabbix:zabbix /etc/zabbix/zabbix_agent2.psk
            chmod 600 /etc/zabbix/zabbix_agent2.psk
            set_config "$AG_F" "TLSAccept"      "psk"
            set_config "$AG_F" "TLSConnect"     "psk"
            set_config "$AG_F" "TLSPSKIdentity" "$PSK_AGENT_ID"
            set_config "$AG_F" "TLSPSKFile"     "/etc/zabbix/zabbix_agent2.psk"
        }
        run_step "Gerando e aplicando chave PSK do Agent 2 da BD" apply_db_agent_psk
    fi

    if [[ "$INSTALL_AGENT" == "1" ]]; then
        run_step "Ativando Zabbix Agent 2 da BD" systemctl enable --now zabbix-agent2
        wait_for_service_active zabbix-agent2 30
    fi

    hold_packages_db() {
        # Fixa versões para evitar atualização acidental via apt upgrade
        apt-mark hold "postgresql-${PG_VER}" 2>/dev/null || true
        [[ "$TSDB_AVAILABLE" == "1" ]] && apt-mark hold "timescaledb-2-postgresql-${PG_VER}" 2>/dev/null || true
        [[ "$INSTALL_AGENT" == "1" ]] && apt-mark hold zabbix-agent2 2>/dev/null || true
        echo -e "  ${VERDE}Versões fixadas. Use 'apt-mark unhold <pacote>' antes de atualizar manualmente.${RESET}"
    }
    run_step "Fixando versões instaladas (apt-mark hold)" hold_packages_db

    [[ "$SIMULATE_MODE" == "1" ]] && finish_simulation
    post_validate_installation "db"
    if [[ "$_CRITICAL_SERVICES_OK" == "1" ]]; then
        CURRENT_STEP=$TOTAL_STEPS; draw_progress "Instalação Perfeita! ✔"; printf "\n"
    else
        CURRENT_STEP=$TOTAL_STEPS; draw_progress "Instalação com Avisos ⚠"; printf "\n"
    fi

    # Certificado
    clear
    start_certificate_export "db"
    [[ "$_CRITICAL_SERVICES_OK" != "1" ]] && \
        echo -e "${VERMELHO}${NEGRITO}⚠ UM OU MAIS SERVIÇOS CRÍTICOS NÃO ESTÃO ATIVOS. Verifique acima e execute: journalctl -xe --no-pager${RESET}\n"
    HOST_IP=$(hostname -I | awk '{print $1}')
    PG_CONF="${PG_CONF_FILE:-/etc/postgresql/${PG_VER}/${PG_CLUSTER_NAME}/postgresql.conf}"
    PG_HBA="${PG_HBA_FILE:-/etc/postgresql/${PG_VER}/${PG_CLUSTER_NAME}/pg_hba.conf}"
    echo -e "${VERDE}${NEGRITO}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${VERDE}${NEGRITO}║           CERTIFICADO — CAMADA DE BASE DE DADOS          ║${RESET}"
    echo -e "${VERDE}${NEGRITO}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo -e "\n${CIANO}${NEGRITO}▸ SISTEMA OPERACIONAL + HARDWARE${RESET}"
    command -v lsb_release >/dev/null 2>&1 && \
        printf "  %-34s %s\n" "Distribuição:" "$(lsb_release -ds)" || \
        printf "  %-34s %s\n" "Sistema:" "$OS_DISPLAY"
    printf "  %-34s %s\n" "Kernel:" "$(uname -r)"
    printf "  %-34s %s\n" "RAM total:" "${RAM_MB} MB"
    printf "  %-34s %s\n" "Núcleos CPU:" "${CPU_CORES}"
    echo -e "\n${CIANO}${NEGRITO}▸ REDE DO HOST${RESET}"
    printf "  %-34s %s\n" "IP desta máquina (BD):" "$HOST_IP"
    printf "  %-34s %s\n" "IPs autorizados (pg_hba.conf):" "$(IFS=', '; echo "${ZBX_SERVER_IPS[*]}")"
    printf "  %-34s %s\n" "Porta PostgreSQL (TCP):" "5432"
    echo -e "\n${CIANO}${NEGRITO}▸ ESTADO DOS SERVIÇOS${RESET}"
    PG_SVC_NAME="postgresql"
    ! systemctl is-active --quiet postgresql 2>/dev/null && PG_SVC_NAME="postgresql@${PG_VER}-main"
    if systemctl is-active --quiet "$PG_SVC_NAME" 2>/dev/null; then
        PG_BIN_VER_OUT=$(postgres_psql_timeout 10 --version 2>/dev/null | head -1 || echo "")
        printf "  %-34s ${VERDE}%s${RESET}\n" "postgresql:" "ATIVO ✔${PG_BIN_VER_OUT:+  ($PG_BIN_VER_OUT)}"
    else
        printf "  %-34s ${VERMELHO}%s${RESET}\n" "postgresql:" "FALHOU ✖"
    fi
    if [[ "$INSTALL_AGENT" == "1" ]]; then
        systemctl is-active --quiet zabbix-agent2 2>/dev/null && \
            printf "  %-34s ${VERDE}%s${RESET}\n" "zabbix-agent2:" "ATIVO ✔" || \
            printf "  %-34s ${VERMELHO}%s${RESET}\n" "zabbix-agent2:" "FALHOU ✖"
    fi
    echo -e "\n${CIANO}${NEGRITO}▸ VERSÕES DOS PACOTES INSTALADOS${RESET}"
    PG_PKG_VER=$(dpkg -l "postgresql-${PG_VER}" 2>/dev/null | awk '/^ii/{print $3}' | head -1 || echo "N/D")
    TSDB_PKG_VER=$(dpkg -l "timescaledb-2-postgresql-${PG_VER}" 2>/dev/null | awk '/^ii/{print $3}' | head -1 || echo "N/D")
    TSDB_EXT_VER=$(postgres_psql_timeout 45 -d "${DB_NAME}" -tAc \
        "SELECT extversion FROM pg_extension WHERE extname='timescaledb';" 2>/dev/null | xargs || echo "N/D")
    printf "  %-34s %s\n" "postgresql-${PG_VER} (pacote):" "${PG_PKG_VER}"
    printf "  %-34s %s\n" "timescaledb-2-postgresql-${PG_VER}:" "${TSDB_PKG_VER}"
    printf "  %-34s %s\n" "TimescaleDB (extensão na BD):" "${TSDB_EXT_VER}"
    printf "  %-34s %s\n" "timescaledb-tune:" "${TSDB_TUNE_STATUS:-não executado}"
    [[ "$INSTALL_AGENT" == "1" ]] && printf "  %-34s %s\n" "zabbix-agent2:" "$(dpkg -l zabbix-agent2 2>/dev/null | awk '/^ii/{print $3}' | head -1 || echo N/D)"
    echo -e "\n${CIANO}${NEGRITO}▸ PARÂMETROS postgresql.conf CONFIRMADOS${RESET}"
    if [[ -f "$PG_CONF" ]]; then
        conf_val() { timeout 10 awk -v k="$1" '$0 ~ "^[[:space:]]*" k "[[:space:]]*=" {val=$0; sub(/.*=[[:space:]]*/, "", val); sub(/[[:space:]]*#.*/, "", val); last=val} END{gsub(/^[[:space:]]+|[[:space:]]+$/, "", last); print last}' "$PG_CONF" 2>/dev/null || true; }
        printf "  %-34s %s\n" "listen_addresses (esta máquina):" "$(conf_val listen_addresses)"
        printf "  %-34s %s\n" "shared_buffers:" "$(conf_val shared_buffers)"
        printf "  %-34s %s\n" "max_connections:" "$(conf_val max_connections)"
        printf "  %-34s %s\n" "effective_cache_size:" "$(conf_val effective_cache_size)"
        printf "  %-34s %s\n" "work_mem:" "$(conf_val work_mem)"
        printf "  %-34s %s\n" "shared_preload_libraries:" "$(conf_val shared_preload_libraries)"
    fi
    echo -e "\n${CIANO}${NEGRITO}▸ ENTRADAS pg_hba.conf (zabbix)${RESET}"
    [[ -f "$PG_HBA" ]] && timeout 10 awk -v db="$DB_NAME" '$0 !~ /^[[:space:]]*#/ && $0 ~ ("[[:space:]]" db "[[:space:]]") { print "  " $0 }' "$PG_HBA" 2>/dev/null || true
    echo -e "\n${AMARELO}${NEGRITO}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${AMARELO}${NEGRITO}║     CREDENCIAIS PARA O SCRIPT AUTOMACAO-ZBX-SERVER       ║${RESET}"
    echo -e "${AMARELO}${NEGRITO}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo -e "  ------------------------------------------------------------"
    printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "IP desta máquina (DB Host):" "$HOST_IP"
    printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "Porta DB:"                  "5432"
    printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "Nome da Base de Dados:"     "$DB_NAME"
    printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "Utilizador:"                "$DB_USER"
    printf "  ${NEGRITO}%-32s${RESET} ${VERMELHO}%s${RESET}\n" "Senha:"                  "$DB_PASS"
    printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "DBUser:"                    "$DB_USER"
    printf "  ${NEGRITO}%-32s${RESET} ${VERMELHO}%s${RESET}\n" "DBPassword:"                "$DB_PASS"
    printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "PostgreSQL versão:"         "$PG_VER"
    if [[ "$TSDB_AVAILABLE" == "1" ]]; then
        printf "  ${NEGRITO}%-32s${RESET} ${VERDE}%s${RESET}\n" "TimescaleDB:"               "INSTALADO ✔  (importar timescaledb.sql no Server)"
    else
        printf "  ${NEGRITO}%-32s${RESET} ${AMARELO}%s${RESET}\n" "TimescaleDB:"               "NÃO INSTALADO — repositório/pacote indisponível"
    fi
    echo -e "  ------------------------------------------------------------"
    if [[ "$INSTALL_AGENT" == "1" ]]; then
        echo -e "\n${AMARELO}${NEGRITO}▸ CREDENCIAIS PARA CADASTRAR O AGENT 2 DA BD${RESET}"
        echo -e "  ------------------------------------------------------------"
        printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "IP desta máquina:"      "$HOST_IP"
        printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "Hostname Agente:"       "$AG_HOSTNAME"
        printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "Server:"                "$AG_SERVER"
        printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "ServerActive:"          "$AG_SERVER_ACTIVE"
        printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "Versão repo Zabbix:"    "$ZBX_AGENT_VERSION"
        if [[ "$USE_PSK" == "1" ]]; then
            printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "PSK Identity:"          "$PSK_AGENT_ID"
            printf "  ${NEGRITO}%-32s${RESET} ${VERMELHO}%s${RESET}\n" "PSK Secret Key:"        "$PSK_AGENT_KEY"
        fi
        echo -e "  ------------------------------------------------------------"
    fi
    print_install_warnings
    echo -e "\n${CIANO}${NEGRITO}▸ EXPORTAÇÃO JSON${RESET}"
    write_install_summary_json "db"
    print_support_commands "db"
    echo -e "\n${NEGRITO}Log completo:${RESET} $LOG_FILE\n"
    ;;


# ══════════════════════════════════════════════════════════════════════════════
# COMPONENTE 2 — SERVIDOR (Zabbix Server + Frontend + Nginx) — Server v1.7
# ══════════════════════════════════════════════════════════════════════════════
server)
    component_supported_or_die "server"

    set_default_php_for_os() {
        if [[ "$OS_FAMILY" == "debian" ]]; then
            case "$U_VER" in
                "12") PHP_VER="8.2"; NEED_PHP_PPA=0 ;;
                "13") PHP_VER="8.4"; NEED_PHP_PPA=0 ;;
                *)    PHP_VER="8.2"; NEED_PHP_PPA=0 ;;
            esac
        else
            case "$U_VER" in
                "20.04") PHP_VER="8.1"; NEED_PHP_PPA=1 ;;
                "22.04") PHP_VER="8.1"; NEED_PHP_PPA=0 ;;
                "24.04") PHP_VER="8.3"; NEED_PHP_PPA=0 ;;
                "26.04") PHP_VER="8.5"; NEED_PHP_PPA=0 ;;
                *)       PHP_VER="8.1"; NEED_PHP_PPA=0 ;;
            esac
        fi
    }
    set_default_php_for_os

    # Zabbix 8.0 exige PHP >= 8.2. Em Ubuntu antigo usa PPA; Debian usa PHP nativo.
    # Esta validação é feita após o utilizador selecionar a versão no questionário,
    # mas o ZBX_VERSION ainda não foi definido aqui, por isso a verificação real
    # ocorre também no bloco de instalação (ver função check_zbx8_php_compat abaixo).
    check_zbx8_php_compat() {
        if [[ "$ZBX_VERSION" == "8.0" ]]; then
            # Converte "8.1" → 81, "8.2" → 82, etc. para comparação numérica
            local php_num="${PHP_VER//./}"
            if (( php_num < 82 )); then
                echo -e "\n${AMARELO}${NEGRITO}⚠ Zabbix 8.0 requer PHP 8.2+.${RESET}"
                if [[ "$OS_FAMILY" == "ubuntu" ]]; then
                    echo -e "  Ubuntu ${U_VER} tem PHP ${PHP_VER} nativo — será instalado PPA ondrej/php com PHP 8.2."
                    PHP_VER="8.2"
                    NEED_PHP_PPA=1
                else
                    echo -e "  ${OS_DISPLAY} não tem PHP compatível definido para Zabbix 8.0 neste instalador."
                    exit 1
                fi
            fi
        fi
    }

    if [[ "$SIMULATE_MODE" == "1" ]]; then
        LOG_FILE=""
    else
        init_install_log "server" "/var/log/zabbix_server_install_$(date +%Y%m%d_%H%M%S).log"
    fi
    log_msg "INFO" "Log iniciado para componente Server em ${LOG_FILE}"

    # Variáveis de estado
    ZBX_VERSION="7.0"; PG_VER="17"
    DB_HOST=""; DB_PORT="5432"; DB_NAME="zabbix"; DB_USER="zabbix"; DB_PASS=""
    USE_TIMESCALE="0"
    ZBX_DB_DETECTED=""          # valor 'mandatory' da tabela dbversion (vazio = BD sem schema Zabbix)
    USE_HTTPS="0"; SSL_TYPE="self-signed"
    SSL_CERT="/etc/ssl/zabbix/zabbix.crt"; SSL_KEY="/etc/ssl/zabbix/zabbix.key"
    USE_HTTP_REDIRECT="0"
    NGINX_PORT="80"; SERVER_NAME="_"; TIMEZONE="${SYS_TIMEZONE:-America/Sao_Paulo}"
    INSTALL_AGENT="0"; USE_PSK="0"; PSK_AGENT_ID=""; PSK_AGENT_KEY=""
    AG_SERVER="127.0.0.1"; AG_SERVER_ACTIVE="127.0.0.1"
    AG_HOSTNAME=""; AG_ALLOWKEY="0"; ENABLE_REMOTE="0"
    USE_TUNING="0"; UPDATE_SYSTEM="0"; CLEAN_INSTALL=0
    PHP_UPLOAD_SIZE="32M"
    T_CACHE="256M"; T_HCACHE="128M"; T_HICACHE="32M"; T_VCACHE="256M"; T_TRCACHE="32M"
    T_POLL="20"; T_PUNREACH="5"; T_TRAP="10"; T_PREPROC="16"; T_DBSYNC="4"
    T_PING="5"; T_DISC="5"; T_HTTP="5"; T_APOLL="1"; T_HAPOLL="1"
    T_SPOLL="10"; T_BPOLL="1"; T_ODBCPOLL="1"; T_MAXC="1000"; T_UNREACH="45"
    T_TOUT="5"; T_HK="1"; T_SLOWQ="3000"

    clamp_int() {
        local value="$1" min="$2" max="$3"
        (( value < min )) && value="$min"
        (( value > max )) && value="$max"
        echo "$value"
    }

    calc_server_auto_performance() {
        if (( RAM_MB < 4096 )); then
            SERVER_PERF_PROFILE="mínimo"
            T_CACHE="64M";  T_VCACHE="64M";  T_HCACHE="64M";  T_TRCACHE="16M"; T_DBSYNC="2"
            T_POLL=$(clamp_int $(( CPU_CORES * 2 )) 4 8)
            T_PREPROC=$(clamp_int $(( CPU_CORES * 1 )) 2 4)
        elif (( RAM_MB < 8192 )); then
            SERVER_PERF_PROFILE="baixo"
            T_CACHE="128M"; T_VCACHE="128M"; T_HCACHE="128M"; T_TRCACHE="32M"; T_DBSYNC="2"
            T_POLL=$(clamp_int $(( CPU_CORES * 4 )) 8 12)
            T_PREPROC=$(clamp_int $(( CPU_CORES * 2 )) 4 8)
        elif (( RAM_MB <= 16384 )); then
            SERVER_PERF_PROFILE="médio"
            T_CACHE="256M"; T_VCACHE="256M"; T_HCACHE="256M"; T_TRCACHE="64M"; T_DBSYNC="4"
            T_POLL=$(clamp_int $(( CPU_CORES * 5 )) 16 30)
            T_PREPROC=$(clamp_int $(( CPU_CORES * 3 )) 12 24)
        else
            SERVER_PERF_PROFILE="alto"
            T_CACHE="512M"; T_VCACHE="512M"; T_HCACHE="512M"; T_TRCACHE="128M"; T_DBSYNC="8"
            T_POLL=$(clamp_int $(( CPU_CORES * 6 )) 30 60)
            T_PREPROC=$(clamp_int $(( CPU_CORES * 4 )) 24 48)
        fi
    }
    calc_server_auto_performance

    # Banner Server
    clear
    echo -e "${VERMELHO}${NEGRITO}"
    cat << "EOF"
 ██████╗███████╗██████╗ ██╗   ██╗███████╗██████╗
██╔════╝██╔════╝██╔══██╗██║   ██║██╔════╝██╔══██╗
╚█████╗ █████╗  ██████╔╝╚██╗ ██╔╝█████╗  ██████╔╝
 ╚═══██╗██╔══╝  ██╔══██╗ ╚████╔╝ ██╔══╝  ██╔══██╗
██████╔╝███████╗██║  ██║  ╚██╔╝  ███████╗██║  ██║
╚═════╝ ╚══════╝╚═╝  ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝
EOF
    echo -e "        & FRONTEND + NGINX — Instalador Enterprise v2.3${RESET}"
    echo -e "        ${VERDE}Sistema detetado: ${OS_DISPLAY} | PHP ${PHP_VER} ✔${RESET}"
    echo -e "        ${CIANO}Hardware: ${RAM_MB} MB RAM | ${CPU_CORES} núcleos | Perfil de performance: ${NEGRITO}${SERVER_PERF_PROFILE}${RESET}\n"

    # Questionário
    m_clean() {
        local Z_LIST
        Z_LIST=$(dpkg -l 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^ii|^rc/ && $2 ~ /(zabbix|nginx)/ {print $2}' || true)
        if [[ -n "$Z_LIST" ]]; then
            echo -e "\n${VERMELHO}${NEGRITO}⚠  Instalação anterior detetada:${RESET}"
            echo -e "${VERMELHO}   $(echo "$Z_LIST" | tr '\n' ' ')${RESET}"
            echo -e "${AMARELO}   Será removida completamente antes de instalar.${RESET}"
            CLEAN_INSTALL=1
        else
            CLEAN_INSTALL=0
        fi
    }

    m_update() {
        echo -e "\n${CIANO}${NEGRITO}>>> ATUALIZAÇÃO E DEPENDÊNCIAS DO SISTEMA <<<${RESET}"
        echo -e "  Recomenda-se atualizar o SO e instalar pacotes auxiliares (snmp, fping, nmap, jq)."
        ask_yes_no "Fazer upgrade seguro dos pacotes e instalar ferramentas de rede?" UPDATE_SYSTEM
    }

    m_version() {
        echo -e "\n${CIANO}${NEGRITO}>>> VERSÃO DO ZABBIX <<<${RESET}"
        echo -e "   1) ${NEGRITO}7.0 LTS${RESET}     — Suporte Longo Prazo (recomendado para produção estável)"
        echo -e "   2) ${NEGRITO}7.4 Current${RESET}  — Versão actual com funcionalidades avançadas"
        echo -e "   3) ${NEGRITO}8.0 LTS${RESET}     — Nova versão LTS (quando publicada para este sistema)"
        echo -e "   ${AMARELO}Nota:${RESET} Zabbix 8.0 requer PHP 8.2+ e PostgreSQL 15+."
        while true; do
            read -rp "   Escolha (1, 2 ou 3): " v_opt
            case "$v_opt" in
                1) ZBX_VERSION="7.0"; break ;;
                2) ZBX_VERSION="7.4"; break ;;
                3) ZBX_VERSION="8.0"; break ;;
                *) echo -e "   ${VERMELHO}Opção inválida.${RESET}" ;;
            esac
        done
        # Repõe PHP_VER e NEED_PHP_PPA aos valores padrão do SO antes de aplicar
        # a regra do Zabbix 8.0 — evita que uma seleção anterior de 8.0 fique
        # "presa" se o utilizador voltar a escolher 7.0 ou 7.4 no menu de revisão.
        set_default_php_for_os
        # Valida compatibilidade PHP após versão escolhida (pode sobrescrever acima se ZBX 8.0)
        check_zbx8_php_compat
    }

    # ---------------------------------------------------------------------------
    # Exibe tabela de compatibilidade após a deteção automática.
    #   $1 — versão TSDB detetada (vazio = não instalado)
    #   $2 — valor 'mandatory' da tabela dbversion (vazio = BD sem schema Zabbix)
    # ---------------------------------------------------------------------------
    # ---------------------------------------------------------------------------
    # Exibe tabela de compatibilidade e retorna um código de ação:
    #   0 — tudo compatível (ou sem schema existente)
    #   1 — utilizador alterou versão Zabbix → re-verificar compatibilidade
    #   2 — utilizador quer re-inserir dados de conexão à BD
    #   3 — utilizador optou por continuar mesmo com incompatibilidade
    # ---------------------------------------------------------------------------
    _show_compat_table() {
        local _tsdb_ver="${1:-}"
        local _zbx_dbver="${2:-}"

        echo -e "\n${CIANO}${NEGRITO}┌─────────────────────────────────────────────────────────────┐${RESET}"
        echo -e "${CIANO}${NEGRITO}│          COMPATIBILIDADE DA BASE DE DADOS DETETADA          │${RESET}"
        echo -e "${CIANO}${NEGRITO}└─────────────────────────────────────────────────────────────┘${RESET}"
        printf "  ${NEGRITO}%-26s %-18s %s${RESET}\n" "Componente" "Detetado" "Estado (Zabbix ${ZBX_VERSION})"
        echo -e "  ─────────────────────────────────────────────────────────────"

        # — PostgreSQL —
        local _pg_status="${VERDE}✔ Compatível${RESET}"
        if [[ "$ZBX_VERSION" == "8.0" && "$PG_VER" -lt 15 ]]; then
            _pg_status="${VERMELHO}✖ Requer PostgreSQL 15+${RESET}"
        elif [[ "$PG_VER" -lt 13 ]]; then
            _pg_status="${VERMELHO}✖ Requer PostgreSQL 13+${RESET}"
        fi
        printf "  %-26s ${VERDE}%-18s${RESET} " "PostgreSQL" "${PG_VER}"
        echo -e "${_pg_status}"

        # — TimescaleDB —
        if [[ -n "$_tsdb_ver" ]]; then
            local _tsdb_status="${VERDE}✔ Compatível${RESET}"
            local _tsdb_major; _tsdb_major=$(echo "$_tsdb_ver" | cut -d. -f1)
            if [[ "$ZBX_VERSION" == "8.0" && "${_tsdb_major:-0}" -lt 2 ]]; then
                _tsdb_status="${VERMELHO}✖ Requer TimescaleDB 2.x+${RESET}"
            fi
            printf "  %-26s ${VERDE}%-18s${RESET} " "TimescaleDB" "${_tsdb_ver}"
            echo -e "${_tsdb_status}"
        else
            printf "  %-26s ${AMARELO}%-18s${RESET} %s\n" "TimescaleDB" "não instalado" "(schema TSDB não será importado)"
        fi

        # — Schema Zabbix existente na BD —
        # Tabela de referência (baseada em erros confirmados em produção):
        #   mandatory 7000000–7039999  →  schema importado por Zabbix 7.0
        #   mandatory 7040000–7050032  →  schema importado por Zabbix 7.4
        #   mandatory  ≥ 7050033       →  schema importado por Zabbix 8.0
        local _incompativel=0
        local _schema_origem=""
        if [[ -n "$_zbx_dbver" && "$_zbx_dbver" =~ ^[0-9]+$ ]]; then
            if   [[ "$_zbx_dbver" -ge 7050033 ]]; then _schema_origem="8.0"
            elif [[ "$_zbx_dbver" -ge 7040000 ]]; then _schema_origem="7.4"
            elif [[ "$_zbx_dbver" -ge 7000000 ]]; then _schema_origem="7.0"
            elif [[ "$_zbx_dbver" -ge 6000000 ]]; then _schema_origem="6.x"
            else                                        _schema_origem="<6.0"
            fi
            case "$ZBX_VERSION" in
                "7.0") [[ "$_zbx_dbver" -lt 7000000 || "$_zbx_dbver" -ge 7040000 ]] && _incompativel=1 ;;
                "7.4") [[ "$_zbx_dbver" -lt 7040000 || "$_zbx_dbver" -ge 7050033 ]] && _incompativel=1 ;;
                "8.0") [[ "$_zbx_dbver" -lt 7050033 ]] && _incompativel=1 ;;
            esac
            local _zbx_schema_status
            if [[ "$_incompativel" == "0" ]]; then
                _zbx_schema_status="${VERDE}✔ Schema compatível — criado pelo Zabbix ${_schema_origem}${RESET}"
            else
                _zbx_schema_status="${VERMELHO}${NEGRITO}✖ INCOMPATÍVEL — schema Zabbix ${_schema_origem}, servidor ${ZBX_VERSION}${RESET}"
            fi
            printf "  %-26s ${AMARELO}%-18s${RESET} " "Schema Zabbix BD" "${_zbx_dbver}"
            echo -e "${_zbx_schema_status}"
        else
            printf "  %-26s ${VERDE}%-18s${RESET} %s\n" \
                "Schema Zabbix BD" "não encontrado" "(BD vazia — schema será importado agora)"
        fi

        echo -e "  ─────────────────────────────────────────────────────────────"

        # — Sem incompatibilidade: apenas ENTER e sair —
        if [[ "$_incompativel" == "0" ]]; then
            read -rp $'  Prima ENTER para continuar...' _dummy
            return 0
        fi

        # — Com incompatibilidade: menu de ação interativo —
        echo -e ""
        echo -e "  ${VERMELHO}${NEGRITO}⚠  CONFLITO DE VERSÃO DETETADO!${RESET}"
        echo -e "  ${VERMELHO}O schema na BD é do Zabbix ${_schema_origem} mas escolheu instalar o Zabbix ${ZBX_VERSION}.${RESET}"
        echo -e "  ${VERMELHO}Se continuar sem resolver, a interface web vai mostrar:${RESET}"
        echo -e "  ${VERMELHO}  \"Database error: version does not match current requirements\"${RESET}"
        echo -e ""
        echo -e "  ${CIANO}${NEGRITO}O que deseja fazer?${RESET}"
        echo -e "  ${AMARELO}1)${RESET} Alterar a versão do Zabbix ${CIANO}(recomendado: escolher Zabbix ${_schema_origem})${RESET}"
        echo -e "  ${AMARELO}2)${RESET} Re-inserir dados de conexão ${CIANO}(conectar a uma BD diferente)${RESET}"
        echo -e "  ${AMARELO}3)${RESET} Continuar mesmo assim ${VERMELHO}(a interface web não vai funcionar!)${RESET}"
        echo -e "  ${AMARELO}4)${RESET} ${VERMELHO}Abortar instalação${RESET}"
        echo -e ""
        while true; do
            read -rp "   Escolha (1-4): " _compat_opt
            case "$_compat_opt" in
                1) m_version; return 1 ;;
                2) return 2 ;;
                3)
                   echo -e "\n  ${VERMELHO}${NEGRITO}Confirmação forte:${RESET} digite CONTINUAR para assumir o risco de schema incompatível."
                   read -rp "   Confirmação: " _schema_force
                   if [[ "$_schema_force" == "CONTINUAR" ]]; then
                       echo -e "\n  ${AMARELO}⚠  A continuar. Resolva o conflito manualmente antes de aceder à interface web.${RESET}"
                       return 3
                   fi
                   echo -e "   ${AMARELO}Confirmação não recebida. Voltando às opções.${RESET}" ;;
                4) echo -e "${VERMELHO}Instalação abortada pelo utilizador.${RESET}"; exit 1 ;;
                *) echo -e "   ${VERMELHO}Opção inválida.${RESET}" ;;
            esac
        done
    }

    m_dbconn() {
        echo -e "\n${CIANO}${NEGRITO}>>> CONEXÃO COM A BASE DE DADOS <<<${RESET}"
        echo -e "  ${AMARELO}Use as credenciais do certificado gerado pelo AUTOMACAO-ZBX-DB.${RESET}"
        echo -e "  ${CIANO}ℹ Após autenticação bem-sucedida, a versão do PostgreSQL e a presença"
        echo -e "    do TimescaleDB serão detetadas automaticamente.${RESET}\n"
        echo -e "${AMARELO}IP da máquina de BD (DB Host)${RESET} — obrigatório"
        while true; do
            read -rp "   Preencher: " DB_HOST
            [[ -n "$DB_HOST" ]] && break
            echo -e "   ${VERMELHO}Campo obrigatório.${RESET}"
        done
        echo -e "\n${AMARELO}Porta PostgreSQL${RESET} (Padrão: 5432)"
        read -rp "   Valor Recomendado [5432]: " DB_PORT; DB_PORT=${DB_PORT:-5432}
        validate_port "$DB_PORT"
        echo -e "\n${AMARELO}Nome da Base de Dados${RESET} (Padrão: zabbix)"
        read -rp "   Valor Recomendado [zabbix]: " DB_NAME; DB_NAME=${DB_NAME:-zabbix}
        validate_identifier "$DB_NAME" "Nome da base de dados"
        echo -e "\n${AMARELO}Utilizador da Base de Dados${RESET}"
        while true; do
            read -rp "   Preencher (ex: zabbix ou zbx_f3a2b1c9): " DB_USER
            [[ -n "$DB_USER" ]] && { validate_identifier "$DB_USER" "Utilizador da base de dados"; break; }
            echo -e "   ${VERMELHO}Campo obrigatório.${RESET}"
        done
        echo -e "\n${AMARELO}Senha do Utilizador${RESET} — obrigatório"
        while true; do
            read -rsp "   Preencher: " DB_PASS; echo
            [[ -n "$DB_PASS" ]] && break
            echo -e "   ${VERMELHO}Campo obrigatório.${RESET}"
        done
        warn_weak_secret "$DB_PASS" "Senha da base de dados"

        if [[ "${SIMULATE_MODE:-0}" == "1" ]]; then
            echo -e "\n  ${AMARELO}SIMULAÇÃO:${RESET} testes TCP, autenticação psql e deteção automática da BD foram ignorados."
            echo -e "  ${AMARELO}SIMULAÇÃO:${RESET} mantendo PostgreSQL ${PG_VER}, TimescaleDB=$([[ "$USE_TIMESCALE" == "1" ]] && echo SIM || echo NÃO) e schema vazio."
            ZBX_DB_DETECTED=""
            return
        fi

        # ── Teste TCP ──────────────────────────────────────────────────────────
        echo -e "\n${CIANO}  A verificar conectividade com ${NEGRITO}${DB_HOST}:${DB_PORT}${RESET}${CIANO}...${RESET}"
        local _tcp_ok=0
        if timeout 5 bash -c "echo > /dev/tcp/${DB_HOST}/${DB_PORT}" 2>/dev/null; then
            _tcp_ok=1
            echo -e "  ${VERDE}${NEGRITO}✔ Porta ${DB_PORT}/TCP alcançável em ${DB_HOST}${RESET}"
        else
            echo -e "  ${VERMELHO}${NEGRITO}✖ Porta ${DB_PORT}/TCP INACESSÍVEL em ${DB_HOST}${RESET}"
            echo -e "  ${AMARELO}  Verifique: listen_addresses inclui o IP desta máquina e pg_hba.conf autoriza este servidor${RESET}"
            local _retry_conn
            ask_yes_no "Corrigir e re-inserir as credenciais agora?" _retry_conn
            if [[ "$_retry_conn" == "1" ]]; then m_dbconn; return; fi
            echo -e "  ${AMARELO}⚠  A continuar sem confirmação de rede.${RESET}"
            return
        fi

        # ── Garantir que psql está disponível (necessário para deteção automática) ──
        local _psql_cmd=""
        if type -P psql >/dev/null 2>&1; then
            _psql_cmd="psql"
        else
            echo -e "\n  ${AMARELO}ℹ psql não encontrado — instalando cliente PostgreSQL para deteção automática...${RESET}"
            # Em LXC recém-criado o cache apt pode estar vazio — atualizar antes de instalar
            apt-get update -qq >/dev/null 2>&1 || true
            if apt-get install -y --no-install-recommends postgresql-client \
                    >/dev/null 2>&1 && type -P psql >/dev/null 2>&1; then
                _psql_cmd="psql"
                echo -e "  ${VERDE}✔ Cliente psql instalado.${RESET}"
            else
                echo -e "  ${AMARELO}⚠  Não foi possível instalar psql."
                echo -e "     PostgreSQL ${NEGRITO}${PG_VER}${RESET}${AMARELO} (padrão) e TimescaleDB=NÃO serão usados."
                echo -e "     Pode re-inserir os dados de ligação após instalar psql para re-tentar.${RESET}"
                return
            fi
        fi

        # ── Autenticação + deteção automática (via .pgpass temporário) ──────────
        local _pgpass_tmp="${HOME}/.pgpass"
        local _pgpass_bak=""
        local _pgpass_db_pass
        _pgpass_db_pass=$(pgpass_escape "$DB_PASS")
        if [[ -f "$_pgpass_tmp" ]]; then
            _pgpass_bak=$(mktemp)
            cp "$_pgpass_tmp" "$_pgpass_bak"
        fi
        echo "${DB_HOST}:${DB_PORT}:*:${DB_USER}:${_pgpass_db_pass}" > "$_pgpass_tmp"
        chmod 0600 "$_pgpass_tmp"

        if ! psql -h "${DB_HOST}" -p "${DB_PORT}" \
                -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT 1;" >/dev/null 2>&1; then
            # Restaura pgpass antes de retry
            if [[ -n "$_pgpass_bak" && -f "$_pgpass_bak" ]]; then
                mv "$_pgpass_bak" "$_pgpass_tmp"
            else
                rm -f "$_pgpass_tmp"
            fi
            echo -e "  ${VERMELHO}${NEGRITO}✖ Autenticação falhou — credenciais incorretas ou pg_hba.conf nega o acesso${RESET}"
            local _retry_auth
            ask_yes_no "Re-inserir credenciais?" _retry_auth
            [[ "$_retry_auth" == "1" ]] && m_dbconn && return
            return
        fi

        echo -e "  ${VERDE}${NEGRITO}✔ Autenticação OK — ${DB_USER}@${DB_NAME}${RESET}"

        # ── Detetar versão do PostgreSQL ─────────────────────────────────────
        echo -e "\n  ${CIANO}A detetar versão do PostgreSQL e TimescaleDB...${RESET}"
        local _detected_pgver
        _detected_pgver=$(psql -h "${DB_HOST}" -p "${DB_PORT}" \
            -U "${DB_USER}" -d "${DB_NAME}" \
            -tAc "SELECT current_setting('server_version_num')::integer/10000;" \
            2>/dev/null | xargs || true)

        if [[ -n "$_detected_pgver" && "$_detected_pgver" =~ ^[0-9]+$ ]]; then
            PG_VER="$_detected_pgver"
            echo -e "  ${VERDE}${NEGRITO}✔ PostgreSQL ${PG_VER} detetado automaticamente${RESET}"
        else
            echo -e "  ${AMARELO}⚠  Não foi possível detetar versão do PG — mantendo padrão ${PG_VER}${RESET}"
        fi

        # ── Detetar TimescaleDB ───────────────────────────────────────────────
        local _detected_tsdb
        _detected_tsdb=$(psql -h "${DB_HOST}" -p "${DB_PORT}" \
            -U "${DB_USER}" -d "${DB_NAME}" \
            -tAc "SELECT extversion FROM pg_extension WHERE extname='timescaledb';" \
            2>/dev/null | xargs || true)

        if [[ -n "$_detected_tsdb" ]]; then
            USE_TIMESCALE="1"
            echo -e "  ${VERDE}${NEGRITO}✔ TimescaleDB ${_detected_tsdb} detetado automaticamente${RESET}"
        else
            USE_TIMESCALE="0"
            echo -e "  ${AMARELO}ℹ TimescaleDB não encontrado na BD${RESET}"
        fi

        # ── Detetar schema Zabbix existente (tabela dbversion) ───────────────
        # Se a tabela não existir, psql retorna erro (suprimido) e nada em stdout → variável vazia → BD limpa
        ZBX_DB_DETECTED=$(psql -h "${DB_HOST}" -p "${DB_PORT}" \
            -U "${DB_USER}" -d "${DB_NAME}" \
            -tAc "SELECT mandatory FROM dbversion LIMIT 1;" \
            2>/dev/null | xargs || true)

        if [[ -n "$ZBX_DB_DETECTED" && "$ZBX_DB_DETECTED" =~ ^[0-9]+$ ]]; then
            echo -e "  ${AMARELO}${NEGRITO}ℹ Schema Zabbix encontrado na BD — mandatory: ${ZBX_DB_DETECTED}${RESET}"
        else
            ZBX_DB_DETECTED=""
            echo -e "  ${VERDE}ℹ Nenhum schema Zabbix na BD — será importado durante a instalação${RESET}"
        fi

        # Restaura .pgpass original
        if [[ -n "$_pgpass_bak" && -f "$_pgpass_bak" ]]; then
            mv "$_pgpass_bak" "$_pgpass_tmp"
        else
            rm -f "$_pgpass_tmp"
        fi

        # ── Tabela de compatibilidade (com loop para tratar ações do utilizador) ──
        local _compat_ret
        while true; do
            _show_compat_table "$_detected_tsdb" "$ZBX_DB_DETECTED"
            _compat_ret=$?
            case "$_compat_ret" in
                0|3) break ;;           # compatível ou continuar mesmo assim
                1)   ;;                 # versão Zabbix alterada → re-mostrar tabela com nova versão
                2)   m_dbconn; return ;; # re-inserir credenciais
            esac
        done
    }

    m_nginx() {
        echo -e "\n${CIANO}${NEGRITO}>>> CONFIGURAÇÃO NGINX + FRONTEND <<<${RESET}"
        echo -e "\n${AMARELO}Protocolo de acesso ao Frontend:${RESET}"
        echo -e "   1) ${NEGRITO}HTTP${RESET}  — porta 80  (sem SSL)"
        echo -e "   2) ${NEGRITO}HTTPS${RESET} — porta 443 (com SSL/TLS)"
        echo -e "   3) ${NEGRITO}HTTP${RESET}  — porta personalizada (sem SSL)"
        while true; do
            read -rp "   Escolha (1, 2 ou 3): " proto_opt
            case "$proto_opt" in
                1) USE_HTTPS="0"; NGINX_PORT="80"; break ;;
                2) USE_HTTPS="1"; NGINX_PORT="443"
                   echo -e "\n   ${CIANO}${NEGRITO}Tipo de Certificado SSL:${RESET}"
                   echo -e "   1) Auto-assinado (gerado agora, 10 anos)"
                   echo -e "   2) Certificado existente (fornecer caminhos)"
                   echo -e "   3) Configurar HTTPS sem certificado agora"
                   while true; do
                       read -rp "   Escolha (1, 2 ou 3): " ssl_opt
                       case "$ssl_opt" in
                           1) SSL_TYPE="self-signed"
                              SSL_CERT="/etc/ssl/zabbix/zabbix.crt"
                              SSL_KEY="/etc/ssl/zabbix/zabbix.key"
                              break ;;
                           2) SSL_TYPE="existing"
                              while true; do read -rp "   Caminho do .crt: " SSL_CERT; [[ -n "$SSL_CERT" ]] && break; done
                              while true; do read -rp "   Caminho do .key: " SSL_KEY;  [[ -n "$SSL_KEY"  ]] && break; done
                              break ;;
                           3) SSL_TYPE="later"
                              SSL_CERT="/etc/ssl/zabbix/zabbix.crt"
                              SSL_KEY="/etc/ssl/zabbix/zabbix.key"
                              break ;;
                           *) echo -e "   ${VERMELHO}Opção inválida.${RESET}" ;;
                       esac
                   done
                   ask_yes_no "Ativar redirecionamento HTTP (80) → HTTPS (443)?" USE_HTTP_REDIRECT
                   break ;;
                3) USE_HTTPS="0"
                   read -rp "   Porta personalizada [8080]: " NGINX_PORT; NGINX_PORT=${NGINX_PORT:-8080}
                   validate_port "$NGINX_PORT"
                   break ;;
                *) echo -e "   ${VERMELHO}Opção inválida.${RESET}" ;;
            esac
        done
        echo -e "\n${AMARELO}Server Name (hostname/IP ou domínio do servidor)${RESET}"
        echo -e "   Deixe em branco para aceitar qualquer hostname (usa '_')."
        while true; do
            read -rp "   Preencher [_]: " SERVER_NAME; SERVER_NAME=${SERVER_NAME:-_}
            if [[ "$SERVER_NAME" == "_" || "$SERVER_NAME" =~ ^[a-zA-Z0-9._*-]+$ ]]; then
                break
            fi
            echo -e "   ${VERMELHO}Server Name inválido: '${SERVER_NAME}'${RESET}"
            echo -e "   Use apenas letras, números, pontos, hífens, asterisco ou '_' para qualquer host."
        done

        echo -e "\n${CIANO}${NEGRITO}>>> LIMITES PHP-FPM (UPLOAD DE TEMPLATES E IMAGENS) <<<${RESET}"
        echo -e "  O padrão do PHP é 2M — insuficiente para importar templates grandes,"
        echo -e "  iconsets e mapas no frontend Zabbix. Erros como '413 Request Entity"
        echo -e "  Too Large' ou 'falha ao importar' são causados por este limite."
        echo -e ""
        echo -e "  ${AMARELO}1)${RESET} 16M  — templates simples, uso leve"
        echo -e "  ${AMARELO}2)${RESET} 32M  — recomendado para a maioria dos ambientes"
        echo -e "  ${AMARELO}3)${RESET} 64M  — iconsets grandes, mapas e templates complexos"
        echo -e "  ${AMARELO}4)${RESET} 128M — ambientes muito grandes com muitos templates"
        echo -e "  ${AMARELO}5)${RESET} Personalizado"
        while true; do
            read -rp "   Escolha (1-5) [2]: " up_opt; up_opt=${up_opt:-2}
            case "$up_opt" in
                1) PHP_UPLOAD_SIZE="16M";  break ;;
                2) PHP_UPLOAD_SIZE="32M";  break ;;
                3) PHP_UPLOAD_SIZE="64M";  break ;;
                4) PHP_UPLOAD_SIZE="128M"; break ;;
                5) while true; do
                       read -rp "   Tamanho personalizado (ex: 256M): " PHP_UPLOAD_SIZE
                       [[ "$PHP_UPLOAD_SIZE" =~ ^[0-9]+[MmGg]$ ]] && break
                       echo -e "   ${VERMELHO}Formato inválido. Use ex: 64M ou 1G${RESET}"
                   done; break ;;
                *) echo -e "   ${VERMELHO}Opção inválida.${RESET}" ;;
            esac
        done
        validate_size "$PHP_UPLOAD_SIZE" "PHP upload_max_filesize"
        echo -e "   ${VERDE}Upload máximo definido: ${NEGRITO}${PHP_UPLOAD_SIZE}${RESET}"
    }


    m_agent() {
        echo -e "\n${CIANO}${NEGRITO}>>> ZABBIX AGENT 2 (nesta máquina Server) <<<${RESET}"
        ask_yes_no "Instalar e configurar o Zabbix Agent 2 neste host?" INSTALL_AGENT
        if [[ "$INSTALL_AGENT" == "1" ]]; then
            echo -e "\n${AMARELO}Server${RESET} (Escuta Passiva)"
            read -rp "   Valor Recomendado [127.0.0.1]: " AG_SERVER; AG_SERVER=${AG_SERVER:-127.0.0.1}
            validate_zabbix_identity "$AG_SERVER" "Server do Agente"
            echo -e "\n${AMARELO}ServerActive${RESET} (Envio Ativo)"
            read -rp "   Valor Recomendado [127.0.0.1]: " AG_SERVER_ACTIVE; AG_SERVER_ACTIVE=${AG_SERVER_ACTIVE:-127.0.0.1}
            validate_zabbix_identity "$AG_SERVER_ACTIVE" "ServerActive do Agente"
            echo -e "\n${AMARELO}Hostname do Agente${RESET} (Identificação única)"
            while true; do
                read -rp "   Preencher [$(hostname)]: " AG_HOSTNAME
                AG_HOSTNAME=${AG_HOSTNAME:-$(hostname)}
                [[ -n "$AG_HOSTNAME" ]] && break
            done
            validate_zabbix_identity "$AG_HOSTNAME" "Hostname do Agente"
            echo -e "${VERMELHO}${NEGRITO}⚠ ATENÇÃO:${RESET} AllowKey=system.run[*] permite execução remota de comandos pelo Zabbix."
            echo -e "${AMARELO}Use apenas em ambiente controlado e preferencialmente com PSK/TLS.${RESET}"
            ask_yes_no "   Habilitar AllowKey=system.run[*] neste agente?" AG_ALLOWKEY
        fi
    }

    m_security() {
        echo -e "\n${CIANO}${NEGRITO}>>> SEGURANÇA E CRIPTOGRAFIA <<<${RESET}"
        if [[ "$INSTALL_AGENT" == "1" ]]; then
            ask_yes_no "Configurar criptografia PSK para o Agent 2 desta máquina?" USE_PSK
            if [[ "$USE_PSK" == "1" ]]; then
                while true; do
                    read -rp "   Identidade PSK do Agente (ex: AGENT-SERVER-01): " PSK_AGENT_ID
                    [[ -n "$PSK_AGENT_ID" ]] && break
                    echo -e "   ${VERMELHO}Campo obrigatório.${RESET}"
                done
                validate_zabbix_identity "$PSK_AGENT_ID" "PSK Identity do Agente"
            fi
        fi
    }

    m_tuning() {
        ask_yes_no "Aplicar Tuning Avançado do Zabbix Server (23 Parâmetros)?" USE_TUNING
        if [[ "$USE_TUNING" == "1" ]]; then
            echo -e "\n${CIANO}${NEGRITO}>>> ASSISTENTE EXPLICATIVO DE PERFORMANCE — ZABBIX SERVER 7.x <<<${RESET}"
            echo -e "Prima [ENTER] para usar o valor recomendado entre [colchetes].\n"

            echo -e "${AMARELO}1. CacheSize${RESET} (Limites: 128K–64G | Padrão: 32M)"
            echo -e "   Memória partilhada para configurações de hosts, itens e triggers."
            read -rp "   Valor Recomendado [${T_CACHE}]: " _v; T_CACHE=${_v:-$T_CACHE}

            echo -e "\n${AMARELO}2. HistoryCacheSize${RESET} (Limites: 128K–2G | Padrão: 16M)"
            echo -e "   Cache de métricas recentes antes de escrever na BD. Crítico para alto throughput."
            read -rp "   Valor Recomendado [${T_HCACHE}]: " _v; T_HCACHE=${_v:-$T_HCACHE}

            echo -e "\n${AMARELO}3. HistoryIndexCacheSize${RESET} (Limites: 128K–2G | Padrão: 4M)"
            echo -e "   Índice da cache de histórico — acelera pesquisas de valores."
            read -rp "   Valor Recomendado [32M]: " T_HICACHE; T_HICACHE=${T_HICACHE:-32M}

            echo -e "\n${AMARELO}4. ValueCacheSize${RESET} (Limites: 0–64G | Padrão: 8M)"
            echo -e "   Cache de valores históricos para cálculo de funções e avaliação de triggers."
            read -rp "   Valor Recomendado [${T_VCACHE}]: " _v; T_VCACHE=${_v:-$T_VCACHE}

            echo -e "\n${AMARELO}5. TrendCacheSize${RESET} (Limites: 128K–2G | Padrão: 4M)"
            echo -e "   Cache de dados de tendência (min/max/avg por hora)."
            read -rp "   Valor Recomendado [${T_TRCACHE}]: " _v; T_TRCACHE=${_v:-$T_TRCACHE}

            echo -e "\n${AMARELO}6. StartPollers${RESET} (Limites: 0–1000 | Padrão: 5)"
            echo -e "   Coletores passivos genéricos (Agent 1, SNMP, scripts)."
            read -rp "   Valor Recomendado [${T_POLL}]: " _v; T_POLL=${_v:-$T_POLL}

            echo -e "\n${AMARELO}7. StartPollersUnreachable${RESET} (Limites: 0–1000 | Padrão: 1)"
            echo -e "   Coletores dedicados a hosts em estado 'caído', sem bloquear os saudáveis."
            read -rp "   Valor Recomendado [5]: " T_PUNREACH; T_PUNREACH=${T_PUNREACH:-5}

            echo -e "\n${AMARELO}8. StartTrappers${RESET} (Limites: 0–1000 | Padrão: 5)"
            echo -e "   Processos que recebem dados de Agentes Ativos e Zabbix Sender."
            read -rp "   Valor Recomendado [10]: " T_TRAP; T_TRAP=${T_TRAP:-10}

            echo -e "\n${AMARELO}9. StartPreprocessors${RESET} (Limites: 1–1000 | Padrão: 3)"
            echo -e "   Threads para converter e processar dados brutos antes da cache."
            read -rp "   Valor Recomendado [${T_PREPROC}]: " _v; T_PREPROC=${_v:-$T_PREPROC}

            echo -e "\n${AMARELO}10. StartDBSyncers${RESET} (Limites: 1–100 | Padrão: 4)"
            echo -e "   Sincronizadores da cache de memória para a Base de Dados."
            read -rp "   Valor Recomendado [${T_DBSYNC}]: " _v; T_DBSYNC=${_v:-$T_DBSYNC}

            echo -e "\n${AMARELO}11. StartPingers${RESET} (Limites: 0–1000 | Padrão: 1)"
            echo -e "   Processos exclusivos para testes de ICMP (ping)."
            read -rp "   Valor Recomendado [5]: " T_PING; T_PING=${T_PING:-5}

            echo -e "\n${AMARELO}12. StartDiscoverers${RESET} (Limites: 0–250 | Padrão: 5)"
            echo -e "   Processos de descoberta de rede (Network Discovery)."
            read -rp "   Valor Recomendado [5]: " T_DISC; T_DISC=${T_DISC:-5}

            echo -e "\n${AMARELO}13. StartHTTPPollers${RESET} (Limites: 0–1000 | Padrão: 1)"
            echo -e "   Processos para testes de cenários Web HTTP."
            read -rp "   Valor Recomendado [5]: " T_HTTP; T_HTTP=${T_HTTP:-5}

            echo -e "\n${AMARELO}14. StartAgentPollers${RESET} (Limites: 0–1000 | Padrão: 1)"
            echo -e "   Coletores assíncronos de alta concorrência para Zabbix Agent 2."
            read -rp "   Valor Recomendado [1]: " T_APOLL; T_APOLL=${T_APOLL:-1}

            echo -e "\n${AMARELO}15. StartHTTPAgentPollers${RESET} (Limites: 0–1000 | Padrão: 1)"
            echo -e "   Coletores assíncronos de alta concorrência para o HTTP Agent."
            read -rp "   Valor Recomendado [1]: " T_HAPOLL; T_HAPOLL=${T_HAPOLL:-1}

            echo -e "\n${AMARELO}16. StartSNMPPollers${RESET} (Limites: 0–1000 | Padrão: 1)"
            echo -e "   Coletores assíncronos dedicados a queries SNMP de alta eficiência."
            read -rp "   Valor Recomendado [10]: " T_SPOLL; T_SPOLL=${T_SPOLL:-10}

            echo -e "\n${AMARELO}17. StartBrowserPollers${RESET} (Limites: 0–1000 | Padrão: 1)"
            echo -e "   Coletores para itens de monitorização via Browser (Zabbix 7.0+)."
            read -rp "   Valor Recomendado [1]: " T_BPOLL; T_BPOLL=${T_BPOLL:-1}

            echo -e "\n${AMARELO}18. StartODBCPollers${RESET} (Limites: 0–1000 | Padrão: 1)"
            echo -e "   Coletores para itens de BD via ODBC (DB Monitor)."
            read -rp "   Valor Recomendado [1]: " T_ODBCPOLL; T_ODBCPOLL=${T_ODBCPOLL:-1}

            echo -e "\n${AMARELO}19. MaxConcurrentChecksPerPoller${RESET} (Limites: 1–1000 | Padrão: 1000)"
            echo -e "   Métricas que um único poller assíncrono processa por ciclo."
            read -rp "   Valor Recomendado [1000]: " T_MAXC; T_MAXC=${T_MAXC:-1000}

            echo -e "\n${AMARELO}20. UnreachablePeriod${RESET} (Limites: 1–3600 | Padrão: 45)"
            echo -e "   Segundos sem resposta até o host ser considerado incontactável."
            read -rp "   Valor Recomendado [45]: " T_UNREACH; T_UNREACH=${T_UNREACH:-45}

            echo -e "\n${AMARELO}21. Timeout${RESET} (Limites: 1–30 | Padrão: 3 segundos)"
            echo -e "   Tempo máximo de espera por resposta de agentes/rede."
            read -rp "   Valor Recomendado [5]: " T_TOUT; T_TOUT=${T_TOUT:-5}

            echo -e "\n${AMARELO}22. HousekeepingFrequency${RESET} (Limites: 0–24 horas | Padrão: 1)"
            echo -e "   Frequência (horas) da limpeza automática de dados antigos. 0=desativado."
            read -rp "   Valor Recomendado [1]: " T_HK; T_HK=${T_HK:-1}

            echo -e "\n${AMARELO}23. LogSlowQueries${RESET} (Padrão: 0=desativado | em milissegundos)"
            echo -e "   Regista queries lentas à BD no log do Server. Útil para diagnóstico."
            read -rp "   Valor Recomendado [3000]: " T_SLOWQ; T_SLOWQ=${T_SLOWQ:-3000}
            validate_size "$T_CACHE" "CacheSize"
            validate_size "$T_HCACHE" "HistoryCacheSize"
            validate_size "$T_HICACHE" "HistoryIndexCacheSize"
            validate_size "$T_VCACHE" "ValueCacheSize"
            validate_size "$T_TRCACHE" "TrendCacheSize"
            validate_int_range "$T_POLL" "StartPollers" 0 1000
            validate_int_range "$T_PUNREACH" "StartPollersUnreachable" 0 1000
            validate_int_range "$T_TRAP" "StartTrappers" 0 1000
            validate_int_range "$T_PREPROC" "StartPreprocessors" 1 1000
            validate_int_range "$T_DBSYNC" "StartDBSyncers" 1 100
            validate_int_range "$T_PING" "StartPingers" 0 1000
            validate_int_range "$T_DISC" "StartDiscoverers" 0 250
            validate_int_range "$T_HTTP" "StartHTTPPollers" 0 1000
            validate_int_range "$T_APOLL" "StartAgentPollers" 0 1000
            validate_int_range "$T_HAPOLL" "StartHTTPAgentPollers" 0 1000
            validate_int_range "$T_SPOLL" "StartSNMPPollers" 0 1000
            validate_int_range "$T_BPOLL" "StartBrowserPollers" 0 1000
            validate_int_range "$T_ODBCPOLL" "StartODBCPollers" 0 1000
            validate_int_range "$T_MAXC" "MaxConcurrentChecksPerPoller" 1 1000
            validate_int_range "$T_UNREACH" "UnreachablePeriod" 1 3600
            validate_int_range "$T_TOUT" "Timeout" 1 30
            validate_int_range "$T_HK" "HousekeepingFrequency" 0 24
            validate_int_range "$T_SLOWQ" "LogSlowQueries" 0 3600000
        fi
    }

    m_timezone() {
        TIMEZONE="$(select_timezone_value "$TIMEZONE" "Será aplicado ao PHP-FPM e ao utilizador Admin do Zabbix.")"
        echo -e "   ${VERDE}Fuso configurado: ${NEGRITO}${TIMEZONE}${RESET}"
    }

    m_clean; m_update; m_version; m_dbconn
    m_nginx; m_agent; m_security; m_tuning; m_timezone

    # Menu de revisão
    while true; do
        clear
        echo -e "${CIANO}${NEGRITO}╔══════════════════════════════════════════════════════════╗${RESET}"
        echo -e "${CIANO}${NEGRITO}║           REVISÃO FINAL — CAMADA DE SERVIDOR             ║${RESET}"
        echo -e "${CIANO}${NEGRITO}╚══════════════════════════════════════════════════════════╝${RESET}"
        echo -e "  ${AMARELO}2)${RESET}  Atualização:       $([[ "$UPDATE_SYSTEM" == "1" ]] && echo -e "${VERDE}ATIVADA${RESET}" || echo "NÃO")"
        echo -e "  ${AMARELO}3)${RESET}  Versão Zabbix:     ${VERDE}${ZBX_VERSION}${RESET}"
        echo -e "  ${AMARELO}4)${RESET}  BD Host:Port:      ${NEGRITO}${DB_HOST:-não definido}:${DB_PORT}${RESET}"
        echo -e "  ${AMARELO}5)${RESET}  BD Nome / User:    ${CIANO}${DB_NAME}${RESET} / ${CIANO}${DB_USER:-não definido}${RESET}"
        echo -e "  ${AMARELO}6)${RESET}  PostgreSQL:        ${VERDE}${PG_VER}${RESET} ${CIANO}(auto-detetado)${RESET}"
        echo -e "  ${AMARELO}7)${RESET}  TimescaleDB:       $([[ "$USE_TIMESCALE" == "1" ]] && echo -e "${VERDE}SIM${RESET} ${CIANO}(auto-detetado)${RESET}" || echo -e "NÃO ${CIANO}(auto-detetado)${RESET}")"
        # Linha de schema Zabbix existente — mostra aviso vermelho se incompatível
        if [[ -n "$ZBX_DB_DETECTED" ]]; then
            _rev_schema_origem=""
            if   [[ "$ZBX_DB_DETECTED" -ge 7050033 ]]; then _rev_schema_origem="8.0"
            elif [[ "$ZBX_DB_DETECTED" -ge 7040000 ]]; then _rev_schema_origem="7.4"
            elif [[ "$ZBX_DB_DETECTED" -ge 7000000 ]]; then _rev_schema_origem="7.0"
            else                                            _rev_schema_origem="<7.0"
            fi
            if [[ "$_rev_schema_origem" == "$ZBX_VERSION" ]]; then
                echo -e "  ${AMARELO}8)${RESET}  Schema Zabbix BD:  ${VERDE}✔ ${ZBX_DB_DETECTED} (Zabbix ${_rev_schema_origem}) — compatível${RESET}"
            else
                echo -e "  ${AMARELO}8)${RESET}  Schema Zabbix BD:  ${VERMELHO}${NEGRITO}✖ ${ZBX_DB_DETECTED} (Zabbix ${_rev_schema_origem}) — INCOMPATÍVEL com ${ZBX_VERSION}!${RESET}"
                echo -e "             ${VERMELHO}→ Altere a versão em 3) ou volte a executar 4-8 após corrigir a BD${RESET}"
            fi
        else
            echo -e "  ${AMARELO}8)${RESET}  Schema Zabbix BD:  ${VERDE}BD vazia — schema será importado${RESET}"
        fi
        if [[ "$USE_HTTPS" == "1" ]]; then
            echo -e "  ${AMARELO}9)${RESET}  Acesso Frontend:   ${VERDE}HTTPS${RESET} porta ${VERDE}${NGINX_PORT}${RESET} | SSL: ${CIANO}${SSL_TYPE}${RESET} | Redir: $([[ "$USE_HTTP_REDIRECT" == "1" ]] && echo -e "${VERDE}SIM${RESET}" || echo "NÃO")"
        else
            echo -e "  ${AMARELO}9)${RESET}  Acesso Frontend:   ${CIANO}HTTP${RESET} porta ${CIANO}${NGINX_PORT}${RESET}"
        fi
        echo -e "  ${AMARELO}10)${RESET} Server Name:       ${CIANO}${SERVER_NAME}${RESET}"
        echo -e "  ${AMARELO}11)${RESET} PHP Upload Máximo: ${CIANO}${PHP_UPLOAD_SIZE}${RESET}  ${AMARELO}(templates, imagens, mapas)${RESET}"
        echo -e "  ${AMARELO}12)${RESET} Zabbix Agent 2:    $([[ "$INSTALL_AGENT" == "1" ]] && echo -e "${VERDE}INSTALAR (${AG_HOSTNAME})${RESET}" || echo "NÃO")"
        echo -e "  ${AMARELO}13)${RESET} PSK Agent:         $([[ "$USE_PSK" == "1" ]] && echo -e "${VERDE}ATIVO (${PSK_AGENT_ID})${RESET}" || echo "INATIVO")"
        echo -e "  ${AMARELO}14)${RESET} Performance Auto:  ${VERDE}${SERVER_PERF_PROFILE}${RESET} (Cache: ${T_CACHE} | History: ${T_HCACHE} | Trend: ${T_TRCACHE} | Value: ${T_VCACHE} | Pollers: ${T_POLL} | Preproc: ${T_PREPROC} | DBSyncers: ${T_DBSYNC})"
        echo -e "  ${AMARELO}15)${RESET} Tuning Manual:     $([[ "$USE_TUNING" == "1" ]] && echo -e "${VERDE}SIM — 23 params${RESET}" || echo "NÃO")"
        echo -e "  ${AMARELO}16)${RESET} Fuso Horário:      ${CIANO}${TIMEZONE}${RESET}"
        echo -e "  ${AMARELO}17)${RESET} ${VERMELHO}Abortar Instalação${RESET}"
        echo -e "\n  ${VERDE}${NEGRITO}0) [ TUDO PRONTO - INICIAR INSTALAÇÃO ]${RESET}"
        echo -e "${CIANO}------------------------------------------------------------${RESET}"
        read -rp "Insira o número da secção a alterar ou 0 para executar: " rev_opt
        case $rev_opt in
            2) m_update ;; 3) m_version ;; 4|5|6|7|8) m_dbconn ;;
            9|10|11) m_nginx ;; 12) m_agent ;; 13) m_security ;; 14|15) m_tuning ;;
            16) m_timezone ;;
            17) echo -e "${VERMELHO}Instalação abortada pelo utilizador.${RESET}"; exit 1 ;; 0) break ;;
        esac
    done

    # Pipeline
    confirm_execution_summary "Server"
    validate_compatibility_matrix "server"
    echo -e "\n${CIANO}${NEGRITO}A processar pipeline... Não cancele a operação!${RESET}\n"
    preflight_install_check "server" 4096 2048
    TOTAL_STEPS=26  # +1 para apt-mark hold
    [[ "$CLEAN_INSTALL" == "1" ]]  && TOTAL_STEPS=$(( TOTAL_STEPS + 3 ))
    [[ "$UPDATE_SYSTEM" == "1" ]]  && TOTAL_STEPS=$(( TOTAL_STEPS + 2 ))
    [[ "$NEED_PHP_PPA"  == "1" ]]  && TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))
    [[ "$USE_TIMESCALE" == "1" ]]  && TOTAL_STEPS=$(( TOTAL_STEPS + 2 ))   # import + compressão
    [[ "$USE_HTTPS" == "1" && "$SSL_TYPE" == "self-signed" ]] && TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))
    [[ "$INSTALL_AGENT" == "1" ]]  && TOTAL_STEPS=$(( TOTAL_STEPS + 2 ))
    [[ "$USE_PSK" == "1" && "$INSTALL_AGENT" == "1" ]] && TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))
    _IS_CONTAINER=0; systemd-detect-virt -c -q 2>/dev/null && _IS_CONTAINER=1 || true
    [[ "$_IS_CONTAINER" == "0" ]] && TOTAL_STEPS=$(( TOTAL_STEPS + 2 ))  # timedatectl + NTP
    [[ "$SIMULATE_MODE" == "1" ]] && echo -e "\n${CIANO}${NEGRITO}SIMULAÇÃO DO PIPELINE — SERVER${RESET}\n"

    if [[ "$CLEAN_INSTALL" == "1" ]]; then
        safe_confirm_cleanup "Limpeza da camada Server" \
            "serviços zabbix-server, zabbix-agent2 e nginx" \
            "pacotes Zabbix Server/Nginx/PHP relacionados" \
            "/etc/zabbix /var/lib/zabbix /var/log/zabbix /run/zabbix /tmp/zabbix_*"
        run_step "Parando serviços Zabbix e Nginx" bash -c \
            "for svc in zabbix-server zabbix-agent2 nginx; do \
                 timeout 15 systemctl stop \$svc 2>/dev/null || \
                 systemctl kill --kill-who=all \$svc 2>/dev/null || true; \
                 systemctl disable \$svc 2>/dev/null || true; \
             done; \
             pkill -9 -x zabbix_server 2>/dev/null || true; \
             pkill -9 -x zabbix_agent2 2>/dev/null || true; \
             pkill -9 -x nginx         2>/dev/null || true"
        run_step "Purge completo de pacotes Zabbix e Nginx" bash -c \
            "dpkg -l 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^ii|^rc/ && \$2 ~ /(zabbix|nginx)/ {print \$2}' | \
             xargs -r apt-mark unhold 2>/dev/null || true; \
             dpkg -l 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^ii|^rc/ && \$2 ~ /(zabbix|nginx)/ {print \$2}' | \
             xargs -r apt-get purge -y 2>/dev/null || true; apt-get autoremove -y 2>/dev/null || true"
        run_step "Remoção de configs, logs e dados Zabbix" bash -c \
            "rm -rf /etc/zabbix /var/lib/zabbix /var/log/zabbix /run/zabbix /tmp/zabbix_* 2>/dev/null || true; rm -f /tmp/zbx_repo.deb /etc/apt/sources.list.d/zabbix*.list /etc/apt/sources.list.d/zabbix*.sources /etc/apt/sources.list.d/pgdg.list /etc/apt/sources.list.d/timescaledb.list /etc/apt/trusted.gpg.d/timescaledb.gpg /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc 2>/dev/null || true"
    fi

    # Em containers LXC o relógio é gerido pelo host — tentar alterar causa erro fatal.
    # systemd-detect-virt -c retorna 0 (verdadeiro) se for qualquer container (LXC, Docker, etc).
    if ! systemd-detect-virt -c -q 2>/dev/null; then
        run_step "Ajustando relógio (${TIMEZONE})" timedatectl set-timezone "${TIMEZONE}"
        run_step "Ativando motor NTP" systemctl enable --now systemd-timesyncd
    else
        echo -e "\n  ${AMARELO}⚠ Ambiente de container (LXC) detectado. Pulando configuração de NTP (gerido pelo Host).${RESET}"
    fi
    run_step "Destravando processos do APT" auto_repair_apt
    run_step "Atualizando caches locais" apt-get update

    if [[ "$UPDATE_SYSTEM" == "1" ]]; then
        run_step "Realizando upgrade seguro dos pacotes do sistema" apt-get upgrade "${APT_FLAGS[@]}"
        run_step "Instalando ferramentas de rede e diagnóstico" install_server_diag_tools
    fi

    if [[ "$SIMULATE_MODE" != "1" ]]; then
        _server_base_check=(curl wget ca-certificates gnupg apt-transport-https lsb-release locales python3)
        [[ "$NEED_PHP_PPA" == "1" && "$OS_FAMILY" == "ubuntu" ]] && _server_base_check+=(software-properties-common)
        validate_packages_available "${_server_base_check[@]}"
    fi
    run_step "Instalando dependências base" install_server_base_deps

    [[ "$NEED_PHP_PPA" == "1" && "$OS_FAMILY" == "ubuntu" ]] && \
        run_step "Adicionando PPA ondrej/php (PHP ${PHP_VER} para Ubuntu ${U_VER})" \
            add-apt-repository -y ppa:ondrej/php

    setup_pgdg_repo() {
        install -d /usr/share/postgresql-common/pgdg
        curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
            https://www.postgresql.org/media/keys/ACCC4CF8.asc
        echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
https://apt.postgresql.org/pub/repos/apt ${U_CODENAME}-pgdg main" \
            > /etc/apt/sources.list.d/pgdg.list
    }
    run_step "Adicionando repositório PGDG (cliente psql)" setup_pgdg_repo
    run_step "Sincronizando repositórios" apt-get update
    [[ "$SIMULATE_MODE" != "1" ]] && check_package_available "postgresql-client-${PG_VER}" "PostgreSQL Client ${PG_VER}"
    run_step "Instalando cliente PostgreSQL ${PG_VER}" \
        apt-get install "${APT_FLAGS[@]}" "postgresql-client-${PG_VER}"

    if [[ "$ZBX_VERSION" == "8.0" ]]; then
        REPO_URL="$(zabbix_release_url "8.0")"
    elif [[ "$ZBX_VERSION" == "7.4" ]]; then
        REPO_URL="$(zabbix_release_url "7.4")"
    else
        REPO_URL="$(zabbix_release_url "7.0")"
    fi
    run_step "Validando URL do repositório Zabbix ${ZBX_VERSION}" check_zabbix_repo_url
    [[ "$SIMULATE_MODE" != "1" ]] && validate_official_zabbix_package zabbix-server-pgsql "$ZBX_VERSION"
    run_step "Baixando repositório oficial Zabbix ${ZBX_VERSION}" wget -q "$REPO_URL" -O /tmp/zbx_repo.deb
    run_step "Registando repositório Zabbix" dpkg --force-confmiss -i /tmp/zbx_repo.deb
    run_step "Sincronizando repositório Zabbix" apt-get update
    run_step "Verificando acesso ao repositório Zabbix ${ZBX_VERSION}" verify_zabbix_repo_active zabbix-server-pgsql
    [[ "$SIMULATE_MODE" != "1" ]] && validate_packages_available \
        zabbix-server-pgsql zabbix-frontend-php zabbix-nginx-conf zabbix-sql-scripts \
        nginx "php${PHP_VER}-fpm" "php${PHP_VER}-pgsql" "php${PHP_VER}-bcmath" \
        "php${PHP_VER}-mbstring" "php${PHP_VER}-gd" "php${PHP_VER}-xml" \
        "php${PHP_VER}-ldap" "php${PHP_VER}-curl" "php${PHP_VER}-zip"

    run_step "Instalando Zabbix Server + Frontend + SQL Scripts" \
        apt-get install "${APT_FLAGS[@]}" \
        zabbix-server-pgsql zabbix-frontend-php zabbix-nginx-conf zabbix-sql-scripts

    run_step "Instalando Nginx + PHP ${PHP_VER}-FPM e extensões" \
        apt-get install "${APT_FLAGS[@]}" nginx \
        "php${PHP_VER}-fpm" "php${PHP_VER}-pgsql" "php${PHP_VER}-bcmath" \
        "php${PHP_VER}-mbstring" "php${PHP_VER}-gd" "php${PHP_VER}-xml" \
        "php${PHP_VER}-ldap" "php${PHP_VER}-curl" "php${PHP_VER}-zip"

    ensure_server_config_files() {
        local missing=0 pkg
        for pkg in zabbix-server-pgsql zabbix-nginx-conf; do
            apt-get install "${APT_FLAGS[@]}" --reinstall -o Dpkg::Options::="--force-confmiss" "$pkg" >/dev/null
        done
        if [[ ! -f /etc/zabbix/zabbix_server.conf ]]; then
            echo "Arquivo /etc/zabbix/zabbix_server.conf ausente após reinstalação do pacote." >&2
            missing=1
        fi
        if [[ ! -f /etc/zabbix/nginx.conf ]]; then
            echo "Arquivo /etc/zabbix/nginx.conf ausente após reinstalação do pacote." >&2
            missing=1
        fi
        [[ "$missing" == "0" ]]
    }
    run_step "Validando arquivos de configuração do Zabbix Server" ensure_server_config_files

    run_step "Gerando locales pt_BR.UTF-8 e en_US.UTF-8" ensure_utf8_locales

    if [[ "$INSTALL_AGENT" == "1" ]]; then
        install_agent2_pkg() {
            apt-mark unhold zabbix-agent2 2>/dev/null || true
            apt-get install "${APT_FLAGS[@]}" zabbix-agent2
        }
        run_step "Instalando Zabbix Agent 2" install_agent2_pkg
    fi

    if [[ "$USE_HTTPS" == "1" && "$SSL_TYPE" == "self-signed" ]]; then
        generate_ssl_cert() {
            mkdir -p /etc/ssl/zabbix
            openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
                -keyout "$SSL_KEY" -out "$SSL_CERT" \
                -subj "/CN=${SERVER_NAME:-localhost}/O=Zabbix/OU=Monitoring/C=BR" 2>/dev/null
            chmod 640 "$SSL_KEY"
            chown root:www-data "$SSL_KEY" 2>/dev/null || chown root:nginx "$SSL_KEY" 2>/dev/null || true
        }
        run_step "Gerando certificado SSL auto-assinado (10 anos)" generate_ssl_cert
    fi

    # ------------------------------------------------------------------
    # Segurança: cria ~/.pgpass para que o psql nunca receba a senha
    # via variável de ambiente (visível em /proc/<pid>/environ e bash -x).
    # O trap EXIT garante a remoção mesmo em erro fatal ou Ctrl+C.
    # O ficheiro anterior do utilizador (se existir) é preservado e
    # restaurado automaticamente ao fim.
    # ------------------------------------------------------------------
    _PGPASS_FILE="${HOME}/.pgpass"
    _PGPASS_BACKUP=""
    setup_pgpass() {
        local _pgpass_db_pass
        _pgpass_db_pass=$(pgpass_escape "$DB_PASS")
        if [[ -f "$_PGPASS_FILE" ]]; then
            _PGPASS_BACKUP=$(mktemp)
            cp "$_PGPASS_FILE" "$_PGPASS_BACKUP"
        fi
        echo "${DB_HOST}:${DB_PORT}:*:${DB_USER}:${_pgpass_db_pass}" > "$_PGPASS_FILE"
        chmod 0600 "$_PGPASS_FILE"
        # Garante limpeza em qualquer saída (sucesso, erro ou Ctrl+C) sem sobrescrever outros traps EXIT
        restore_pgpass() {
            if [[ -n "${_PGPASS_BACKUP:-}" && -f "${_PGPASS_BACKUP}" ]]; then
                mv "${_PGPASS_BACKUP}" "${_PGPASS_FILE}"
            else
                rm -f "${_PGPASS_FILE}"
            fi
        }
        add_exit_trap restore_pgpass
    }
    run_step "Configurando autenticação segura PostgreSQL (.pgpass)" setup_pgpass

    test_db_connection() {
        if ! psql -h "${DB_HOST}" -p "${DB_PORT}" \
            -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT 1;" >/dev/null 2>&1; then
            echo -e "\n\n${VERMELHO}${NEGRITO}✖ FALHA NA CONEXÃO COM A BASE DE DADOS!${RESET}"
            exit 1
        fi
    }
    run_step "Testando conectividade com a BD (${DB_HOST}:${DB_PORT})" test_db_connection

    if [[ "$SIMULATE_MODE" == "1" ]]; then
        ZBX_SQL_SERVER="/usr/share/zabbix/sql-scripts/postgresql/server.sql.gz"
        ZBX_SQL_TSDB="/usr/share/zabbix/sql-scripts/postgresql/timescaledb/schema.sql"
    elif [[ -f "/usr/share/zabbix/sql-scripts/postgresql/server.sql.gz" ]]; then
        ZBX_SQL_SERVER="/usr/share/zabbix/sql-scripts/postgresql/server.sql.gz"
        ZBX_SQL_TSDB="/usr/share/zabbix/sql-scripts/postgresql/timescaledb/schema.sql"
    elif [[ -f "/usr/share/zabbix-sql-scripts/postgresql/server.sql.gz" ]]; then
        ZBX_SQL_SERVER="/usr/share/zabbix-sql-scripts/postgresql/server.sql.gz"
        ZBX_SQL_TSDB="/usr/share/zabbix-sql-scripts/postgresql/timescaledb.sql"
    else
        echo -e "${VERMELHO}${NEGRITO}ERRO CRÍTICO:${RESET} Ficheiro server.sql.gz não encontrado."
        echo -e "  Verifique: dpkg -L zabbix-sql-scripts"; exit 1
    fi

    import_schema() {
        # Verifica dbversion (schema completo) e não apenas hosts (pode existir parcialmente)
        local schema_completo
        schema_completo=$(psql -h "${DB_HOST}" -p "${DB_PORT}" \
            -U "${DB_USER}" -d "${DB_NAME}" \
            -tAc "SELECT to_regclass('public.dbversion');" 2>/dev/null | xargs || echo "")
        if [[ "$schema_completo" == "public.dbversion" || "$schema_completo" == "dbversion" ]]; then
            echo "Schema Zabbix completo já presente (dbversion) — passo ignorado." >> "$LOG_FILE"
            return 0
        fi
        zcat "${ZBX_SQL_SERVER}" | psql \
            -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}"
        # Confirma que o import foi completo — dbversion deve existir após import bem-sucedido
        local confirma
        confirma=$(psql -h "${DB_HOST}" -p "${DB_PORT}" \
            -U "${DB_USER}" -d "${DB_NAME}" \
            -tAc "SELECT to_regclass('public.dbversion');" 2>/dev/null | xargs || echo "")
        if [[ "$confirma" != "public.dbversion" && "$confirma" != "dbversion" ]]; then
            echo -e "\n${VERMELHO}${NEGRITO}ERRO:${RESET} Import do schema falhou ou ficou incompleto — tabela dbversion não encontrada."
            echo -e "  Verifique o log: ${LOG_FILE}"
            exit 1
        fi
    }
    run_step "Importando schema principal do Zabbix (server.sql.gz)" import_schema

    if [[ "$USE_TIMESCALE" == "1" ]]; then
        import_timescaledb() {
            [[ ! -f "${ZBX_SQL_TSDB}" ]] && { echo "ERRO: ${ZBX_SQL_TSDB} não encontrado" >&2; return 1; }
            local hyper_count
            hyper_count=$(psql -h "${DB_HOST}" -p "${DB_PORT}" \
                -U "${DB_USER}" -d "${DB_NAME}" \
                -tAc "SELECT COUNT(*) FROM timescaledb_information.hypertables;" 2>/dev/null | xargs || echo "0")
            if [[ "${hyper_count:-0}" -gt 0 ]]; then
                echo "Hipertabelas já presentes — passo ignorado." >> "$LOG_FILE"; return 0
            fi
            cat "${ZBX_SQL_TSDB}" | psql \
                -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}"
        }
        run_step "Importando schema TimescaleDB (hypertables)" import_timescaledb

        configure_tsdb_compression() {
            # Políticas de compressão automática para as hipertabelas Zabbix:
            #   histórico  → comprimir chunks com mais de 7 dias
            #   tendências → comprimir chunks com mais de 1 dia
            # if_not_exists=true: idempotente, não falha se a política já existir
            local _ok=0 _total=0
            _configure_one_tsdb_policy() {
                local table="$1" interval="$2" result
                result=$(psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
                    -v ON_ERROR_STOP=1 -qAt <<SQL 2>> "$LOG_FILE" | tee -a "$LOG_FILE" | tail -n 1 || true
CREATE TEMP TABLE zbx_tsdb_policy_result(status text) ON COMMIT DROP;
DO \$\$
BEGIN
    BEGIN
        EXECUTE format('ALTER TABLE %I SET (timescaledb.compress, timescaledb.compress_segmentby = ''itemid'')', '${table}');
    EXCEPTION WHEN OTHERS THEN
        BEGIN
            EXECUTE format('ALTER TABLE %I SET (timescaledb.enable_columnstore = true)', '${table}');
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'TimescaleDB compression/columnstore not enabled for ${table}: %', SQLERRM;
        END;
    END;
    BEGIN
        PERFORM add_compression_policy('${table}', INTERVAL '${interval}', if_not_exists => true);
        INSERT INTO zbx_tsdb_policy_result(status) VALUES ('applied');
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'TimescaleDB compression policy skipped for ${table}: %', SQLERRM;
        INSERT INTO zbx_tsdb_policy_result(status) VALUES ('skipped');
    END;
END
\$\$;
SELECT status FROM zbx_tsdb_policy_result LIMIT 1;
SQL
                )
                [[ "$result" == "applied" ]]
            }
            for _t in history history_uint history_str history_log history_text; do
                _total=$((_total+1))
                _configure_one_tsdb_policy "$_t" "7 days" && _ok=$((_ok+1)) || true
            done
            for _t in trends trends_uint; do
                _total=$((_total+1))
                _configure_one_tsdb_policy "$_t" "1 day" && _ok=$((_ok+1)) || true
            done
            if [[ "$_ok" -eq "$_total" ]]; then
                echo -e "  ${VERDE}Políticas aplicadas: ${_ok}/${_total} tabelas (histórico ≥7d | tendências ≥1d)${RESET}"
            else
                echo -e "  ${AMARELO}Políticas aplicadas: ${_ok}/${_total}; $((_total - _ok)) ignorada(s) pela versão/configuração atual do TimescaleDB.${RESET}"
            fi
        }
        run_step "Configurando compressão automática TimescaleDB (histórico 7d, tendências 1d)" \
            configure_tsdb_compression
    fi

    set_default_language() {
        psql -h "${DB_HOST}" -p "${DB_PORT}" \
            -U "${DB_USER}" -d "${DB_NAME}" \
            -c "UPDATE users SET lang='pt_BR', timezone='${TIMEZONE}' WHERE username='Admin';" \
            >> "$LOG_FILE" 2>&1 || true

    }
    run_step "Definindo idioma pt_BR e timezone ${TIMEZONE} (Admin)" set_default_language

    SV_F="/etc/zabbix/zabbix_server.conf"
    apply_server_config() {
        set_config "$SV_F" "DBHost"     "${DB_HOST}"
        set_config "$SV_F" "DBName"     "${DB_NAME}"
        set_config "$SV_F" "DBUser"     "${DB_USER}"
        set_config "$SV_F" "DBPassword" "${DB_PASS}"
        set_config "$SV_F" "DBPort"     "${DB_PORT}"
        set_config "$SV_F" "DBSocket"   ""
        set_config "$SV_F" "StartPollers"       "$T_POLL"
        set_config "$SV_F" "StartPreprocessors" "$T_PREPROC"
        set_config "$SV_F" "CacheSize"          "$T_CACHE"
        set_config "$SV_F" "ValueCacheSize"     "$T_VCACHE"
        set_config "$SV_F" "HistoryCacheSize"   "$T_HCACHE"
        set_config "$SV_F" "TrendCacheSize"     "$T_TRCACHE"
        set_config "$SV_F" "StartDBSyncers"     "$T_DBSYNC"
        if [[ "$USE_TUNING" == "1" ]]; then
            set_config "$SV_F" "HistoryIndexCacheSize"        "$T_HICACHE"
            set_config "$SV_F" "StartPollersUnreachable"      "$T_PUNREACH"
            set_config "$SV_F" "StartTrappers"                "$T_TRAP"
            set_config "$SV_F" "StartPingers"                 "$T_PING"
            set_config "$SV_F" "StartDiscoverers"             "$T_DISC"
            set_config "$SV_F" "StartHTTPPollers"             "$T_HTTP"
            set_config "$SV_F" "StartAgentPollers"            "$T_APOLL"
            set_config "$SV_F" "StartHTTPAgentPollers"        "$T_HAPOLL"
            set_config "$SV_F" "StartSNMPPollers"             "$T_SPOLL"
            set_config "$SV_F" "StartBrowserPollers"          "$T_BPOLL"
            set_config "$SV_F" "StartODBCPollers"             "$T_ODBCPOLL"
            set_config "$SV_F" "MaxConcurrentChecksPerPoller" "$T_MAXC"
            set_config "$SV_F" "UnreachablePeriod"            "$T_UNREACH"
            set_config "$SV_F" "Timeout"                      "$T_TOUT"
            set_config "$SV_F" "HousekeepingFrequency"        "$T_HK"
            set_config "$SV_F" "LogSlowQueries"               "$T_SLOWQ"
        fi
    }
    run_step "Configurando zabbix_server.conf (BD + tuning)" apply_server_config

    AG_F="/etc/zabbix/zabbix_agent2.conf"
    if [[ "$INSTALL_AGENT" == "1" && ( -f "$AG_F" || "$SIMULATE_MODE" == "1" ) ]]; then
        apply_agent_config() {
            set_config "$AG_F" "Server"       "$AG_SERVER"
            set_config "$AG_F" "ServerActive" "$AG_SERVER_ACTIVE"
            set_config "$AG_F" "Hostname"     "$AG_HOSTNAME"
            [[ "$AG_ALLOWKEY" == "1" ]] && set_config "$AG_F" "AllowKey" "system.run[*]"
        }
        run_step "Configurando Zabbix Agent 2" apply_agent_config
    fi

    if [[ "$USE_PSK" == "1" && "$INSTALL_AGENT" == "1" ]]; then
        if [[ "$SIMULATE_MODE" == "1" ]]; then
            PSK_AGENT_KEY="<gerado-na-instalação-real>"
        else
            PSK_AGENT_KEY=$(openssl rand -hex 32)
        fi
        apply_psk_agent() {
            echo "$PSK_AGENT_KEY" > /etc/zabbix/zabbix_agent2.psk
            chown zabbix:zabbix /etc/zabbix/zabbix_agent2.psk
            chmod 600 /etc/zabbix/zabbix_agent2.psk
            set_config "$AG_F" "TLSAccept"      "psk"
            set_config "$AG_F" "TLSConnect"     "psk"
            set_config "$AG_F" "TLSPSKIdentity" "$PSK_AGENT_ID"
            set_config "$AG_F" "TLSPSKFile"     "/etc/zabbix/zabbix_agent2.psk"
        }
        run_step "Gerando e aplicando chave PSK do Agente" apply_psk_agent
    fi

    configure_nginx() {
        local NX_F="/etc/zabbix/nginx.conf"
        if [[ "$USE_HTTPS" == "1" ]]; then
            sed -i "s|#\s*listen\s\+[0-9]\+;|        listen          ${NGINX_PORT} ssl;|g" "$NX_F"
            sed -i "s|^\s*listen\s\+[0-9]\+;|        listen          ${NGINX_PORT} ssl;|g" "$NX_F"
            SSL_CERT_VAR="${SSL_CERT}" SSL_KEY_VAR="${SSL_KEY}" NX_F_VAR="${NX_F}" python3 << 'PYEOF'
import re, os
nxf=os.environ['NX_F_VAR']; cert=os.environ['SSL_CERT_VAR']; key=os.environ['SSL_KEY_VAR']
with open(nxf) as f: c=f.read()
if 'ssl_certificate' not in c:
    blk=('\n        ssl_certificate     '+cert+';'+'\n        ssl_certificate_key '+key+';'+
         '\n        ssl_protocols       TLSv1.2 TLSv1.3;'+
         '\n        ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;'+
         '\n        ssl_prefer_server_ciphers on;'+'\n        ssl_session_cache   shared:SSL:10m;'+'\n        ssl_session_timeout 10m;')
    c=re.sub(r'([ \t]*listen[ \t]+[0-9]+[ \t]+ssl;)',r'\1'+blk,c)
    with open(nxf,'w') as f: f.write(c)
PYEOF
            if [[ "$USE_HTTP_REDIRECT" == "1" ]]; then
                mkdir -p /etc/nginx/conf.d
                cat > /etc/nginx/conf.d/zabbix-http-redirect.conf << EOF
server {
    listen 80;
    server_name ${SERVER_NAME};
    return 301 https://\$host\$request_uri;
}
EOF
            fi
        else
            sed -i "s|#\s*listen\s\+[0-9]\+;|        listen          ${NGINX_PORT};|g" "$NX_F"
            sed -i "s|^\s*listen\s\+[0-9]\+;|        listen          ${NGINX_PORT};|g" "$NX_F"
        fi
        sed -i "s|#\s*server_name\s\+.*;|        server_name     ${SERVER_NAME};|g" "$NX_F"
        sed -i "s|^\s*server_name\s\+.*;|        server_name     ${SERVER_NAME};|g" "$NX_F"
        sed -i "s|fastcgi_pass\s\+unix:/var/run/php/php[0-9.]*-fpm\.sock|fastcgi_pass    unix:/var/run/php/php${PHP_VER}-fpm.sock|g" "$NX_F"
        rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
        mkdir -p /etc/nginx/conf.d
        # ln -sf sempre: zabbix-nginx-conf 7.4 já cria este ficheiro no pacote.
        # O padrão anterior "[[ ! -e ]] && ln" falhava com set -e quando o
        # ficheiro existia (condição devolve 1 → set -e abortava a função).
        ln -sf /etc/zabbix/nginx.conf /etc/nginx/conf.d/zabbix.conf
    }
    run_step "Configurando Nginx (porta ${NGINX_PORT}$([[ "$USE_HTTPS" == "1" ]] && echo " SSL" || echo ""), server_name ${SERVER_NAME})" configure_nginx

    configure_phpfpm() {
        local PHP_FPM_CONF="/etc/zabbix/php-fpm.conf"

        # Corrigir socket para a versão de PHP instalada
        sed -i "s|listen = /var/run/php/php[0-9.]*-fpm\.sock|listen = /var/run/php/php${PHP_VER}-fpm.sock|g" \
            "$PHP_FPM_CONF" 2>/dev/null || true

        # Timezone
        if grep -qE "^;?\s*php_value\[date\.timezone\]" "$PHP_FPM_CONF" 2>/dev/null; then
            sed -i "s|^;*\s*php_value\[date\.timezone\].*|php_value[date.timezone] = ${TIMEZONE}|g" "$PHP_FPM_CONF"
        else
            echo "php_value[date.timezone] = ${TIMEZONE}" >> "$PHP_FPM_CONF"
        fi

        # Memória: 256M (padrão PHP 128M é insuficiente para Zabbix)
        sed -i "s|php_value\[memory_limit\].*|php_value[memory_limit] = 256M|g" \
            "$PHP_FPM_CONF" 2>/dev/null || \
            echo "php_value[memory_limit] = 256M" >> "$PHP_FPM_CONF"

        # Tempo máximo de execução: 300s (importações pesadas podem demorar)
        sed -i "s|php_value\[max_execution_time\].*|php_value[max_execution_time] = 300|g" \
            "$PHP_FPM_CONF" 2>/dev/null || \
            echo "php_value[max_execution_time] = 300" >> "$PHP_FPM_CONF"

        # Tempo máximo de leitura do input
        sed -i "s|php_value\[max_input_time\].*|php_value[max_input_time] = 300|g" \
            "$PHP_FPM_CONF" 2>/dev/null || \
            echo "php_value[max_input_time] = 300" >> "$PHP_FPM_CONF"

        # Upload: valor escolhido pelo utilizador (templates, iconsets, mapas)
        sed -i "s|php_value\[upload_max_filesize\].*|php_value[upload_max_filesize] = ${PHP_UPLOAD_SIZE}|g" \
            "$PHP_FPM_CONF" 2>/dev/null || \
            echo "php_value[upload_max_filesize] = ${PHP_UPLOAD_SIZE}" >> "$PHP_FPM_CONF"

        # post_max_size deve ser >= upload_max_filesize (usar o mesmo valor é seguro)
        sed -i "s|php_value\[post_max_size\].*|php_value[post_max_size] = ${PHP_UPLOAD_SIZE}|g" \
            "$PHP_FPM_CONF" 2>/dev/null || \
            echo "php_value[post_max_size] = ${PHP_UPLOAD_SIZE}" >> "$PHP_FPM_CONF"

        # pm.max_children: calculado com base na RAM disponível (~50MB por worker PHP)
        local php_workers=$(( RAM_MB / 50 ))
        (( php_workers <  10 )) && php_workers=10
        (( php_workers > 100 )) && php_workers=100
        sed -i "s|^pm\.max_children\s*=.*|pm.max_children = ${php_workers}|g" \
            "$PHP_FPM_CONF" 2>/dev/null || true

        # pm.max_requests: limita vazamentos de memória reiniciando workers periodicamente
        sed -i "s|^pm\.max_requests\s*=.*|pm.max_requests = 200|g" \
            "$PHP_FPM_CONF" 2>/dev/null || \
            echo "pm.max_requests = 200" >> "$PHP_FPM_CONF"
    }
    run_step "Configurando PHP ${PHP_VER}-FPM (timezone, memória, upload ${PHP_UPLOAD_SIZE}, workers)" configure_phpfpm

    preconfigure_frontend() {
        mkdir -p /etc/zabbix/web
        local DB_NAME_PHP DB_USER_PHP DB_PASS_PHP DB_HOST_PHP DB_PORT_PHP SERVER_NAME_PHP
        DB_NAME_PHP=$(php_single_quote_escape "$DB_NAME")
        DB_USER_PHP=$(php_single_quote_escape "$DB_USER")
        DB_PASS_PHP=$(php_single_quote_escape "$DB_PASS")
        DB_HOST_PHP=$(php_single_quote_escape "$DB_HOST")
        DB_PORT_PHP=$(php_single_quote_escape "$DB_PORT")
        SERVER_NAME_PHP=$(php_single_quote_escape "$SERVER_NAME")
        cat > /etc/zabbix/web/zabbix.conf.php << ZCONF
<?php
// Zabbix GUI configuration file — gerado por AUTOMACAO-ZBX-UNIFIED ${INSTALLER_LABEL}
global \$DB;
\$DB['TYPE']='POSTGRESQL'; \$DB['SERVER']='${DB_HOST_PHP}'; \$DB['PORT']='${DB_PORT_PHP}';
\$DB['DATABASE']='${DB_NAME_PHP}'; \$DB['USER']='${DB_USER_PHP}'; \$DB['PASSWORD']='${DB_PASS_PHP}';
\$DB['SCHEMA']=''; \$DB['ENCRYPTION']=false; \$DB['KEY_FILE']=''; \$DB['CERT_FILE']='';
\$DB['CA_FILE']=''; \$DB['VERIFY_HOST']=false; \$DB['CIPHER_LIST']='';
\$DB['VAULT_URL']=''; \$DB['VAULT_DB_PATH']=''; \$DB['VAULT_TOKEN']=''; \$DB['DOUBLE_IEEE754']=true;
\$ZBX_SERVER='localhost'; \$ZBX_SERVER_PORT='10051'; \$ZBX_SERVER_NAME='${SERVER_NAME_PHP}';
\$IMAGE_FORMAT_DEFAULT=IMAGE_FORMAT_PNG;
ZCONF
        chown www-data:www-data /etc/zabbix/web/zabbix.conf.php 2>/dev/null || \
            chown nginx:nginx /etc/zabbix/web/zabbix.conf.php 2>/dev/null || true
        chmod 640 /etc/zabbix/web/zabbix.conf.php
    }
    run_step "Pré-configurando frontend Zabbix (eliminando wizard do browser)" preconfigure_frontend


    start_services() {
        systemctl enable --now zabbix-server nginx "php${PHP_VER}-fpm"
        [[ "$INSTALL_AGENT" == "1" ]] && systemctl enable --now zabbix-agent2
        systemctl reload nginx 2>/dev/null || true
    }
    run_step "Ativando serviços (zabbix-server, nginx, php${PHP_VER}-fpm)" start_services
    wait_for_service_active zabbix-server 30
    wait_for_service_active nginx 30
    wait_for_service_active "php${PHP_VER}-fpm" 30
    [[ "$INSTALL_AGENT" == "1" ]] && wait_for_service_active zabbix-agent2 30

    create_zabbix_dirs() {
        # Diretórios para scripts externos e de alertas — necessários para
        # External Check items e Media Type scripts personalizados
        mkdir -p /usr/lib/zabbix/externalscripts /usr/lib/zabbix/alertscripts
        chown -R zabbix:zabbix /usr/lib/zabbix/ 2>/dev/null || true
        chmod 755 /usr/lib/zabbix/externalscripts /usr/lib/zabbix/alertscripts
    }
    run_step "Criando diretorias de scripts Zabbix (externalscripts + alertscripts)" create_zabbix_dirs

    configure_logrotate() {
        # Rotação semanal dos logs do Zabbix — evita crescimento ilimitado
        cat > /etc/logrotate.d/zabbix << 'LOGEOF'
/var/log/zabbix/*.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 640 zabbix zabbix
    sharedscripts
    postrotate
        [ -f /run/zabbix/zabbix_server.pid ] && \
            kill -HUP $(cat /run/zabbix/zabbix_server.pid) 2>/dev/null || true
        [ -f /run/zabbix/zabbix_agent2.pid ] && \
            kill -HUP $(cat /run/zabbix/zabbix_agent2.pid) 2>/dev/null || true
    endscript
}
LOGEOF
    }
    run_step "Configurando logrotate para /var/log/zabbix/ (semanal, 12 semanas)" configure_logrotate

    hold_packages_server() {
        # Fixa versões para evitar atualização acidental via apt upgrade
        apt-mark hold zabbix-server-pgsql zabbix-frontend-php zabbix-nginx-conf zabbix-sql-scripts 2>/dev/null || true
        [[ "$INSTALL_AGENT" == "1" ]] && apt-mark hold zabbix-agent2 2>/dev/null || true
        echo -e "  ${VERDE}Versões fixadas. Use 'apt-mark unhold <pacote>' antes de atualizar manualmente.${RESET}"
    }
    run_step "Fixando versões instaladas (apt-mark hold)" hold_packages_server

    [[ "$SIMULATE_MODE" == "1" ]] && finish_simulation
    post_validate_installation "server"
    if [[ "$_CRITICAL_SERVICES_OK" == "1" ]]; then
        CURRENT_STEP=$TOTAL_STEPS; draw_progress "Instalação Perfeita! ✔"; printf "\n"
    else
        CURRENT_STEP=$TOTAL_STEPS; draw_progress "Instalação com Avisos ⚠"; printf "\n"
    fi

    # Certificado
    clear
    start_certificate_export "server"
    [[ "$_CRITICAL_SERVICES_OK" != "1" ]] && \
        echo -e "${VERMELHO}${NEGRITO}⚠ UM OU MAIS SERVIÇOS CRÍTICOS NÃO ESTÃO ATIVOS. Verifique acima e execute: journalctl -xe --no-pager${RESET}\n"
    HOST_IP=$(hostname -I | awk '{print $1}')
    SV_RAM=$(free -m | awk '/^Mem/{print $2}'); SV_CORES=$(nproc)
    echo -e "${VERDE}${NEGRITO}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${VERDE}${NEGRITO}║           CERTIFICADO — CAMADA DE SERVIDOR               ║${RESET}"
    echo -e "${VERDE}${NEGRITO}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo -e "\n${CIANO}${NEGRITO}▸ SISTEMA OPERACIONAL + HARDWARE${RESET}"
    command -v lsb_release >/dev/null 2>&1 && \
        printf "  %-34s %s\n" "Distribuição:" "$(lsb_release -ds)" || \
        printf "  %-34s %s\n" "Sistema:" "$OS_DISPLAY"
    printf "  %-34s %s\n" "Kernel:" "$(uname -r)"
    printf "  %-34s %s\n" "RAM total:" "${SV_RAM} MB"
    printf "  %-34s %s\n" "Núcleos CPU:" "${SV_CORES}"
    echo -e "\n${CIANO}${NEGRITO}▸ VERSÕES DOS PACOTES INSTALADOS${RESET}"
    printf "  %-34s %s\n" "zabbix-server-pgsql:" "$(dpkg -l zabbix-server-pgsql 2>/dev/null | awk '/^ii/{print $3}' | head -1 || echo N/D)"
    printf "  %-34s %s\n" "nginx (binário):" "$(nginx -v 2>&1 | head -1 || echo N/D)"
    printf "  %-34s %s\n" "PHP ${PHP_VER} (binário):" "$(php${PHP_VER} --version 2>/dev/null | head -1 | cut -d' ' -f1-2 || echo N/D)"
    printf "  %-34s %s\n" "postgresql-client-${PG_VER}:" "$(dpkg -l postgresql-client-${PG_VER} 2>/dev/null | awk '/^ii/{print $3}' | head -1 || echo N/D)"
    [[ "$INSTALL_AGENT" == "1" ]] && printf "  %-34s %s\n" "zabbix-agent2:" "$(dpkg -l zabbix-agent2 2>/dev/null | awk '/^ii/{print $3}' | head -1 || echo N/D)"
    echo -e "\n${CIANO}${NEGRITO}▸ ACESSO AO FRONTEND${RESET}"
    [[ "$USE_HTTPS" == "1" ]] && printf "  %-34s ${VERDE}%s${RESET}\n" "URL de Acesso:" "https://${HOST_IP}:${NGINX_PORT}" || \
                                  printf "  %-34s ${VERDE}%s${RESET}\n" "URL de Acesso:" "http://${HOST_IP}:${NGINX_PORT}"
    printf "  %-34s %s\n"           "Utilizador padrão:" "Admin"
    printf "  %-34s ${AMARELO}%s${RESET}\n" "Senha padrão:" "zabbix  ← ALTERE NO PRIMEIRO LOGIN!"
    FRONTEND_URL="http://${HOST_IP}:${NGINX_PORT}"
    [[ "$USE_HTTPS" == "1" ]] && FRONTEND_URL="https://${HOST_IP}:${NGINX_PORT}"
    echo -e "\n${CIANO}${NEGRITO}▸ COPIAR PARA O OPERADOR${RESET}"
    echo "  ------------------------------------------------------------"
    echo "  URL=${FRONTEND_URL}"
    echo "  USER=Admin"
    echo "  PASSWORD=zabbix"
    echo "  ACTION=Alterar senha no primeiro login"
    echo "  ------------------------------------------------------------"
    echo -e "\n${CIANO}${NEGRITO}▸ CREDENCIAIS DA BASE EM USO PELO SERVER${RESET}"
    echo "  ------------------------------------------------------------"
    printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "DBHost:"     "$DB_HOST"
    printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "DBPort:"     "$DB_PORT"
    printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "DBName:"     "$DB_NAME"
    printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "DBUser:"     "$DB_USER"
    printf "  ${NEGRITO}%-32s${RESET} ${VERMELHO}%s${RESET}\n" "DBPassword:" "$DB_PASS"
    echo "  ------------------------------------------------------------"
    echo -e "\n${CIANO}${NEGRITO}▸ ESTADO DOS SERVIÇOS${RESET}"
    for svc in zabbix-server nginx "php${PHP_VER}-fpm"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            printf "  %-34s ${VERDE}%s${RESET}\n" "${svc}:" "ATIVO ✔"
        else
            printf "  %-34s ${VERMELHO}%s${RESET}\n" "${svc}:" "FALHOU ✖"
            echo -e "  ${AMARELO}Diagnóstico:${RESET} journalctl -u ${svc} -n 30 --no-pager"
        fi
    done
    [[ "$INSTALL_AGENT" == "1" ]] && systemctl is-active --quiet zabbix-agent2 2>/dev/null && \
        printf "  %-34s ${VERDE}%s${RESET}\n" "zabbix-agent2:" "ATIVO ✔"
    echo -e "\n${CIANO}${NEGRITO}▸ AUDITORIA: LINHAS ATIVAS NO SERVER.CONF${RESET}"
    timeout 10 awk '$0 !~ /^[[:space:]]*#/ && $0 !~ /^[[:space:]]*$/ { print "  " $0 }' "$SV_F" 2>/dev/null || true
    if [[ "$USE_PSK" == "1" && "$INSTALL_AGENT" == "1" ]]; then
        echo -e "\n${AMARELO}${NEGRITO}▸ CREDENCIAIS PSK — AGENT 2${RESET}"
        echo -e "  ------------------------------------------------------------"
        printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "IP desta máquina:"  "$HOST_IP"
        printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "Hostname Agente:"   "$AG_HOSTNAME"
        printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "PSK Identity:"      "$PSK_AGENT_ID"
        printf "  ${NEGRITO}%-32s${RESET} ${VERMELHO}%s${RESET}\n" "PSK Secret Key:" "$PSK_AGENT_KEY"
        echo -e "  ------------------------------------------------------------"
    fi
    print_install_warnings
    echo -e "\n${CIANO}${NEGRITO}▸ EXPORTAÇÃO JSON${RESET}"
    write_install_summary_json "server"
    print_support_commands "server"
    echo -e "\n${NEGRITO}Log completo:${RESET} $LOG_FILE\n"
    ;;


# ══════════════════════════════════════════════════════════════════════════════
# COMPONENTE 3 — PROXY (Zabbix Proxy + Agent 2) — Proxy v10.7
# ══════════════════════════════════════════════════════════════════════════════
proxy)
    component_supported_or_die "proxy"

    if [[ "$SIMULATE_MODE" == "1" ]]; then
        LOG_FILE=""
    else
        init_install_log "proxy" "/var/log/zabbix_proxy_install_$(date +%Y%m%d_%H%M%S).log"
    fi
    log_msg "INFO" "Log iniciado para componente Proxy em ${LOG_FILE}"

    # Variáveis de estado
    T_UNREACH="45"; T_PING="5"; T_DISC="5"; T_HTTP="1"
    T_PUNREACH="5"; T_TRAP="5"; T_APOLL="1"; T_HAPOLL="1"
    T_SPOLL="10"; T_BPOLL="1"; T_ODBCPOLL="1"; T_MAXC="1000"; T_CFG_FREQ="10"; T_SND_FREQ="1"
    T_OFFLINE="1"; T_BUF_MOD="hybrid"; T_BUF_SZ="16M"; T_BUF_AGE="0"
    PROXY_PERF_PROFILE=""
    CLEAN_INSTALL=0; UPDATE_SYSTEM=0; ZBX_VERSION="7.0"; PROXY_MODE="0"
    PROXY_TIMEZONE="${SYS_TIMEZONE:-America/Sao_Paulo}"

    clamp_int() {
        local value="$1" min="$2" max="$3"
        (( value < min )) && value="$min"
        (( value > max )) && value="$max"
        echo "$value"
    }
    calc_proxy_auto_performance() {
        if (( RAM_MB < 4096 )); then
            PROXY_PERF_PROFILE="mínimo"
            T_CACHE="64M";  T_HCACHE="64M";  T_HICACHE="16M"; T_DBSYNC="2"
            T_POLL=$(clamp_int $(( CPU_CORES * 2 )) 4 10)
            T_PREPROC=$(clamp_int $(( CPU_CORES * 2 )) 4 8)
        elif (( RAM_MB < 8192 )); then
            PROXY_PERF_PROFILE="baixo"
            T_CACHE="128M"; T_HCACHE="128M"; T_HICACHE="32M"; T_DBSYNC="2"
            T_POLL=$(clamp_int $(( CPU_CORES * 3 )) 10 20)
            T_PREPROC=$(clamp_int $(( CPU_CORES * 3 )) 8 16)
        elif (( RAM_MB <= 16384 )); then
            PROXY_PERF_PROFILE="médio"
            T_CACHE="256M"; T_HCACHE="256M"; T_HICACHE="64M"; T_DBSYNC="4"
            T_POLL=$(clamp_int $(( CPU_CORES * 4 )) 20 40)
            T_PREPROC=$(clamp_int $(( CPU_CORES * 4 )) 16 32)
        else
            PROXY_PERF_PROFILE="alto"
            T_CACHE="512M"; T_HCACHE="512M"; T_HICACHE="128M"; T_DBSYNC="8"
            T_POLL=$(clamp_int $(( CPU_CORES * 5 )) 40 80)
            T_PREPROC=$(clamp_int $(( CPU_CORES * 5 )) 32 64)
        fi
    }
    calc_proxy_auto_performance
    ZBX_SERVER=""; ZBX_HOSTNAME=""; INSTALL_AGENT="0"; ENABLE_REMOTE="0"
    USE_PSK="0"; USE_TUNING="0"; PSK_PROXY_ID=""; PSK_AGENT_ID=""
    PSK_PROXY_KEY=""; PSK_AGENT_KEY=""
    AG_SERVER="127.0.0.1"; AG_SERVER_ACTIVE="127.0.0.1"; AG_HOSTNAME=""; AG_ALLOWKEY="0"

    # Banner Proxy
    clear
    echo -e "${VERMELHO}${NEGRITO}"
    cat << "EOF"
██████╗ ██████╗  ██████╗ ██╗  ██╗██╗   ██╗
██╔══██╗██╔══██╗██╔═══██╗╚██╗██╔╝╚██╗ ██╔╝
██████╔╝██████╔╝██║   ██║ ╚███╔╝  ╚████╔╝
██╔═══╝ ██╔══██╗██║   ██║ ██╔██╗   ╚██╔╝
██║     ██║  ██║╚██████╔╝██╔╝ ██╗   ██║
╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝   ╚═╝
EOF
    echo -e "        & AGENT 2 — Instalador Enterprise v10.8${RESET}"
    echo -e "        ${VERDE}Sistema detetado: ${OS_DISPLAY} ✔${RESET}"
    echo -e "        ${CIANO}Hardware: ${RAM_MB} MB RAM | ${CPU_CORES} núcleos | Perfil de performance: ${NEGRITO}${PROXY_PERF_PROFILE}${RESET}\n"

    # Questionário
    m_clean() {
        local Z_LIST
        Z_LIST=$(dpkg -l 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^ii|^rc/ && $2 ~ /zabbix/ {print $2}' || true)
        if [[ -n "$Z_LIST" ]]; then
            echo -e "\n${VERMELHO}${NEGRITO}⚠  Instalação anterior detetada:${RESET}"
            echo -e "${VERMELHO}   $(echo "$Z_LIST" | tr '\n' ' ')${RESET}"
            echo -e "${AMARELO}   Será removida completamente antes de instalar.${RESET}"
            CLEAN_INSTALL=1
        else
            CLEAN_INSTALL=0
        fi
    }

    m_update() {
        echo -e "\n${CIANO}${NEGRITO}>>> ATUALIZAÇÃO E DEPENDÊNCIAS DO SISTEMA <<<${RESET}"
        echo -e "  Recomenda-se atualizar o SO e instalar pacotes auxiliares (snmp, fping, nmap, jq)."
        ask_yes_no "Fazer upgrade seguro dos pacotes e instalar ferramentas de rede?" UPDATE_SYSTEM
    }

    m_version() {
        echo -e "\n${CIANO}${NEGRITO}>>> VERSÃO DO ZABBIX <<<${RESET}"
        echo -e "   1) ${NEGRITO}7.0 LTS${RESET}     — Suporte Longo Prazo"
        echo -e "   2) ${NEGRITO}7.4 Current${RESET}  — Versão actual"
        echo -e "   3) ${NEGRITO}8.0 LTS${RESET}     — Nova versão LTS (quando publicada para este sistema)"
        while true; do
            read -rp "  Escolha (1, 2 ou 3): " v_opt
            case "$v_opt" in
                1) ZBX_VERSION="7.0"; break ;;
                2) ZBX_VERSION="7.4"; break ;;
                3) ZBX_VERSION="8.0"; break ;;
                *) echo -e "  ${VERMELHO}Opção inválida.${RESET}" ;;
            esac
        done
    }

    m_proxy_mode() {
        echo -e "\n${CIANO}${NEGRITO}>>> MODO DE OPERAÇÃO DO PROXY <<<${RESET}"
        echo -e "${AMARELO}ProxyMode${RESET} (Padrão Zabbix: 0)"
        echo -e "   0 - Proxy no modo ATIVO (O Proxy conecta ao Server. Mais Recomendado)"
        echo -e "   1 - Proxy no modo PASSIVO (O Server conecta ao Proxy para buscar dados)"
        while true; do
            read -rp "   Valor Recomendado [0]: " pm_opt; pm_opt=${pm_opt:-0}
            case "$pm_opt" in
                0) PROXY_MODE="0"; break ;;
                1) PROXY_MODE="1"; break ;;
                *) echo -e "   ${VERMELHO}Opção inválida. Escolha 0 ou 1.${RESET}" ;;
            esac
        done
    }

    m_proxy_net() {
        echo -e "\n${CIANO}${NEGRITO}>>> IDENTIFICAÇÃO E CONEXÃO DO PROXY <<<${RESET}"
        echo -e "\n${AMARELO}Server${RESET} (Destino ou Origem do Zabbix Server. Obrigatório)"
        echo -e "   Se ProxyMode=0 (Ativo): IP/DNS ou cluster (nós separados por ';')"
        echo -e "   Se ProxyMode=1 (Passivo): Lista de IPs autorizados (separados por ',')"
        while true; do
            read -rp "   Preencher: " ZBX_SERVER
            [[ -n "$ZBX_SERVER" ]] && break
            echo -e "   ${VERMELHO}Campo obrigatório.${RESET}"
        done
        validate_zabbix_identity "$ZBX_SERVER" "Server do Proxy"
        echo -e "\n${AMARELO}Hostname${RESET} (Obrigatório — deve ser idêntico ao configurado no Server)"
        while true; do
            read -rp "   Preencher: " ZBX_HOSTNAME
            [[ -n "$ZBX_HOSTNAME" ]] && break
            echo -e "   ${VERMELHO}Campo obrigatório.${RESET}"
        done
        validate_zabbix_identity "$ZBX_HOSTNAME" "Hostname do Proxy"
    }

    m_agent() {
        echo -e "\n${CIANO}${NEGRITO}>>> ZABBIX AGENT 2 <<<${RESET}"
        ask_yes_no "Instalar o Zabbix Agent 2 neste host?" INSTALL_AGENT
        if [[ "$INSTALL_AGENT" == "1" ]]; then
            echo -e "\n${AMARELO}Server${RESET} (Escuta Passiva. Padrão Zabbix: 127.0.0.1)"
            read -rp "   Valor Recomendado [127.0.0.1]: " AG_SERVER; AG_SERVER=${AG_SERVER:-127.0.0.1}
            validate_zabbix_identity "$AG_SERVER" "Server do Agente"
            echo -e "\n${AMARELO}ServerActive${RESET} (Envio Ativo. Padrão Zabbix: 127.0.0.1)"
            read -rp "   Valor Recomendado [127.0.0.1]: " AG_SERVER_ACTIVE; AG_SERVER_ACTIVE=${AG_SERVER_ACTIVE:-127.0.0.1}
            validate_zabbix_identity "$AG_SERVER_ACTIVE" "ServerActive do Agente"
            echo -e "\n${AMARELO}Hostname${RESET} (Identificação do Agente)"
            echo -e "   Geralmente mantemos igual ao nome do Proxy ($ZBX_HOSTNAME)."
            local AG_SAME
            ask_yes_no "   Usar o Hostname '$ZBX_HOSTNAME'?" AG_SAME
            if [[ "$AG_SAME" == "0" ]]; then
                while true; do
                    read -rp "   Preencher: " AG_HOSTNAME
                    [[ -n "$AG_HOSTNAME" ]] && break
                    echo -e "   ${VERMELHO}Campo obrigatório.${RESET}"
                done
            else
                AG_HOSTNAME="$ZBX_HOSTNAME"
            fi
            validate_zabbix_identity "$AG_HOSTNAME" "Hostname do Agente"
            echo -e "${VERMELHO}${NEGRITO}⚠ ATENÇÃO:${RESET} AllowKey=system.run[*] permite execução remota de comandos pelo Zabbix."
            echo -e "${AMARELO}Use apenas em ambiente controlado e preferencialmente com PSK/TLS.${RESET}"
            ask_yes_no "   Habilitar AllowKey=system.run[*] no Agente?" AG_ALLOWKEY
        fi
    }

    m_security() {
        echo -e "\n${CIANO}${NEGRITO}>>> SEGURANÇA E CRIPTOGRAFIA <<<${RESET}"
        echo -e "\n${AMARELO}EnableRemoteCommands${RESET} (Proxy)"
        ask_yes_no "   Habilitar EnableRemoteCommands no Proxy?" ENABLE_REMOTE
        echo -e "\n${AMARELO}TLSConnect / TLSAccept${RESET} (PSK)"
        ask_yes_no "   Configurar criptografia com chaves PSK DISTINTAS?" USE_PSK
        if [[ "$USE_PSK" == "1" ]]; then
            while true; do
                read -rp "   Identidade PSK do Proxy (ex: PROXY-01): " PSK_PROXY_ID
                [[ -n "$PSK_PROXY_ID" ]] && break
                echo -e "   ${VERMELHO}Campo obrigatório.${RESET}"
            done
            validate_zabbix_identity "$PSK_PROXY_ID" "PSK Identity do Proxy"
            if [[ "$INSTALL_AGENT" == "1" ]]; then
                while true; do
                    while true; do
                        read -rp "   Identidade PSK do Agente (ex: AGENT-01): " PSK_AGENT_ID
                        [[ -n "$PSK_AGENT_ID" ]] && break
                        echo -e "   ${VERMELHO}Campo obrigatório.${RESET}"
                    done
                    validate_zabbix_identity "$PSK_AGENT_ID" "PSK Identity do Agente"
                    if [[ "$PSK_AGENT_ID" == "$PSK_PROXY_ID" ]]; then
                        echo -e "   ${VERMELHO}${NEGRITO}✖ A identidade PSK do Agente não pode ser igual à do Proxy (\"${PSK_PROXY_ID}\").${RESET}"
                        echo -e "   ${AMARELO}Escolha um nome diferente (ex: AGENT-01 vs PROXY-01).${RESET}"
                    else
                        break
                    fi
                done
            fi
        fi
    }

    m_tuning() {
        ask_yes_no "Aplicar Tuning Avançado de Performance (25 Parâmetros)?" USE_TUNING
        if [[ "$USE_TUNING" == "1" ]]; then
            echo -e "\n${CIANO}${NEGRITO}>>> ASSISTENTE EXPLICATIVO DE PERFORMANCE <<<${RESET}"
            echo -e "Prima [ENTER] sem escrever nada para usar o valor recomendado entre [colchetes].\n"

            echo -e "${AMARELO}1. CacheSize${RESET} (Limites: 128K-64G | Padrão Zabbix: 32M)"
            echo -e "   Tamanho da memória partilhada para manter configurações de hosts e itens."
            read -rp "   Valor Recomendado [${T_CACHE}]: " _v; T_CACHE=${_v:-$T_CACHE}

            echo -e "\n${AMARELO}2. StartDBSyncers${RESET} (Limites: 1-100 | Padrão Zabbix: 4)"
            echo -e "   Número de instâncias que sincronizam ativamente a memória com a Base de Dados."
            read -rp "   Valor Recomendado [${T_DBSYNC}]: " _v; T_DBSYNC=${_v:-$T_DBSYNC}

            echo -e "\n${AMARELO}3. HistoryCacheSize${RESET} (Limites: 128K-16G | Padrão Zabbix: 16M)"
            echo -e "   Tamanho da memória partilhada para guardar métricas recentes antes de escrever no disco."
            read -rp "   Valor Recomendado [${T_HCACHE}]: " _v; T_HCACHE=${_v:-$T_HCACHE}

            echo -e "\n${AMARELO}4. HistoryIndexCacheSize${RESET} (Limites: 128K-16G | Padrão Zabbix: 4M)"
            echo -e "   Memória partilhada dedicada à indexação do histórico, que agiliza muito a procura."
            read -rp "   Valor Recomendado [${T_HICACHE}]: " _v; T_HICACHE=${_v:-$T_HICACHE}

            echo -e "\n${AMARELO}5. Timeout${RESET} (Limites: 1-30 | Padrão Zabbix: 3)"
            echo -e "   Tempo máximo em segundos que o Proxy espera por respostas de rede ou agentes."
            read -rp "   Valor Recomendado [4]: " T_TOUT; T_TOUT=${T_TOUT:-4}

            echo -e "\n${AMARELO}6. UnreachablePeriod${RESET} (Limites: 1-3600 | Padrão Zabbix: 45)"
            echo -e "   Segundos sem resposta até o Zabbix considerar que um host está incontactável."
            read -rp "   Valor Recomendado [45]: " T_UNREACH; T_UNREACH=${T_UNREACH:-45}

            echo -e "\n${AMARELO}7. StartPingers${RESET} (Limites: 0-1000 | Padrão Zabbix: 1)"
            echo -e "   Número de processos em background que efetuam exclusivamente testes de ICMP (Ping)."
            read -rp "   Valor Recomendado [5]: " T_PING; T_PING=${T_PING:-5}

            echo -e "\n${AMARELO}8. StartDiscoverers${RESET} (Limites: 0-1000 | Padrão Zabbix: 5)"
            echo -e "   Número de processos dedicados à pesquisa (Discovery) na rede."
            read -rp "   Valor Recomendado [5]: " T_DISC; T_DISC=${T_DISC:-5}

            echo -e "\n${AMARELO}9. StartHTTPPollers${RESET} (Limites: 0-1000 | Padrão Zabbix: 1)"
            echo -e "   Número de processos dedicados a recolhas e testes de cenários Web HTTP."
            read -rp "   Valor Recomendado [1]: " T_HTTP; T_HTTP=${T_HTTP:-1}

            echo -e "\n${AMARELO}10. StartPreprocessors${RESET} (Limites: 1-1000 | Padrão Zabbix: 16)"
            echo -e "   Threads focadas em converter, calcular e processar dados brutos antes da cache."
            read -rp "   Valor Recomendado [${T_PREPROC}]: " _v; T_PREPROC=${_v:-$T_PREPROC}

            echo -e "\n${AMARELO}11. StartPollersUnreachable${RESET} (Limites: 0-1000 | Padrão Zabbix: 1)"
            echo -e "   Coletores passivos destacados só para equipamentos em estado 'caído', evitando atrasar os saudáveis."
            read -rp "   Valor Recomendado [5]: " T_PUNREACH; T_PUNREACH=${T_PUNREACH:-5}

            echo -e "\n${AMARELO}12. StartTrappers${RESET} (Limites: 0-1000 | Padrão Zabbix: 5)"
            echo -e "   Processos dedicados a receber fluxos de Agentes Ativos e do Zabbix Sender."
            read -rp "   Valor Recomendado [5]: " T_TRAP; T_TRAP=${T_TRAP:-5}

            echo -e "\n${AMARELO}13. StartPollers${RESET} (Limites: 0-1000 | Padrão Zabbix: 5)"
            echo -e "   Coletores passivos genéricos (adequados para Zabbix Agent 1 e scripts comuns)."
            read -rp "   Valor Recomendado [${T_POLL}]: " _v; T_POLL=${_v:-$T_POLL}

            echo -e "\n${AMARELO}14. StartAgentPollers${RESET} (Limites: 0-1000 | Padrão Zabbix: 1)"
            echo -e "   Coletores assíncronos modernos de alta concorrência para o Zabbix Agent."
            read -rp "   Valor Recomendado [1]: " T_APOLL; T_APOLL=${T_APOLL:-1}

            echo -e "\n${AMARELO}15. StartHTTPAgentPollers${RESET} (Limites: 0-1000 | Padrão Zabbix: 1)"
            echo -e "   Coletores assíncronos de alta concorrência para o HTTP Agent."
            read -rp "   Valor Recomendado [1]: " T_HAPOLL; T_HAPOLL=${T_HAPOLL:-1}

            echo -e "\n${AMARELO}16. StartSNMPPollers${RESET} (Limites: 0-1000 | Padrão Zabbix: 1)"
            echo -e "   Coletores assíncronos de altíssima eficiência dedicados a queries de SNMP."
            read -rp "   Valor Recomendado [10]: " T_SPOLL; T_SPOLL=${T_SPOLL:-10}

            echo -e "\n${AMARELO}17. StartBrowserPollers${RESET} (Limites: 0-1000 | Padrão Zabbix: 1)"
            echo -e "   Coletores assíncronos dedicados a itens de monitorização via Browser (Zabbix 7.0+)."
            read -rp "   Valor Recomendado [1]: " T_BPOLL; T_BPOLL=${T_BPOLL:-1}

            echo -e "\n${AMARELO}18. StartODBCPollers${RESET} (Limites: 0-1000 | Padrão Zabbix: 1)"
            echo -e "   Coletores dedicados a itens de Base de Dados via ODBC (DB Monitor)."
            read -rp "   Valor Recomendado [1]: " T_ODBCPOLL; T_ODBCPOLL=${T_ODBCPOLL:-1}

            echo -e "\n${AMARELO}19. MaxConcurrentChecksPerPoller${RESET} (Limites: 1-1000 | Padrão Zabbix: 1000)"
            echo -e "   Número máximo de métricas que UM único poller assíncrono consegue processar a cada ciclo."
            read -rp "   Valor Recomendado [1000]: " T_MAXC; T_MAXC=${T_MAXC:-1000}

            echo -e "\n${AMARELO}20. ProxyConfigFrequency${RESET} (Limites: 1-604800 | Padrão Zabbix: 10)"
            echo -e "   Intervalo em segundos para que o Proxy (Ativo) descarregue configurações novas do Server."
            read -rp "   Valor Recomendado [10]: " T_CFG_FREQ; T_CFG_FREQ=${T_CFG_FREQ:-10}

            echo -e "\n${AMARELO}21. DataSenderFrequency${RESET} (Limites: 1-3600 | Padrão Zabbix: 1)"
            echo -e "   Intervalo em segundos para que o Proxy (Ativo) envie os seus dados para o Server."
            read -rp "   Valor Recomendado [1]: " T_SND_FREQ; T_SND_FREQ=${T_SND_FREQ:-1}

            echo -e "\n${AMARELO}22. ProxyOfflineBuffer${RESET} (Limites: 1-720 | Padrão Zabbix: 1)"
            echo -e "   Mantém os dados acumulados durante N 'Horas' caso a ligação ao Zabbix Server falhe."
            read -rp "   Valor Recomendado [1]: " T_OFFLINE; T_OFFLINE=${T_OFFLINE:-1}

            echo -e "\n${AMARELO}23. ProxyBufferMode${RESET} (Opções: disk, memory, hybrid | Padrão Zabbix: disk)"
            echo -e "   Motor de cache. A opção 'hybrid' aproveita a RAM para aceleração bruta e descarrega no disco se encher."
            while true; do
                read -rp "   Valor Recomendado [hybrid]: " T_BUF_MOD; T_BUF_MOD=${T_BUF_MOD:-hybrid}
                [[ "$T_BUF_MOD" =~ ^(disk|memory|hybrid)$ ]] && break
                echo "  Escolha 'disk', 'memory' ou 'hybrid'."
            done

            if [[ "$T_BUF_MOD" == "memory" || "$T_BUF_MOD" == "hybrid" ]]; then
                echo -e "\n${AMARELO}24. ProxyMemoryBufferSize${RESET} (Limites: 0, 128K-2G | Padrão Zabbix: 0)"
                echo -e "   Tamanho fixo da memória RAM alocada ao buffer (Modo Memory/Hybrid)."
                read -rp "   Valor Recomendado [16M]: " T_BUF_SZ; T_BUF_SZ=${T_BUF_SZ:-16M}

                echo -e "\n${AMARELO}25. ProxyMemoryBufferAge${RESET} (Limites: 0, 600-864000 | Padrão Zabbix: 0)"
                echo -e "   Tempo limite (em segundos) que a cache fica na RAM antes de ser forçada para a BD."
                read -rp "   Valor Recomendado [0]: " T_BUF_AGE; T_BUF_AGE=${T_BUF_AGE:-0}
            fi
            validate_size "$T_CACHE" "CacheSize"
            validate_int_range "$T_DBSYNC" "StartDBSyncers" 1 100
            validate_size "$T_HCACHE" "HistoryCacheSize"
            validate_size "$T_HICACHE" "HistoryIndexCacheSize"
            validate_int_range "$T_TOUT" "Timeout" 1 30
            validate_int_range "$T_UNREACH" "UnreachablePeriod" 1 3600
            validate_int_range "$T_PING" "StartPingers" 0 1000
            validate_int_range "$T_DISC" "StartDiscoverers" 0 1000
            validate_int_range "$T_HTTP" "StartHTTPPollers" 0 1000
            validate_int_range "$T_PREPROC" "StartPreprocessors" 1 1000
            validate_int_range "$T_PUNREACH" "StartPollersUnreachable" 0 1000
            validate_int_range "$T_TRAP" "StartTrappers" 0 1000
            validate_int_range "$T_POLL" "StartPollers" 0 1000
            validate_int_range "$T_APOLL" "StartAgentPollers" 0 1000
            validate_int_range "$T_HAPOLL" "StartHTTPAgentPollers" 0 1000
            validate_int_range "$T_SPOLL" "StartSNMPPollers" 0 1000
            validate_int_range "$T_BPOLL" "StartBrowserPollers" 0 1000
            validate_int_range "$T_ODBCPOLL" "StartODBCPollers" 0 1000
            validate_int_range "$T_MAXC" "MaxConcurrentChecksPerPoller" 1 1000
            validate_int_range "$T_CFG_FREQ" "ProxyConfigFrequency" 1 604800
            validate_int_range "$T_SND_FREQ" "DataSenderFrequency" 1 3600
            validate_int_range "$T_OFFLINE" "ProxyOfflineBuffer" 1 720
            if [[ "$T_BUF_MOD" == "memory" || "$T_BUF_MOD" == "hybrid" ]]; then
                validate_size "$T_BUF_SZ" "ProxyMemoryBufferSize"
                validate_zero_or_int_range "$T_BUF_AGE" "ProxyMemoryBufferAge" 600 864000
            fi
        fi
    }

    m_timezone() {
        PROXY_TIMEZONE="$(select_timezone_value "$PROXY_TIMEZONE" "Será aplicado ao relógio do sistema via timedatectl.")"
        echo -e "   ${VERDE}Fuso configurado: ${NEGRITO}${PROXY_TIMEZONE}${RESET}"
    }

    m_clean; m_update; m_version; m_proxy_mode; m_proxy_net; m_agent; m_security; m_tuning; m_timezone

    # Menu de revisão
    while true; do
        clear
        echo -e "${CIANO}${NEGRITO}╔══════════════════════════════════════════════════════════╗${RESET}"
        echo -e "${CIANO}${NEGRITO}║               REVISÃO FINAL DAS CONFIGURAÇÕES            ║${RESET}"
        echo -e "${CIANO}${NEGRITO}╚══════════════════════════════════════════════════════════╝${RESET}"
        echo -e "       Limpeza de Sistema:   $([[ "$CLEAN_INSTALL" == "1" ]] && echo -e "${VERMELHO}INSTALAÇÃO ANTERIOR DETETADA — será removida${RESET}" || echo "Sistema limpo")"
        echo -e "  ${AMARELO}2)${RESET} Atualização:          $([[ "$UPDATE_SYSTEM" == "1" ]] && echo -e "${VERDE}ATIVADA${RESET}" || echo "APENAS OBRIGATÓRIOS")"
        echo -e "  ${AMARELO}3)${RESET} Versão Zabbix:        ${VERDE}$ZBX_VERSION${RESET}"
        echo -e "  ${AMARELO}4)${RESET} Modo de Operação:     $([[ "$PROXY_MODE" == "0" ]] && echo "ATIVO (Push)" || echo "PASSIVO (Pull)")"
        echo -e "  ${AMARELO}5)${RESET} Zabbix Server:        ${NEGRITO}$ZBX_SERVER${RESET}"
        echo -e "  ${AMARELO}6)${RESET} Hostname Proxy:       ${CIANO}$ZBX_HOSTNAME${RESET}"
        echo -e "  ${AMARELO}7)${RESET} Zabbix Agent 2:       $([[ "$INSTALL_AGENT" == "1" ]] && echo -e "${VERDE}INSTALAR (Host: $AG_HOSTNAME)${RESET}" || echo "NÃO")"
        echo -e "  ${AMARELO}8)${RESET} Segurança PSK:        $([[ "$USE_PSK" == "1" ]] && echo -e "${VERDE}ATIVO (Prox: $PSK_PROXY_ID)${RESET}" || echo "INATIVO")"
        echo -e "  ${AMARELO}9)${RESET} Comandos Remotos:     $([[ "$ENABLE_REMOTE" == "1" ]] && echo "PERMITIDOS" || echo "BLOQUEADOS")"
        echo -e "  ${AMARELO}10)${RESET} Performance Auto:     ${VERDE}${PROXY_PERF_PROFILE}${RESET} (Cache: ${T_CACHE} | History: ${T_HCACHE} | Pollers: ${T_POLL} | Preproc: ${T_PREPROC} | DBSyncers: ${T_DBSYNC})"
        echo -e "  ${AMARELO}11)${RESET} Tuning Avançado:      $([[ "$USE_TUNING" == "1" ]] && echo -e "${VERDE}SIM (BufferMode: $T_BUF_MOD)${RESET}" || echo "NÃO")"
        echo -e "  ${AMARELO}12)${RESET} Fuso Horário:         ${CIANO}${PROXY_TIMEZONE}${RESET}"
        echo -e "  ${AMARELO}13)${RESET} ${VERMELHO}Abortar Instalação${RESET}"
        echo -e "\n  ${VERDE}${NEGRITO}0) [ TUDO PRONTO - INICIAR INSTALAÇÃO ]${RESET}"
        echo -e "${CIANO}------------------------------------------------------------${RESET}"
        read -rp "Insira o número da secção a alterar ou 0 para executar: " rev_opt
        case $rev_opt in
            2) m_update ;; 3) m_version ;; 4) m_proxy_mode ;; 5|6) m_proxy_net ;;
            7) m_agent ;; 8|9) m_security ;; 10|11) m_tuning ;;
            12) m_timezone ;;
            13) echo -e "${VERMELHO}Instalação abortada pelo utilizador.${RESET}"; exit 1 ;; 0) break ;;
        esac
    done

    # Pipeline
    confirm_execution_summary "Proxy"
    validate_compatibility_matrix "proxy"
    echo -e "\n${CIANO}${NEGRITO}A processar pipeline... Não cancele a operação!${RESET}\n"
    preflight_install_check "proxy" 2048 1024
    TOTAL_STEPS=15  # +1 para apt-mark hold
    [[ "$CLEAN_INSTALL" == "1" ]] && TOTAL_STEPS=$(( TOTAL_STEPS + 3 ))
    [[ "$UPDATE_SYSTEM" == "1" ]] && TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))
    [[ "$INSTALL_AGENT" == "1" ]] && TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))
    [[ "$USE_PSK" == "1" ]]       && TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))
    _IS_CONTAINER=0; systemd-detect-virt -c -q 2>/dev/null && _IS_CONTAINER=1 || true
    [[ "$_IS_CONTAINER" == "0" ]] && TOTAL_STEPS=$(( TOTAL_STEPS + 2 ))  # timedatectl + NTP
    [[ "$SIMULATE_MODE" == "1" ]] && echo -e "\n${CIANO}${NEGRITO}SIMULAÇÃO DO PIPELINE — PROXY${RESET}\n"

    if [[ "$CLEAN_INSTALL" == "1" ]]; then
        safe_confirm_cleanup "Limpeza da camada Proxy" \
            "serviços zabbix-proxy e zabbix-agent2" \
            "pacotes Zabbix Proxy/Agent" \
            "/etc/zabbix /var/lib/zabbix /var/log/zabbix /run/zabbix /tmp/zabbix_*"
        run_step "Parando e desativando serviços zabbix" bash -c \
            "for svc in zabbix-proxy zabbix-agent2; do \
                 timeout 15 systemctl stop \$svc 2>/dev/null || \
                 systemctl kill --kill-who=all \$svc 2>/dev/null || true; \
                 systemctl disable \$svc 2>/dev/null || true; \
             done; \
             pkill -9 -x zabbix_proxy  2>/dev/null || true; \
             pkill -9 -x zabbix_agent2 2>/dev/null || true"
        run_step "Purge completo de todos os pacotes zabbix" bash -c \
            "dpkg -l 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^ii|^rc/ && \$2 ~ /zabbix/ {print \$2}' | \
             xargs -r apt-mark unhold 2>/dev/null || true; \
             dpkg -l 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^ii|^rc/ && \$2 ~ /zabbix/ {print \$2}' | \
             xargs -r apt-get purge -y 2>/dev/null || true; \
             apt-get autoremove -y 2>/dev/null || true"
        run_step "Remoção completa de dados, configs e logs" bash -c \
            "rm -rf /etc/zabbix /var/lib/zabbix /var/log/zabbix /run/zabbix /tmp/zabbix_* 2>/dev/null || true; rm -f /tmp/zbx_repo.deb /etc/apt/sources.list.d/zabbix*.list /etc/apt/sources.list.d/zabbix*.sources /etc/apt/sources.list.d/pgdg.list /etc/apt/sources.list.d/timescaledb.list /etc/apt/trusted.gpg.d/timescaledb.gpg /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc 2>/dev/null || true"
    fi

    # Em containers LXC o relógio é gerido pelo host — tentar alterar causa erro fatal.
    # systemd-detect-virt -c retorna 0 (verdadeiro) se for qualquer container (LXC, Docker, etc).
    if ! systemd-detect-virt -c -q 2>/dev/null; then
        run_step "Ajustando relógio (${PROXY_TIMEZONE})" timedatectl set-timezone "${PROXY_TIMEZONE}"
        run_step "Ativando motor NTP" systemctl enable --now systemd-timesyncd
    else
        echo -e "\n  ${AMARELO}⚠ Ambiente de container (LXC) detectado. Pulando configuração de NTP (gerido pelo Host).${RESET}"
    fi
    run_step "Destravando processos do APT" auto_repair_apt
    run_step "Atualizando caches locais" apt-get update
    [[ "$SIMULATE_MODE" != "1" ]] && validate_packages_available curl wget sqlite3 openssl

    if [[ "$UPDATE_SYSTEM" == "1" ]]; then
        run_step "Realizando upgrade seguro dos pacotes do sistema" apt-get upgrade "${APT_FLAGS[@]}"
        run_step "Instalando plugins e ferramentas completas" install_proxy_full_tools
    else
        run_step "Instalando apenas dependências obrigatórias" \
            apt-get install "${APT_FLAGS[@]}" curl wget sqlite3 openssl
    fi

    if [[ "$ZBX_VERSION" == "8.0" ]]; then
        REPO_URL="$(zabbix_release_url "8.0")"
    elif [[ "$ZBX_VERSION" == "7.4" ]]; then
        REPO_URL="$(zabbix_release_url "7.4")"
    else
        REPO_URL="$(zabbix_release_url "7.0")"
    fi
    run_step "Validando URL do repositório Zabbix ${ZBX_VERSION}" check_zabbix_repo_url
    [[ "$SIMULATE_MODE" != "1" ]] && validate_official_zabbix_package zabbix-proxy-sqlite3 "$ZBX_VERSION"
    run_step "Baixando Repo Oficial Zabbix" wget -q "$REPO_URL" -O /tmp/zbx_repo.deb
    run_step "Validando Repositório" dpkg --force-confmiss -i /tmp/zbx_repo.deb
    run_step "Sincronizando novas sources" apt-get update
    run_step "Verificando acesso ao repositório Zabbix ${ZBX_VERSION}" verify_zabbix_repo_active zabbix-proxy-sqlite3
    [[ "$SIMULATE_MODE" != "1" ]] && validate_packages_available zabbix-proxy-sqlite3
    [[ "$SIMULATE_MODE" != "1" && "$INSTALL_AGENT" == "1" ]] && validate_packages_available zabbix-agent2
    run_step "Instalando Proxy SQLite3" apt-get install "${APT_FLAGS[@]}" zabbix-proxy-sqlite3

    [[ "$INSTALL_AGENT" == "1" ]] && run_step "Instalando Agent 2" \
        apt-get install "${APT_FLAGS[@]}" zabbix-agent2

    ensure_proxy_config_files() {
        local missing=0
        apt-get install "${APT_FLAGS[@]}" --reinstall -o Dpkg::Options::="--force-confmiss" zabbix-proxy-sqlite3 >/dev/null
        if [[ "$INSTALL_AGENT" == "1" ]]; then
            apt-get install "${APT_FLAGS[@]}" --reinstall -o Dpkg::Options::="--force-confmiss" zabbix-agent2 >/dev/null
        fi
        if [[ ! -f /etc/zabbix/zabbix_proxy.conf ]]; then
            echo "Arquivo /etc/zabbix/zabbix_proxy.conf ausente após reinstalação do pacote." >&2
            missing=1
        fi
        if [[ "$INSTALL_AGENT" == "1" && ! -f /etc/zabbix/zabbix_agent2.conf ]]; then
            echo "Arquivo /etc/zabbix/zabbix_agent2.conf ausente após reinstalação do pacote." >&2
            missing=1
        fi
        [[ "$missing" == "0" ]]
    }
    run_step "Validando arquivos de configuração do Proxy" ensure_proxy_config_files

    run_step "Formando estrutura base da DB" mkdir -p /var/lib/zabbix
    prepare_proxy_runtime_dirs() {
        install -d -o zabbix -g zabbix -m 0750 /var/lib/zabbix /var/log/zabbix /run/zabbix
        rm -f /var/lib/zabbix/zabbix_proxy.db-journal /var/lib/zabbix/zabbix_proxy.db-wal /var/lib/zabbix/zabbix_proxy.db-shm 2>/dev/null || true
        chown -R zabbix:zabbix /var/lib/zabbix /var/log/zabbix /run/zabbix
    }
    run_step "Preparando diretórios runtime do Proxy" prepare_proxy_runtime_dirs

    PX_F="/etc/zabbix/zabbix_proxy.conf"
    AG_F="/etc/zabbix/zabbix_agent2.conf"

    apply_logic() {
        set_config "$PX_F" "ProxyMode" "$PROXY_MODE"
        set_config "$PX_F" "Server"    "$ZBX_SERVER"
        set_config "$PX_F" "Hostname"  "$ZBX_HOSTNAME"
        set_config "$PX_F" "DBName"    "/var/lib/zabbix/zabbix_proxy.db"
        set_config "$PX_F" "LogType"   "file"
        set_config "$PX_F" "LogFile"   "/var/log/zabbix/zabbix_proxy.log"
        set_config "$PX_F" "EnableRemoteCommands" ""
        set_config "$PX_F" "AllowKey" ""
        set_config "$PX_F" "CacheSize"        "$T_CACHE"
        set_config "$PX_F" "StartDBSyncers"   "$T_DBSYNC"
        set_config "$PX_F" "HistoryCacheSize" "$T_HCACHE"
        set_config "$PX_F" "StartPollers"     "$T_POLL"
        set_config "$PX_F" "StartPreprocessors" "$T_PREPROC"
        if [[ "$USE_TUNING" == "1" ]]; then
            set_config "$PX_F" "HistoryIndexCacheSize"        "$T_HICACHE"
            set_config "$PX_F" "Timeout"                      "$T_TOUT"
            set_config "$PX_F" "UnreachablePeriod"            "$T_UNREACH"
            set_config "$PX_F" "StartPingers"                 "$T_PING"
            set_config "$PX_F" "StartDiscoverers"             "$T_DISC"
            set_config "$PX_F" "StartHTTPPollers"             "$T_HTTP"
            set_config "$PX_F" "StartPollersUnreachable"      "$T_PUNREACH"
            set_config "$PX_F" "StartTrappers"                "$T_TRAP"
            set_config "$PX_F" "StartAgentPollers"            "$T_APOLL"
            set_config "$PX_F" "StartHTTPAgentPollers"        "$T_HAPOLL"
            set_config "$PX_F" "StartSNMPPollers"             "$T_SPOLL"
            set_config "$PX_F" "StartBrowserPollers"          "$T_BPOLL"
            set_config "$PX_F" "StartODBCPollers"             "$T_ODBCPOLL"
            set_config "$PX_F" "MaxConcurrentChecksPerPoller" "$T_MAXC"
            set_config "$PX_F" "ProxyConfigFrequency"         "$T_CFG_FREQ"
            set_config "$PX_F" "DataSenderFrequency"          "$T_SND_FREQ"
            set_config "$PX_F" "ProxyOfflineBuffer"           "$T_OFFLINE"
            set_config "$PX_F" "ProxyBufferMode"              "$T_BUF_MOD"
            if [[ "$T_BUF_MOD" == "hybrid" || "$T_BUF_MOD" == "memory" ]]; then
                set_config "$PX_F" "ProxyMemoryBufferSize" "$T_BUF_SZ"
                set_config "$PX_F" "ProxyMemoryBufferAge"  "$T_BUF_AGE"
            fi
        fi
        if [[ -f "$AG_F" && "$INSTALL_AGENT" == "1" ]]; then
            set_config "$AG_F" "Server"       "$AG_SERVER"
            set_config "$AG_F" "ServerActive" "$AG_SERVER_ACTIVE"
            set_config "$AG_F" "Hostname"     "$AG_HOSTNAME"
            [[ "$AG_ALLOWKEY" == "1" ]] && set_config "$AG_F" "AllowKey" "system.run[*]"
        fi
    }
    run_step "Aplicando configurações nos ficheiros" apply_logic

    if [[ "$USE_PSK" == "1" ]]; then
        if [[ "$SIMULATE_MODE" == "1" ]]; then
            PSK_PROXY_KEY="<gerado-na-instalação-real>"
        else
            PSK_PROXY_KEY=$(openssl rand -hex 32)
        fi
        if [[ "$SIMULATE_MODE" != "1" ]]; then
            echo "$PSK_PROXY_KEY" > /etc/zabbix/zabbix_proxy.psk
            chown zabbix:zabbix /etc/zabbix/zabbix_proxy.psk
            chmod 600 /etc/zabbix/zabbix_proxy.psk
        fi
        if [[ "$INSTALL_AGENT" == "1" ]]; then
            if [[ "$SIMULATE_MODE" == "1" ]]; then
                PSK_AGENT_KEY="<gerado-na-instalação-real>"
            else
                PSK_AGENT_KEY=$(openssl rand -hex 32)
            fi
            if [[ "$SIMULATE_MODE" != "1" ]]; then
                echo "$PSK_AGENT_KEY" > /etc/zabbix/zabbix_agent2.psk
                chown zabbix:zabbix /etc/zabbix/zabbix_agent2.psk
                chmod 600 /etc/zabbix/zabbix_agent2.psk
            fi
        fi
        apply_psk() {
            set_config "$PX_F" "TLSAccept"      "psk"
            [[ "$PROXY_MODE" == "0" ]] && set_config "$PX_F" "TLSConnect" "psk"
            set_config "$PX_F" "TLSPSKIdentity" "$PSK_PROXY_ID"
            set_config "$PX_F" "TLSPSKFile"     "/etc/zabbix/zabbix_proxy.psk"
            if [[ -f "$AG_F" && "$INSTALL_AGENT" == "1" ]]; then
                set_config "$AG_F" "TLSAccept"      "psk"
                set_config "$AG_F" "TLSConnect"     "psk"
                set_config "$AG_F" "TLSPSKIdentity" "$PSK_AGENT_ID"
                set_config "$AG_F" "TLSPSKFile"     "/etc/zabbix/zabbix_agent2.psk"
            fi
        }
        run_step "Gerando e aplicando chaves PSK independentes" apply_psk
    fi

    start_proxy_service() {
        systemctl enable zabbix-proxy
        if ! timeout 30 systemctl restart zabbix-proxy; then
            echo "Falha ao iniciar zabbix-proxy. Últimas linhas do serviço:" >&2
            timeout 10 systemctl status zabbix-proxy --no-pager 2>&1 | tail -n 40 >&2 || true
            timeout 10 journalctl -u zabbix-proxy --no-pager -n 80 2>&1 >&2 || true
            return 1
        fi
    }
    run_step "Ativando Zabbix Proxy" start_proxy_service
    start_proxy_agent_service() {
        systemctl enable zabbix-agent2
        if ! timeout 30 systemctl restart zabbix-agent2; then
            echo "Falha ao iniciar zabbix-agent2. Últimas linhas do serviço:" >&2
            timeout 10 systemctl status zabbix-agent2 --no-pager 2>&1 | tail -n 40 >&2 || true
            timeout 10 journalctl -u zabbix-agent2 --no-pager -n 80 2>&1 >&2 || true
            return 1
        fi
    }
    [[ "$INSTALL_AGENT" == "1" ]] && run_step "Ativando Zabbix Agent 2" start_proxy_agent_service
    wait_for_service_active zabbix-proxy 30
    [[ "$INSTALL_AGENT" == "1" ]] && wait_for_service_active zabbix-agent2 30

    hold_packages_proxy() {
        # Fixa versões para evitar atualização acidental via apt upgrade
        apt-mark hold zabbix-proxy-sqlite3 2>/dev/null || true
        [[ "$INSTALL_AGENT" == "1" ]] && apt-mark hold zabbix-agent2 2>/dev/null || true
        echo -e "  ${VERDE}Versões fixadas. Use 'apt-mark unhold <pacote>' antes de atualizar manualmente.${RESET}"
    }
    run_step "Fixando versões instaladas (apt-mark hold)" hold_packages_proxy

    [[ "$SIMULATE_MODE" == "1" ]] && finish_simulation
    post_validate_installation "proxy"
    if [[ "$_CRITICAL_SERVICES_OK" == "1" ]]; then
        CURRENT_STEP=$TOTAL_STEPS; draw_progress "Instalação Perfeita! ✔"; printf "\n"
    else
        CURRENT_STEP=$TOTAL_STEPS; draw_progress "Instalação com Avisos ⚠"; printf "\n"
    fi

    # Certificado
    clear
    start_certificate_export "proxy"
    [[ "$_CRITICAL_SERVICES_OK" != "1" ]] && \
        echo -e "${VERMELHO}${NEGRITO}⚠ UM OU MAIS SERVIÇOS CRÍTICOS NÃO ESTÃO ATIVOS. Verifique acima e execute: journalctl -xe --no-pager${RESET}\n"
    echo -e "${VERDE}${NEGRITO}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${VERDE}${NEGRITO}║                CERTIFICADO DE IMPLANTAÇÃO                ║${RESET}"
    echo -e "${VERDE}${NEGRITO}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo -e "\n${CIANO}${NEGRITO}▸ INFO DO SISTEMA OPERACIONAL${RESET}"
    command -v lsb_release >/dev/null 2>&1 && \
        printf "  %-34s %s\n" "Distribuição:" "$(lsb_release -ds)" || \
        printf "  %-34s %s\n" "Sistema:" "$OS_DISPLAY"
    printf "  %-34s %s\n" "Kernel:" "$(uname -r)"
    printf "  %-34s %s\n" "Arquitetura:" "$(uname -m)"
    echo -e "\n${CIANO}${NEGRITO}▸ DADOS DE REDE DO HOST${RESET}"
    HOST_IP=$(hostname -I | awk '{print $1}')
    printf "  %-34s %s\n" "Endereço IPv4 Local:" "$HOST_IP"
    printf "  %-34s %s\n" "Gateway Padrão:" "$(ip route | awk '/default/ {print $3}' | head -n 1)"
    printf "  %-34s %s\n" "Porta do Proxy (TCP):" "10051 — abrir no firewall se necessário"
    if [[ "$PROXY_MODE" == "1" ]]; then
        echo -e "  ${AMARELO}Modo passivo:${RESET} o Zabbix Server deve conseguir alcançar este Proxy em ${HOST_IP}:10051/TCP."
    fi
    check_proxy_server_connectivity "$ZBX_SERVER" "$PROXY_MODE"
    echo -e "\n${CIANO}${NEGRITO}▸ VERSÕES DOS PACOTES INSTALADOS${RESET}"
    PX_PKG_VER=$(dpkg -l zabbix-proxy-sqlite3 2>/dev/null | awk '/^ii/{print $3}' | head -n 1 || true)
    SQLITE_VER=$(sqlite3 --version 2>/dev/null | awk '{print $1}' || true)
    printf "  %-34s %s\n" "zabbix-proxy-sqlite3:" "${PX_PKG_VER:-N/D}"
    printf "  %-34s %s\n" "sqlite3:" "${SQLITE_VER:-N/D}"
    if [[ "$INSTALL_AGENT" == "1" ]]; then
        AG_PKG_VER=$(dpkg -l zabbix-agent2 2>/dev/null | awk '/^ii/{print $3}' | head -n 1 || true)
        printf "  %-34s %s\n" "zabbix-agent2:" "${AG_PKG_VER:-N/D}"
    fi
    echo -e "\n${CIANO}${NEGRITO}▸ ESTADO DOS SERVIÇOS${RESET}"
    systemctl is-active --quiet zabbix-proxy && \
        printf "  %-34s ${VERDE}%s${RESET}\n" "zabbix-proxy:" "ATIVO ✔" || \
        printf "  %-34s ${VERMELHO}%s${RESET}\n" "zabbix-proxy:" "FALHOU ✖"
    if [[ "$INSTALL_AGENT" == "1" ]]; then
        systemctl is-active --quiet zabbix-agent2 && \
            printf "  %-34s ${VERDE}%s${RESET}\n" "zabbix-agent2:" "ATIVO ✔" || \
            printf "  %-34s ${VERMELHO}%s${RESET}\n" "zabbix-agent2:" "FALHOU ✖"
    fi
    echo -e "\n${CIANO}${NEGRITO}▸ AUDITORIA: LINHAS ATIVAS NO PROXY ($PX_F)${RESET}"
    timeout 10 awk '$0 !~ /^[[:space:]]*#/ && $0 !~ /^[[:space:]]*$/ { print "  " $0 }' "$PX_F" 2>/dev/null || true
    if [[ "$INSTALL_AGENT" == "1" ]]; then
        echo -e "\n${CIANO}${NEGRITO}▸ AUDITORIA: LINHAS ATIVAS NO AGENTE ($AG_F)${RESET}"
        timeout 10 awk '$0 !~ /^[[:space:]]*#/ && $0 !~ /^[[:space:]]*$/ { print "  " $0 }' "$AG_F" 2>/dev/null || true
    fi
    if [[ "$USE_PSK" == "1" ]]; then
        echo -e "\n${AMARELO}${NEGRITO}▸ CREDENCIAIS PSK PARA O FRONTEND${RESET}"
        echo -e "  ------------------------------------------------------------"
        echo -e "  ${VERDE}[ ZABBIX PROXY ]${RESET}"
        printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "IP:"         "$HOST_IP"
        printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "Hostname:"   "$ZBX_HOSTNAME"
        printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "Identity:"   "$PSK_PROXY_ID"
        printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "Secret Key:" "$PSK_PROXY_KEY"
        if [[ "$INSTALL_AGENT" == "1" ]]; then
            echo -e "\n  ${VERDE}[ ZABBIX AGENT 2 ]${RESET}"
            printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "IP:"         "$HOST_IP"
            printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "Hostname:"   "$AG_HOSTNAME"
            printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "Identity:"   "$PSK_AGENT_ID"
            printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "Secret Key:" "$PSK_AGENT_KEY"
        fi
        echo -e "  ------------------------------------------------------------"
    fi
    print_install_warnings
    echo -e "\n${CIANO}${NEGRITO}▸ EXPORTAÇÃO JSON${RESET}"
    write_install_summary_json "proxy"
    print_support_commands "proxy"
    echo -e "\n${NEGRITO}Log completo:${RESET} $LOG_FILE\n"
    ;;

esac
exit 0
