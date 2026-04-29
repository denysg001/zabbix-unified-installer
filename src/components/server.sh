# shellcheck shell=bash

# Server component: Zabbix Server, frontend, Nginx, PHP-FPM, schema import, and optional Agent 2.
run_component_server() {
    component_supported_or_die "server"

    set_default_php_for_os() {
        if [[ "$OS_FAMILY" == "debian" ]]; then
            case "$U_VER" in
            "12")
                PHP_VER="8.2"
                NEED_PHP_PPA=0
                ;;
            "13")
                PHP_VER="8.4"
                NEED_PHP_PPA=0
                ;;
            *)
                PHP_VER="8.2"
                NEED_PHP_PPA=0
                ;;
            esac
        else
            case "$U_VER" in
            "20.04")
                PHP_VER="8.1"
                NEED_PHP_PPA=1
                ;;
            "22.04")
                PHP_VER="8.1"
                NEED_PHP_PPA=0
                ;;
            "24.04")
                PHP_VER="8.3"
                NEED_PHP_PPA=0
                ;;
            "26.04")
                PHP_VER="8.5"
                NEED_PHP_PPA=0
                ;;
            *)
                PHP_VER="8.1"
                NEED_PHP_PPA=0
                ;;
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
            if ((php_num < 82)); then
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
    ZBX_VERSION="7.0"
    PG_VER="17"
    DB_HOST=""
    DB_PORT="5432"
    DB_NAME="zabbix"
    DB_USER="zabbix"
    DB_PASS=""
    USE_TIMESCALE="0"
    ZBX_DB_DETECTED="" # valor 'mandatory' da tabela dbversion (vazio = BD sem schema Zabbix)
    USE_HTTPS="0"
    SSL_TYPE="self-signed"
    SSL_CERT="/etc/ssl/zabbix/zabbix.crt"
    SSL_KEY="/etc/ssl/zabbix/zabbix.key"
    USE_HTTP_REDIRECT="0"
    NGINX_PORT="80"
    SERVER_NAME="_"
    TIMEZONE="${SYS_TIMEZONE:-America/Sao_Paulo}"
    INSTALL_AGENT="0"
    USE_PSK="0"
    PSK_AGENT_ID=""
    PSK_AGENT_KEY=""
    AG_SERVER="127.0.0.1"
    AG_SERVER_ACTIVE="127.0.0.1"
    AG_HOSTNAME=""
    AG_ALLOWKEY="0"
    ENABLE_REMOTE="0"
    USE_TUNING="0"
    UPDATE_SYSTEM="0"
    CLEAN_INSTALL=0
    PHP_UPLOAD_SIZE="32M"
    T_CACHE="256M"
    T_HCACHE="128M"
    T_HICACHE="32M"
    T_VCACHE="256M"
    T_TRCACHE="32M"
    T_POLL="20"
    T_PUNREACH="5"
    T_TRAP="10"
    T_PREPROC="16"
    T_DBSYNC="4"
    T_PING="5"
    T_DISC="5"
    T_HTTP="5"
    T_APOLL="1"
    T_HAPOLL="1"
    T_SPOLL="10"
    T_BPOLL="1"
    T_ODBCPOLL="1"
    T_MAXC="1000"
    T_UNREACH="45"
    T_TOUT="5"
    T_HK="1"
    T_SLOWQ="3000"

    clamp_int() {
        local value="$1" min="$2" max="$3"
        ((value < min)) && value="$min"
        ((value > max)) && value="$max"
        echo "$value"
    }

    calc_server_auto_performance() {
        if ((RAM_MB < 4096)); then
            SERVER_PERF_PROFILE="mínimo"
            T_CACHE="64M"
            T_VCACHE="64M"
            T_HCACHE="64M"
            T_TRCACHE="16M"
            T_DBSYNC="2"
            T_POLL=$(clamp_int $((CPU_CORES * 2)) 4 8)
            T_PREPROC=$(clamp_int $((CPU_CORES * 1)) 2 4)
        elif ((RAM_MB < 8192)); then
            SERVER_PERF_PROFILE="baixo"
            T_CACHE="128M"
            T_VCACHE="128M"
            T_HCACHE="128M"
            T_TRCACHE="32M"
            T_DBSYNC="2"
            T_POLL=$(clamp_int $((CPU_CORES * 4)) 8 12)
            T_PREPROC=$(clamp_int $((CPU_CORES * 2)) 4 8)
        elif ((RAM_MB <= 16384)); then
            SERVER_PERF_PROFILE="médio"
            T_CACHE="256M"
            T_VCACHE="256M"
            T_HCACHE="256M"
            T_TRCACHE="64M"
            T_DBSYNC="4"
            T_POLL=$(clamp_int $((CPU_CORES * 5)) 16 30)
            T_PREPROC=$(clamp_int $((CPU_CORES * 3)) 12 24)
        else
            SERVER_PERF_PROFILE="alto"
            T_CACHE="512M"
            T_VCACHE="512M"
            T_HCACHE="512M"
            T_TRCACHE="128M"
            T_DBSYNC="8"
            T_POLL=$(clamp_int $((CPU_CORES * 6)) 30 60)
            T_PREPROC=$(clamp_int $((CPU_CORES * 4)) 24 48)
        fi
    }
    calc_server_auto_performance

    # Banner Server
    clear
    echo -e "${VERMELHO}${NEGRITO}"
    cat <<"EOF"
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
            1)
                ZBX_VERSION="7.0"
                break
                ;;
            2)
                ZBX_VERSION="7.4"
                break
                ;;
            3)
                ZBX_VERSION="8.0"
                break
                ;;
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
            local _tsdb_major
            _tsdb_major=$(echo "$_tsdb_ver" | cut -d. -f1)
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
            if [[ "$_zbx_dbver" -ge 7050033 ]]; then
                _schema_origem="8.0"
            elif [[ "$_zbx_dbver" -ge 7040000 ]]; then
                _schema_origem="7.4"
            elif [[ "$_zbx_dbver" -ge 7000000 ]]; then
                _schema_origem="7.0"
            elif [[ "$_zbx_dbver" -ge 6000000 ]]; then
                _schema_origem="6.x"
            else
                _schema_origem="<6.0"
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
            1)
                m_version
                return 1
                ;;
            2) return 2 ;;
            3)
                echo -e "\n  ${VERMELHO}${NEGRITO}Confirmação forte:${RESET} digite CONTINUAR para assumir o risco de schema incompatível."
                read -rp "   Confirmação: " _schema_force
                if [[ "$_schema_force" == "CONTINUAR" ]]; then
                    echo -e "\n  ${AMARELO}⚠  A continuar. Resolva o conflito manualmente antes de aceder à interface web.${RESET}"
                    return 3
                fi
                echo -e "   ${AMARELO}Confirmação não recebida. Voltando às opções.${RESET}"
                ;;
            4)
                echo -e "${VERMELHO}Instalação abortada pelo utilizador.${RESET}"
                exit 1
                ;;
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
        read -rp "   Valor Recomendado [5432]: " DB_PORT
        DB_PORT=${DB_PORT:-5432}
        validate_port "$DB_PORT"
        echo -e "\n${AMARELO}Nome da Base de Dados${RESET} (Padrão: zabbix)"
        read -rp "   Valor Recomendado [zabbix]: " DB_NAME
        DB_NAME=${DB_NAME:-zabbix}
        validate_identifier "$DB_NAME" "Nome da base de dados"
        echo -e "\n${AMARELO}Utilizador da Base de Dados${RESET}"
        while true; do
            read -rp "   Preencher (ex: zabbix ou zbx_f3a2b1c9): " DB_USER
            [[ -n "$DB_USER" ]] && {
                validate_identifier "$DB_USER" "Utilizador da base de dados"
                break
            }
            echo -e "   ${VERMELHO}Campo obrigatório.${RESET}"
        done
        echo -e "\n${AMARELO}Senha do Utilizador${RESET} — obrigatório"
        while true; do
            read -rsp "   Preencher: " DB_PASS
            echo
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
            if [[ "$_retry_conn" == "1" ]]; then
                m_dbconn
                return
            fi
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
        echo "${DB_HOST}:${DB_PORT}:*:${DB_USER}:${_pgpass_db_pass}" >"$_pgpass_tmp"
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
            0 | 3) break ;; # compatível ou continuar mesmo assim
            1) ;;           # versão Zabbix alterada → re-mostrar tabela com nova versão
            2)
                m_dbconn
                return
                ;; # re-inserir credenciais
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
            1)
                USE_HTTPS="0"
                NGINX_PORT="80"
                break
                ;;
            2)
                USE_HTTPS="1"
                NGINX_PORT="443"
                echo -e "\n   ${CIANO}${NEGRITO}Tipo de Certificado SSL:${RESET}"
                echo -e "   1) Auto-assinado (gerado agora, 10 anos)"
                echo -e "   2) Certificado existente (fornecer caminhos)"
                echo -e "   3) Configurar HTTPS sem certificado agora"
                while true; do
                    read -rp "   Escolha (1, 2 ou 3): " ssl_opt
                    case "$ssl_opt" in
                    1)
                        SSL_TYPE="self-signed"
                        SSL_CERT="/etc/ssl/zabbix/zabbix.crt"
                        SSL_KEY="/etc/ssl/zabbix/zabbix.key"
                        break
                        ;;
                    2)
                        SSL_TYPE="existing"
                        while true; do
                            read -rp "   Caminho do .crt: " SSL_CERT
                            [[ -n "$SSL_CERT" ]] && break
                        done
                        while true; do
                            read -rp "   Caminho do .key: " SSL_KEY
                            [[ -n "$SSL_KEY" ]] && break
                        done
                        break
                        ;;
                    3)
                        SSL_TYPE="later"
                        SSL_CERT="/etc/ssl/zabbix/zabbix.crt"
                        SSL_KEY="/etc/ssl/zabbix/zabbix.key"
                        break
                        ;;
                    *) echo -e "   ${VERMELHO}Opção inválida.${RESET}" ;;
                    esac
                done
                ask_yes_no "Ativar redirecionamento HTTP (80) → HTTPS (443)?" USE_HTTP_REDIRECT
                break
                ;;
            3)
                USE_HTTPS="0"
                read -rp "   Porta personalizada [8080]: " NGINX_PORT
                NGINX_PORT=${NGINX_PORT:-8080}
                validate_port "$NGINX_PORT"
                break
                ;;
            *) echo -e "   ${VERMELHO}Opção inválida.${RESET}" ;;
            esac
        done
        echo -e "\n${AMARELO}Server Name (hostname/IP ou domínio do servidor)${RESET}"
        echo -e "   Deixe em branco para aceitar qualquer hostname (usa '_')."
        while true; do
            read -rp "   Preencher [_]: " SERVER_NAME
            SERVER_NAME=${SERVER_NAME:-_}
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
            read -rp "   Escolha (1-5) [2]: " up_opt
            up_opt=${up_opt:-2}
            case "$up_opt" in
            1)
                PHP_UPLOAD_SIZE="16M"
                break
                ;;
            2)
                PHP_UPLOAD_SIZE="32M"
                break
                ;;
            3)
                PHP_UPLOAD_SIZE="64M"
                break
                ;;
            4)
                PHP_UPLOAD_SIZE="128M"
                break
                ;;
            5)
                while true; do
                    read -rp "   Tamanho personalizado (ex: 256M): " PHP_UPLOAD_SIZE
                    [[ "$PHP_UPLOAD_SIZE" =~ ^[0-9]+[MmGg]$ ]] && break
                    echo -e "   ${VERMELHO}Formato inválido. Use ex: 64M ou 1G${RESET}"
                done
                break
                ;;
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
            read -rp "   Valor Recomendado [127.0.0.1]: " AG_SERVER
            AG_SERVER=${AG_SERVER:-127.0.0.1}
            validate_zabbix_identity "$AG_SERVER" "Server do Agente"
            echo -e "\n${AMARELO}ServerActive${RESET} (Envio Ativo)"
            read -rp "   Valor Recomendado [127.0.0.1]: " AG_SERVER_ACTIVE
            AG_SERVER_ACTIVE=${AG_SERVER_ACTIVE:-127.0.0.1}
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
            read -rp "   Valor Recomendado [${T_CACHE}]: " _v
            T_CACHE=${_v:-$T_CACHE}

            echo -e "\n${AMARELO}2. HistoryCacheSize${RESET} (Limites: 128K–2G | Padrão: 16M)"
            echo -e "   Cache de métricas recentes antes de escrever na BD. Crítico para alto throughput."
            read -rp "   Valor Recomendado [${T_HCACHE}]: " _v
            T_HCACHE=${_v:-$T_HCACHE}

            echo -e "\n${AMARELO}3. HistoryIndexCacheSize${RESET} (Limites: 128K–2G | Padrão: 4M)"
            echo -e "   Índice da cache de histórico — acelera pesquisas de valores."
            read -rp "   Valor Recomendado [32M]: " T_HICACHE
            T_HICACHE=${T_HICACHE:-32M}

            echo -e "\n${AMARELO}4. ValueCacheSize${RESET} (Limites: 0–64G | Padrão: 8M)"
            echo -e "   Cache de valores históricos para cálculo de funções e avaliação de triggers."
            read -rp "   Valor Recomendado [${T_VCACHE}]: " _v
            T_VCACHE=${_v:-$T_VCACHE}

            echo -e "\n${AMARELO}5. TrendCacheSize${RESET} (Limites: 128K–2G | Padrão: 4M)"
            echo -e "   Cache de dados de tendência (min/max/avg por hora)."
            read -rp "   Valor Recomendado [${T_TRCACHE}]: " _v
            T_TRCACHE=${_v:-$T_TRCACHE}

            echo -e "\n${AMARELO}6. StartPollers${RESET} (Limites: 0–1000 | Padrão: 5)"
            echo -e "   Coletores passivos genéricos (Agent 1, SNMP, scripts)."
            read -rp "   Valor Recomendado [${T_POLL}]: " _v
            T_POLL=${_v:-$T_POLL}

            echo -e "\n${AMARELO}7. StartPollersUnreachable${RESET} (Limites: 0–1000 | Padrão: 1)"
            echo -e "   Coletores dedicados a hosts em estado 'caído', sem bloquear os saudáveis."
            read -rp "   Valor Recomendado [5]: " T_PUNREACH
            T_PUNREACH=${T_PUNREACH:-5}

            echo -e "\n${AMARELO}8. StartTrappers${RESET} (Limites: 0–1000 | Padrão: 5)"
            echo -e "   Processos que recebem dados de Agentes Ativos e Zabbix Sender."
            read -rp "   Valor Recomendado [10]: " T_TRAP
            T_TRAP=${T_TRAP:-10}

            echo -e "\n${AMARELO}9. StartPreprocessors${RESET} (Limites: 1–1000 | Padrão: 3)"
            echo -e "   Threads para converter e processar dados brutos antes da cache."
            read -rp "   Valor Recomendado [${T_PREPROC}]: " _v
            T_PREPROC=${_v:-$T_PREPROC}

            echo -e "\n${AMARELO}10. StartDBSyncers${RESET} (Limites: 1–100 | Padrão: 4)"
            echo -e "   Sincronizadores da cache de memória para a Base de Dados."
            read -rp "   Valor Recomendado [${T_DBSYNC}]: " _v
            T_DBSYNC=${_v:-$T_DBSYNC}

            echo -e "\n${AMARELO}11. StartPingers${RESET} (Limites: 0–1000 | Padrão: 1)"
            echo -e "   Processos exclusivos para testes de ICMP (ping)."
            read -rp "   Valor Recomendado [5]: " T_PING
            T_PING=${T_PING:-5}

            echo -e "\n${AMARELO}12. StartDiscoverers${RESET} (Limites: 0–250 | Padrão: 5)"
            echo -e "   Processos de descoberta de rede (Network Discovery)."
            read -rp "   Valor Recomendado [5]: " T_DISC
            T_DISC=${T_DISC:-5}

            echo -e "\n${AMARELO}13. StartHTTPPollers${RESET} (Limites: 0–1000 | Padrão: 1)"
            echo -e "   Processos para testes de cenários Web HTTP."
            read -rp "   Valor Recomendado [5]: " T_HTTP
            T_HTTP=${T_HTTP:-5}

            echo -e "\n${AMARELO}14. StartAgentPollers${RESET} (Limites: 0–1000 | Padrão: 1)"
            echo -e "   Coletores assíncronos de alta concorrência para Zabbix Agent 2."
            read -rp "   Valor Recomendado [1]: " T_APOLL
            T_APOLL=${T_APOLL:-1}

            echo -e "\n${AMARELO}15. StartHTTPAgentPollers${RESET} (Limites: 0–1000 | Padrão: 1)"
            echo -e "   Coletores assíncronos de alta concorrência para o HTTP Agent."
            read -rp "   Valor Recomendado [1]: " T_HAPOLL
            T_HAPOLL=${T_HAPOLL:-1}

            echo -e "\n${AMARELO}16. StartSNMPPollers${RESET} (Limites: 0–1000 | Padrão: 1)"
            echo -e "   Coletores assíncronos dedicados a queries SNMP de alta eficiência."
            read -rp "   Valor Recomendado [10]: " T_SPOLL
            T_SPOLL=${T_SPOLL:-10}

            echo -e "\n${AMARELO}17. StartBrowserPollers${RESET} (Limites: 0–1000 | Padrão: 1)"
            echo -e "   Coletores para itens de monitorização via Browser (Zabbix 7.0+)."
            read -rp "   Valor Recomendado [1]: " T_BPOLL
            T_BPOLL=${T_BPOLL:-1}

            echo -e "\n${AMARELO}18. StartODBCPollers${RESET} (Limites: 0–1000 | Padrão: 1)"
            echo -e "   Coletores para itens de BD via ODBC (DB Monitor)."
            read -rp "   Valor Recomendado [1]: " T_ODBCPOLL
            T_ODBCPOLL=${T_ODBCPOLL:-1}

            echo -e "\n${AMARELO}19. MaxConcurrentChecksPerPoller${RESET} (Limites: 1–1000 | Padrão: 1000)"
            echo -e "   Métricas que um único poller assíncrono processa por ciclo."
            read -rp "   Valor Recomendado [1000]: " T_MAXC
            T_MAXC=${T_MAXC:-1000}

            echo -e "\n${AMARELO}20. UnreachablePeriod${RESET} (Limites: 1–3600 | Padrão: 45)"
            echo -e "   Segundos sem resposta até o host ser considerado incontactável."
            read -rp "   Valor Recomendado [45]: " T_UNREACH
            T_UNREACH=${T_UNREACH:-45}

            echo -e "\n${AMARELO}21. Timeout${RESET} (Limites: 1–30 | Padrão: 3 segundos)"
            echo -e "   Tempo máximo de espera por resposta de agentes/rede."
            read -rp "   Valor Recomendado [5]: " T_TOUT
            T_TOUT=${T_TOUT:-5}

            echo -e "\n${AMARELO}22. HousekeepingFrequency${RESET} (Limites: 0–24 horas | Padrão: 1)"
            echo -e "   Frequência (horas) da limpeza automática de dados antigos. 0=desativado."
            read -rp "   Valor Recomendado [1]: " T_HK
            T_HK=${T_HK:-1}

            echo -e "\n${AMARELO}23. LogSlowQueries${RESET} (Padrão: 0=desativado | em milissegundos)"
            echo -e "   Regista queries lentas à BD no log do Server. Útil para diagnóstico."
            read -rp "   Valor Recomendado [3000]: " T_SLOWQ
            T_SLOWQ=${T_SLOWQ:-3000}
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

    m_clean
    m_update
    m_version
    m_dbconn
    m_nginx
    m_agent
    m_security
    m_tuning
    m_timezone

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
            if [[ "$ZBX_DB_DETECTED" -ge 7050033 ]]; then
                _rev_schema_origem="8.0"
            elif [[ "$ZBX_DB_DETECTED" -ge 7040000 ]]; then
                _rev_schema_origem="7.4"
            elif [[ "$ZBX_DB_DETECTED" -ge 7000000 ]]; then
                _rev_schema_origem="7.0"
            else
                _rev_schema_origem="<7.0"
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
        2) m_update ;; 3) m_version ;; 4 | 5 | 6 | 7 | 8) m_dbconn ;;
        9 | 10 | 11) m_nginx ;; 12) m_agent ;; 13) m_security ;; 14 | 15) m_tuning ;;
        16) m_timezone ;;
        17)
            echo -e "${VERMELHO}Instalação abortada pelo utilizador.${RESET}"
            exit 1
            ;;
        0) break ;;
        esac
    done

    # Pipeline
    confirm_execution_summary "Server"
    validate_compatibility_matrix "server"
    echo -e "\n${CIANO}${NEGRITO}A processar pipeline... Não cancele a operação!${RESET}\n"
    preflight_install_check "server" 4096 2048
    TOTAL_STEPS=26 # +1 para apt-mark hold
    [[ "$CLEAN_INSTALL" == "1" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 3))
    [[ "$UPDATE_SYSTEM" == "1" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 2))
    [[ "$NEED_PHP_PPA" == "1" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
    [[ "$USE_TIMESCALE" == "1" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 2)) # import + compressão
    [[ "$USE_HTTPS" == "1" && "$SSL_TYPE" == "self-signed" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
    [[ "$INSTALL_AGENT" == "1" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 2))
    [[ "$USE_PSK" == "1" && "$INSTALL_AGENT" == "1" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
    _IS_CONTAINER=0
    systemd-detect-virt -c -q 2>/dev/null && _IS_CONTAINER=1 || true
    [[ "$_IS_CONTAINER" == "0" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 2)) # timedatectl + NTP
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

    setup_timezone_ntp "$TIMEZONE"
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

    [[ "$NEED_PHP_PPA" == "1" && "$OS_FAMILY" == "ubuntu" ]] &&
        run_step "Adicionando PPA ondrej/php (PHP ${PHP_VER} para Ubuntu ${U_VER})" \
            add-apt-repository -y ppa:ondrej/php

    setup_pgdg_repo() {
        install -d /usr/share/postgresql-common/pgdg
        _curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
            https://www.postgresql.org/media/keys/ACCC4CF8.asc
        echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
https://apt.postgresql.org/pub/repos/apt ${U_CODENAME}-pgdg main" \
            >/etc/apt/sources.list.d/pgdg.list
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
    run_step "Baixando repositório oficial Zabbix ${ZBX_VERSION}" _wget -q "$REPO_URL" -O /tmp/zbx_repo.deb
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

    run_step "Validando locale do frontend (pt_BR com fallback en_US)" ensure_zabbix_frontend_locales

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
        echo "${DB_HOST}:${DB_PORT}:*:${DB_USER}:${_pgpass_db_pass}" >"$_PGPASS_FILE"
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
        echo -e "  Verifique: dpkg -L zabbix-sql-scripts"
        exit 1
    fi

    import_schema() {
        # Verifica dbversion (schema completo) e não apenas hosts (pode existir parcialmente)
        local schema_completo
        schema_completo=$(psql -h "${DB_HOST}" -p "${DB_PORT}" \
            -U "${DB_USER}" -d "${DB_NAME}" \
            -tAc "SELECT to_regclass('public.dbversion');" 2>/dev/null | xargs || echo "")
        if [[ "$schema_completo" == "public.dbversion" || "$schema_completo" == "dbversion" ]]; then
            echo "Schema Zabbix completo já presente (dbversion) — passo ignorado." >>"$LOG_FILE"
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
            [[ ! -f "${ZBX_SQL_TSDB}" ]] && {
                echo "ERRO: ${ZBX_SQL_TSDB} não encontrado" >&2
                return 1
            }
            local hyper_count
            hyper_count=$(psql -h "${DB_HOST}" -p "${DB_PORT}" \
                -U "${DB_USER}" -d "${DB_NAME}" \
                -tAc "SELECT COUNT(*) FROM timescaledb_information.hypertables;" 2>/dev/null | xargs || echo "0")
            if [[ "${hyper_count:-0}" -gt 0 ]]; then
                echo "Hipertabelas já presentes — passo ignorado." >>"$LOG_FILE"
                return 0
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
                result=$(
                    psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
                        -v ON_ERROR_STOP=1 -qAt <<SQL 2>>"$LOG_FILE" | tee -a "$LOG_FILE" | tail -n 1 || true
DO \$\$
DECLARE
    policy_status text := 'skipped';
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
        policy_status := 'applied';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'TimescaleDB compression policy skipped for ${table}: %', SQLERRM;
        policy_status := 'skipped';
    END;
    RAISE NOTICE 'zbx_policy_status:%', policy_status;
END
\$\$;
SQL
                )
                result=$(printf '%s\n' "$result" | awk -F'zbx_policy_status:' '/zbx_policy_status:/{print $2}' | tail -1 | xargs || true)
                [[ "$result" == "applied" ]]
            }
            for _t in history history_uint history_str history_log history_text; do
                _total=$((_total + 1))
                _configure_one_tsdb_policy "$_t" "7 days" && _ok=$((_ok + 1)) || true
            done
            for _t in trends trends_uint; do
                _total=$((_total + 1))
                _configure_one_tsdb_policy "$_t" "1 day" && _ok=$((_ok + 1)) || true
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
        local admin_lang_sql timezone_sql
        admin_lang_sql=$(sql_quote_literal "${ZBX_FRONTEND_LANG:-en_US}")
        timezone_sql=$(sql_quote_literal "${TIMEZONE}")
        psql -h "${DB_HOST}" -p "${DB_PORT}" \
            -U "${DB_USER}" -d "${DB_NAME}" \
            -c "UPDATE users SET lang=${admin_lang_sql}, timezone=${timezone_sql} WHERE username='Admin';" \
            >>"$LOG_FILE" 2>&1 || true

    }
    run_step "Definindo idioma ${ZBX_FRONTEND_LANG:-en_US} e timezone ${TIMEZONE} (Admin)" set_default_language

    SV_F="/etc/zabbix/zabbix_server.conf"
    apply_server_config() {
        set_config "$SV_F" "DBHost" "${DB_HOST}"
        set_config "$SV_F" "DBName" "${DB_NAME}"
        set_config "$SV_F" "DBUser" "${DB_USER}"
        set_config "$SV_F" "DBPassword" "${DB_PASS}"
        set_config "$SV_F" "DBPort" "${DB_PORT}"
        set_config "$SV_F" "DBSocket" ""
        set_config "$SV_F" "StartPollers" "$T_POLL"
        set_config "$SV_F" "StartPreprocessors" "$T_PREPROC"
        set_config "$SV_F" "CacheSize" "$T_CACHE"
        set_config "$SV_F" "ValueCacheSize" "$T_VCACHE"
        set_config "$SV_F" "HistoryCacheSize" "$T_HCACHE"
        set_config "$SV_F" "TrendCacheSize" "$T_TRCACHE"
        set_config "$SV_F" "StartDBSyncers" "$T_DBSYNC"
        if [[ "$USE_TUNING" == "1" ]]; then
            set_config "$SV_F" "HistoryIndexCacheSize" "$T_HICACHE"
            set_config "$SV_F" "StartPollersUnreachable" "$T_PUNREACH"
            set_config "$SV_F" "StartTrappers" "$T_TRAP"
            set_config "$SV_F" "StartPingers" "$T_PING"
            set_config "$SV_F" "StartDiscoverers" "$T_DISC"
            set_config "$SV_F" "StartHTTPPollers" "$T_HTTP"
            set_config "$SV_F" "StartAgentPollers" "$T_APOLL"
            set_config "$SV_F" "StartHTTPAgentPollers" "$T_HAPOLL"
            set_config "$SV_F" "StartSNMPPollers" "$T_SPOLL"
            set_config "$SV_F" "StartBrowserPollers" "$T_BPOLL"
            set_config "$SV_F" "StartODBCPollers" "$T_ODBCPOLL"
            set_config "$SV_F" "MaxConcurrentChecksPerPoller" "$T_MAXC"
            set_config "$SV_F" "UnreachablePeriod" "$T_UNREACH"
            set_config "$SV_F" "Timeout" "$T_TOUT"
            set_config "$SV_F" "HousekeepingFrequency" "$T_HK"
            set_config "$SV_F" "LogSlowQueries" "$T_SLOWQ"
        fi
    }
    run_step "Configurando zabbix_server.conf (BD + tuning)" apply_server_config

    AG_F="/etc/zabbix/zabbix_agent2.conf"
    if [[ "$INSTALL_AGENT" == "1" && (-f "$AG_F" || "$SIMULATE_MODE" == "1") ]]; then
        apply_agent_config() {
            set_config "$AG_F" "Server" "$AG_SERVER"
            set_config "$AG_F" "ServerActive" "$AG_SERVER_ACTIVE"
            set_config "$AG_F" "Hostname" "$AG_HOSTNAME"
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
            echo "$PSK_AGENT_KEY" >/etc/zabbix/zabbix_agent2.psk
            chown zabbix:zabbix /etc/zabbix/zabbix_agent2.psk
            chmod 600 /etc/zabbix/zabbix_agent2.psk
            set_config "$AG_F" "TLSAccept" "psk"
            set_config "$AG_F" "TLSConnect" "psk"
            set_config "$AG_F" "TLSPSKIdentity" "$PSK_AGENT_ID"
            set_config "$AG_F" "TLSPSKFile" "/etc/zabbix/zabbix_agent2.psk"
        }
        run_step "Gerando e aplicando chave PSK do Agente" apply_psk_agent
    fi

    configure_nginx() {
        local NX_F="/etc/zabbix/nginx.conf"
        if [[ "$USE_HTTPS" == "1" ]]; then
            sed -i "s|#\s*listen\s\+[0-9]\+;|        listen          ${NGINX_PORT} ssl;|g" "$NX_F"
            sed -i "s|^\s*listen\s\+[0-9]\+;|        listen          ${NGINX_PORT} ssl;|g" "$NX_F"
            SSL_CERT_VAR="${SSL_CERT}" SSL_KEY_VAR="${SSL_KEY}" NX_F_VAR="${NX_F}" python3 <<'PYEOF'
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
                cat >/etc/nginx/conf.d/zabbix-http-redirect.conf <<EOF
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
            echo "php_value[date.timezone] = ${TIMEZONE}" >>"$PHP_FPM_CONF"
        fi

        # Memória: 256M (padrão PHP 128M é insuficiente para Zabbix)
        sed -i "s|php_value\[memory_limit\].*|php_value[memory_limit] = 256M|g" \
            "$PHP_FPM_CONF" 2>/dev/null ||
            echo "php_value[memory_limit] = 256M" >>"$PHP_FPM_CONF"

        # Tempo máximo de execução: 300s (importações pesadas podem demorar)
        sed -i "s|php_value\[max_execution_time\].*|php_value[max_execution_time] = 300|g" \
            "$PHP_FPM_CONF" 2>/dev/null ||
            echo "php_value[max_execution_time] = 300" >>"$PHP_FPM_CONF"

        # Tempo máximo de leitura do input
        sed -i "s|php_value\[max_input_time\].*|php_value[max_input_time] = 300|g" \
            "$PHP_FPM_CONF" 2>/dev/null ||
            echo "php_value[max_input_time] = 300" >>"$PHP_FPM_CONF"

        # Upload: valor escolhido pelo utilizador (templates, iconsets, mapas)
        sed -i "s|php_value\[upload_max_filesize\].*|php_value[upload_max_filesize] = ${PHP_UPLOAD_SIZE}|g" \
            "$PHP_FPM_CONF" 2>/dev/null ||
            echo "php_value[upload_max_filesize] = ${PHP_UPLOAD_SIZE}" >>"$PHP_FPM_CONF"

        # post_max_size deve ser >= upload_max_filesize (usar o mesmo valor é seguro)
        sed -i "s|php_value\[post_max_size\].*|php_value[post_max_size] = ${PHP_UPLOAD_SIZE}|g" \
            "$PHP_FPM_CONF" 2>/dev/null ||
            echo "php_value[post_max_size] = ${PHP_UPLOAD_SIZE}" >>"$PHP_FPM_CONF"

        # pm.max_children: calculado com base na RAM disponível (~50MB por worker PHP)
        local php_workers=$((RAM_MB / 50))
        ((php_workers < 10)) && php_workers=10
        ((php_workers > 100)) && php_workers=100
        sed -i "s|^pm\.max_children\s*=.*|pm.max_children = ${php_workers}|g" \
            "$PHP_FPM_CONF" 2>/dev/null || true

        # pm.max_requests: limita vazamentos de memória reiniciando workers periodicamente
        sed -i "s|^pm\.max_requests\s*=.*|pm.max_requests = 200|g" \
            "$PHP_FPM_CONF" 2>/dev/null ||
            echo "pm.max_requests = 200" >>"$PHP_FPM_CONF"
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
        cat >/etc/zabbix/web/zabbix.conf.php <<ZCONF
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
        chown www-data:www-data /etc/zabbix/web/zabbix.conf.php 2>/dev/null ||
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
        cat >/etc/logrotate.d/zabbix <<'LOGEOF'
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
        CURRENT_STEP=$TOTAL_STEPS
        draw_progress "Instalação Perfeita! ✔"
        printf "\n"
    else
        CURRENT_STEP=$TOTAL_STEPS
        draw_progress "Instalação com Avisos ⚠"
        printf "\n"
    fi

    # Certificado
    clear
    start_certificate_export "server"
    [[ "$_CRITICAL_SERVICES_OK" != "1" ]] &&
        echo -e "${VERMELHO}${NEGRITO}⚠ UM OU MAIS SERVIÇOS CRÍTICOS NÃO ESTÃO ATIVOS. Verifique acima e execute: journalctl -xe --no-pager${RESET}\n"
    HOST_IP=$(hostname -I | awk '{print $1}')
    SV_RAM=$(free -m | awk '/^Mem/{print $2}')
    SV_CORES=$(nproc)
    echo -e "${VERDE}${NEGRITO}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${VERDE}${NEGRITO}║           CERTIFICADO — CAMADA DE SERVIDOR               ║${RESET}"
    echo -e "${VERDE}${NEGRITO}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo -e "\n${CIANO}${NEGRITO}▸ SISTEMA OPERACIONAL + HARDWARE${RESET}"
    command -v lsb_release >/dev/null 2>&1 &&
        printf "  %-34s %s\n" "Distribuição:" "$(lsb_release -ds)" ||
        printf "  %-34s %s\n" "Sistema:" "$OS_DISPLAY"
    printf "  %-34s %s\n" "Kernel:" "$(uname -r)"
    printf "  %-34s %s\n" "RAM total:" "${SV_RAM} MB"
    printf "  %-34s %s\n" "Núcleos CPU:" "${SV_CORES}"
    echo -e "\n${CIANO}${NEGRITO}▸ VERSÕES DOS PACOTES INSTALADOS${RESET}"
    printf "  %-34s %s\n" "zabbix-server-pgsql:" "$(package_version_or_na zabbix-server-pgsql)"
    printf "  %-34s %s\n" "nginx (binário):" "$(nginx -v 2>&1 | head -1 || echo N/D)"
    printf "  %-34s %s\n" "PHP ${PHP_VER} (binário):" "$(php${PHP_VER} --version 2>/dev/null | head -1 | cut -d' ' -f1-2 || echo N/D)"
    printf "  %-34s %s\n" "postgresql-client-${PG_VER}:" "$(package_version_or_na "postgresql-client-${PG_VER}")"
    [[ "$INSTALL_AGENT" == "1" ]] && printf "  %-34s %s\n" "zabbix-agent2:" "$(package_version_or_na zabbix-agent2)"
    echo -e "\n${CIANO}${NEGRITO}▸ ACESSO AO FRONTEND${RESET}"
    [[ "$USE_HTTPS" == "1" ]] && printf "  %-34s ${VERDE}%s${RESET}\n" "URL de Acesso:" "https://${HOST_IP}:${NGINX_PORT}" ||
        printf "  %-34s ${VERDE}%s${RESET}\n" "URL de Acesso:" "http://${HOST_IP}:${NGINX_PORT}"
    printf "  %-34s %s\n" "Utilizador padrão:" "Admin"
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
    printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "DBHost:" "$DB_HOST"
    printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "DBPort:" "$DB_PORT"
    printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "DBName:" "$DB_NAME"
    printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "DBUser:" "$DB_USER"
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
    [[ "$INSTALL_AGENT" == "1" ]] && systemctl is-active --quiet zabbix-agent2 2>/dev/null &&
        printf "  %-34s ${VERDE}%s${RESET}\n" "zabbix-agent2:" "ATIVO ✔"
    echo -e "\n${CIANO}${NEGRITO}▸ AUDITORIA: LINHAS ATIVAS NO SERVER.CONF${RESET}"
    timeout 10 awk '$0 !~ /^[[:space:]]*#/ && $0 !~ /^[[:space:]]*$/ { print "  " $0 }' "$SV_F" 2>/dev/null || true
    if [[ "$USE_PSK" == "1" && "$INSTALL_AGENT" == "1" ]]; then
        echo -e "\n${AMARELO}${NEGRITO}▸ CREDENCIAIS PSK — AGENT 2${RESET}"
        echo -e "  ------------------------------------------------------------"
        printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "IP desta máquina:" "$HOST_IP"
        printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "Hostname Agente:" "$AG_HOSTNAME"
        printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "PSK Identity:" "$PSK_AGENT_ID"
        printf "  ${NEGRITO}%-32s${RESET} ${VERMELHO}%s${RESET}\n" "PSK Secret Key:" "$PSK_AGENT_KEY"
        echo -e "  ------------------------------------------------------------"
    fi
    print_install_warnings
    echo -e "\n${CIANO}${NEGRITO}▸ EXPORTAÇÃO JSON${RESET}"
    write_install_summary_json "server"
    print_support_commands "server"
    echo -e "\n${NEGRITO}Log completo:${RESET} $LOG_FILE\n"
}
