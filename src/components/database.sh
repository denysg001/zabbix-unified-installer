# shellcheck shell=bash

# Database component: PostgreSQL, TimescaleDB, DB credentials, and optional Agent 2.
run_component_db() {
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
            echo "${param} = ${value}" >>"$file"
        fi
    }

    calc_pg_auto_tuning() {
        local ram=$RAM_MB
        if ((ram >= 16384)); then
            PG_MAX_CONN="500"
        elif ((ram >= 8192)); then
            PG_MAX_CONN="300"
        elif ((ram >= 4096)); then
            PG_MAX_CONN="200"
        else
            PG_MAX_CONN="100"
        fi
        local sb=$((ram * 25 / 100))
        ((sb < 128)) && sb=128
        ((sb > 8192)) && sb=8192
        PG_SHARED_BUF="${sb}MB"
        local wm=$((ram * 25 / 100 / PG_MAX_CONN))
        ((wm < 4)) && wm=4
        ((wm > 64)) && wm=64
        PG_WORK_MEM="${wm}MB"
        local mm=$((ram / 8))
        ((mm < 64)) && mm=64
        ((mm > 2048)) && mm=2048
        PG_MAINT_MEM="${mm}MB"
        local ec=$((ram * 75 / 100))
        ((ec < 256)) && ec=256
        PG_EFF_CACHE="${ec}MB"
        local wb=$((sb * 3 / 100))
        ((wb < 8)) && wb=8
        ((wb > 64)) && wb=64
        PG_WAL_BUFS="${wb}MB"
        PG_CKPT="0.9"
        PG_STATS="100"
        PG_RAND_COST="1.1"
    }

    # Variáveis de estado
    PG_VER="17"
    USE_TSDB_TUNE="1"
    ZBX_TARGET_VERSION="7.4"
    ZBX_AGENT_VERSION="7.4"
    ZBX_SERVER_IPS=()
    DB_NAME="zabbix"
    DB_USER="zabbix"
    DB_PASS=""
    UPDATE_SYSTEM="0"
    CLEAN_INSTALL=0
    USE_TUNING="0"
    INSTALL_AGENT="0"
    USE_PSK="0"
    AG_SERVER=""
    AG_SERVER_ACTIVE=""
    AG_HOSTNAME=""
    AG_ALLOWKEY="0"
    PSK_AGENT_ID=""
    PSK_AGENT_KEY=""
    PG_MAX_CONN="200"
    PG_SHARED_BUF="256MB"
    PG_WORK_MEM="8MB"
    PG_MAINT_MEM="128MB"
    PG_EFF_CACHE="768MB"
    PG_WAL_BUFS="16MB"
    PG_CKPT="0.9"
    PG_STATS="100"
    PG_RAND_COST="1.1"
    PG_CLUSTER_NAME="main"
    PG_CONF_FILE=""
    PG_HBA_FILE=""
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
        PG_LISTEN_ADDR="'*'" # fallback se deteção falhar
    fi

    # Banner BD
    clear
    echo -e "${VERMELHO}${NEGRITO}"
    cat <<"EOF"
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
            1)
                ZBX_TARGET_VERSION="7.0"
                break
                ;;
            2)
                ZBX_TARGET_VERSION="7.4"
                break
                ;;
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
            1)
                PG_VER="17"
                break
                ;;
            2)
                PG_VER="18"
                echo -e "\n   ${AMARELO}${NEGRITO}⚠  ATENÇÃO: PostgreSQL 18 + TimescaleDB pode ser experimental.${RESET}"
                break
                ;;
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
            idx=$((idx + 1))
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
        read -rp "   Valor Recomendado [zabbix]: " DB_NAME
        DB_NAME=${DB_NAME:-zabbix}
        validate_identifier "$DB_NAME" "Nome da base de dados"
        echo -e "\n${AMARELO}Utilizador da Base de Dados${RESET}"
        echo -e "   1) Gerar utilizador aleatório ${CIANO}(ex: zbx_f3a2b1c9)${RESET} — mais seguro"
        echo -e "   2) Usar o nome padrão ${CIANO}'zabbix'${RESET}          — convencional"
        echo -e "   3) Definir manualmente"
        while true; do
            read -rp "   Escolha (1, 2 ou 3): " u_opt
            case "$u_opt" in
            1)
                DB_USER="zbx_$(openssl rand -hex 4)"
                echo -e "   ${VERDE}Utilizador gerado: ${NEGRITO}${DB_USER}${RESET}"
                break
                ;;
            2)
                DB_USER="zabbix"
                echo -e "   ${VERDE}Utilizador: ${NEGRITO}${DB_USER}${RESET}"
                break
                ;;
            3)
                while true; do
                    read -rp "   Nome do utilizador: " DB_USER
                    [[ -n "$DB_USER" ]] && break
                    echo -e "   ${VERMELHO}Campo obrigatório.${RESET}"
                done
                break
                ;;
            *) echo -e "   ${VERMELHO}Opção inválida.${RESET}" ;;
            esac
        done
        echo -e "\n${AMARELO}Senha do Utilizador${RESET}"
        echo -e "   A senha é sempre gerada automaticamente (32 caracteres hex)."
        DB_PASS=$(openssl rand -hex 16)
        echo -e "   ${VERDE}Senha gerada: ${NEGRITO}$(mask_secret "$DB_PASS")${RESET}"
        local redef
        ask_yes_no "Redefinir a senha manualmente?" redef
        if [[ "$redef" == "1" ]]; then
            while true; do
                read -rsp "   Nova senha: " DB_PASS
                echo
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
            read -rp "   Valor recomendado [${default_server}]: " AG_SERVER
            AG_SERVER=${AG_SERVER:-$default_server}
            validate_zabbix_identity "$AG_SERVER" "Server do Agente"
            echo -e "\n${AMARELO}ServerActive${RESET} (envio ativo para o Server)"
            read -rp "   Valor recomendado [${default_server}]: " AG_SERVER_ACTIVE
            AG_SERVER_ACTIVE=${AG_SERVER_ACTIVE:-$default_server}
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
            USE_PSK="0"
            AG_ALLOWKEY="0"
            PSK_AGENT_ID=""
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
            echo -e "${VERMELHO}ERRO:${RESET} max_connections inválido: ${PG_MAX_CONN}"
            exit 1
        fi
    }

    m_pgtuning() {
        ask_yes_no "Aplicar Tuning Manual de Performance do PostgreSQL?" USE_TUNING
        if [[ "$USE_TUNING" == "1" ]]; then
            calc_pg_auto_tuning
            echo -e "\n${CIANO}${NEGRITO}>>> ASSISTENTE DE TUNING DO POSTGRESQL <<<${RESET}"
            echo -e "  ${NEGRITO}Hardware detetado: ${RAM_MB} MB RAM | ${CPU_CORES} núcleos${RESET}"
            echo -e "  Valores calculados automaticamente para este hardware:\n"
            printf "    %-34s ${VERDE}%s${RESET}\n" "shared_buffers (25% RAM):" "$PG_SHARED_BUF"
            printf "    %-34s ${VERDE}%s${RESET}\n" "work_mem:" "$PG_WORK_MEM"
            printf "    %-34s ${VERDE}%s${RESET}\n" "maintenance_work_mem (12.5%):" "$PG_MAINT_MEM"
            printf "    %-34s ${VERDE}%s${RESET}\n" "effective_cache_size (75%):" "$PG_EFF_CACHE"
            printf "    %-34s ${VERDE}%s${RESET}\n" "wal_buffers:" "$PG_WAL_BUFS"
            printf "    %-34s ${VERDE}%s${RESET}\n" "checkpoint_completion_target:" "$PG_CKPT"
            printf "    %-34s ${VERDE}%s${RESET}\n" "default_statistics_target:" "$PG_STATS"
            printf "    %-34s ${VERDE}%s${RESET}\n" "random_page_cost (SSD):" "$PG_RAND_COST"
            echo ""
            local use_auto
            ask_yes_no "Usar estes valores calculados automaticamente?" use_auto
            if [[ "$use_auto" == "0" ]]; then
                echo -e "\n  Prima [ENTER] para usar o valor calculado entre [colchetes].\n"

                echo -e "${AMARELO}1. shared_buffers${RESET} (25% da RAM | Padrão PG: 128MB)"
                echo -e "   Cache de dados em memória. Regra geral: 25% da RAM total."
                read -rp "   Valor calculado [${PG_SHARED_BUF}]: " _v
                PG_SHARED_BUF=${_v:-$PG_SHARED_BUF}

                echo -e "\n${AMARELO}3. work_mem${RESET} (Padrão PG: 4MB)"
                echo -e "   Memória por operação de ordenação/hash. Multiplica por conexões ativas."
                read -rp "   Valor calculado [${PG_WORK_MEM}]: " _v
                PG_WORK_MEM=${_v:-$PG_WORK_MEM}

                echo -e "\n${AMARELO}4. maintenance_work_mem${RESET} (12.5% da RAM | Padrão PG: 64MB)"
                echo -e "   Memória para VACUUM, CREATE INDEX, etc."
                read -rp "   Valor calculado [${PG_MAINT_MEM}]: " _v
                PG_MAINT_MEM=${_v:-$PG_MAINT_MEM}

                echo -e "\n${AMARELO}5. effective_cache_size${RESET} (75% da RAM | Padrão PG: 4GB)"
                echo -e "   Estimativa do cache disponível ao PostgreSQL (SO + PG). Ajuda o planeador."
                read -rp "   Valor calculado [${PG_EFF_CACHE}]: " _v
                PG_EFF_CACHE=${_v:-$PG_EFF_CACHE}

                echo -e "\n${AMARELO}6. wal_buffers${RESET} (3% de shared_buffers | Padrão PG: auto)"
                echo -e "   Buffer de memória para o Write-Ahead Log. Melhora escrita em disco."
                read -rp "   Valor calculado [${PG_WAL_BUFS}]: " _v
                PG_WAL_BUFS=${_v:-$PG_WAL_BUFS}

                echo -e "\n${AMARELO}7. checkpoint_completion_target${RESET} (Padrão PG: 0.9)"
                echo -e "   Fracção do intervalo de checkpoint para distribuir a escrita. 0.9 é ideal."
                read -rp "   Valor calculado [${PG_CKPT}]: " _v
                PG_CKPT=${_v:-$PG_CKPT}

                echo -e "\n${AMARELO}8. default_statistics_target${RESET} (Padrão PG: 100)"
                echo -e "   Detalhe das estatísticas do planeador. Mais alto = queries mais eficientes."
                read -rp "   Valor calculado [${PG_STATS}]: " _v
                PG_STATS=${_v:-$PG_STATS}

                echo -e "\n${AMARELO}9. random_page_cost${RESET} (SSD: 1.1 | HDD: 4.0 | Padrão PG: 4.0)"
                echo -e "   Custo estimado de acesso aleatório. Use 1.1 para SSD, 4.0 para HDD."
                read -rp "   Valor calculado [${PG_RAND_COST}]: " _v
                PG_RAND_COST=${_v:-$PG_RAND_COST}
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

    m_clean
    m_update
    m_versions
    m_zbxserver_ip
    m_dbcreds
    m_agent
    m_max_connections
    m_tsdb_tune
    m_pgtuning
    m_timezone

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
        echo -e "  ${AMARELO}6)${RESET} Acesso Remoto (IPs):  ${NEGRITO}$(
            IFS=', '
            echo "${ZBX_SERVER_IPS[*]:-<não definido>}"
        )${RESET}  ${AMARELO}← Zabbix Server (pg_hba.conf)${RESET}"
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
        2) m_update ;; 3 | 4) m_versions ;; 5 | 6) m_zbxserver_ip ;; 7 | 8) m_dbcreds ;;
        9 | 10) m_agent ;; 11) m_max_connections ;; 12) m_tsdb_tune ;; 13) m_pgtuning ;;
        14) m_timezone ;;
        15)
            echo -e "${VERMELHO}Instalação abortada pelo utilizador.${RESET}"
            exit 1
            ;;
        0) break ;;
        esac
    done

    # Pipeline
    confirm_execution_summary "DB"
    validate_compatibility_matrix "db"
    echo -e "\n${CIANO}${NEGRITO}A processar pipeline... Não cancele a operação!${RESET}\n"
    preflight_install_check "db" 4096 1024
    TOTAL_STEPS=20 # +1 para apt-mark hold
    [[ "$CLEAN_INSTALL" == "1" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 3))
    [[ "$UPDATE_SYSTEM" == "1" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
    [[ "$INSTALL_AGENT" == "1" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 9))
    [[ "$USE_PSK" == "1" && "$INSTALL_AGENT" == "1" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
    _IS_CONTAINER=0
    systemd-detect-virt -c -q 2>/dev/null && _IS_CONTAINER=1 || true
    [[ "$_IS_CONTAINER" == "0" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 2)) # timedatectl + NTP
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

    setup_timezone_ntp "$DB_TIMEZONE"
    run_step "Destravando processos do APT" auto_repair_apt
    run_step "Atualizando caches locais" apt-get update
    [[ "$SIMULATE_MODE" != "1" ]] && validate_packages_available \
        curl wget ca-certificates gnupg apt-transport-https lsb-release locales

    [[ "$INSTALL_AGENT" == "1" ]] &&
        run_step "Removendo instalação anterior do Zabbix Agent 2 da BD" bash -c \
            "timeout 15 systemctl stop zabbix-agent2 2>/dev/null || true; \
             systemctl disable zabbix-agent2 2>/dev/null || true; \
             pkill -9 -x zabbix_agent2 2>/dev/null || true; \
             apt-mark unhold zabbix-agent2 2>/dev/null || true; \
             apt-get purge -y zabbix-agent2 2>/dev/null || true; \
             rm -rf /etc/zabbix /var/lib/zabbix /var/log/zabbix /run/zabbix 2>/dev/null || true"

    [[ "$UPDATE_SYSTEM" == "1" ]] &&
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
        run_step "Baixando repositório oficial Zabbix ${ZBX_AGENT_VERSION}" _wget -q "$REPO_URL" -O /tmp/zbx_repo.deb
        run_step "Registando repositório Zabbix para Agent 2" dpkg --force-confmiss -i /tmp/zbx_repo.deb
        run_step "Sincronizando repositório Zabbix" apt-get update
        run_step "Verificando acesso ao repositório Zabbix ${ZBX_AGENT_VERSION}" verify_zabbix_repo_active zabbix-agent2
        run_step "Instalando Zabbix Agent 2" apt-get install "${APT_FLAGS[@]}" zabbix-agent2
    fi

    setup_pgdg_repo() {
        install -d /usr/share/postgresql-common/pgdg
        _curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
            https://www.postgresql.org/media/keys/ACCC4CF8.asc
        echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
https://apt.postgresql.org/pub/repos/apt ${U_CODENAME}-pgdg main" \
            >/etc/apt/sources.list.d/pgdg.list
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
        if ! _curl -fsL --max-time 15 \
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
            _curl -fsSL https://packagecloud.io/timescale/timescaledb/gpgkey |
                gpg --batch --yes --dearmor -o /etc/apt/trusted.gpg.d/timescaledb.gpg
            echo "deb https://packagecloud.io/timescale/timescaledb/$(timescale_repo_os)/ ${U_CODENAME} main" \
                >/etc/apt/sources.list.d/timescaledb.list
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
        timeout 20 systemctl start "postgresql@${PG_VER}-${PG_CLUSTER_NAME}" 2>/dev/null ||
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
                sed -i "0,/^#[[:space:]]*shared_preload_libraries/{s|^#[[:space:]]*shared_preload_libraries.*|shared_preload_libraries = '${lib}'|}" "$PG_CONF" 2>/dev/null ||
                    echo "shared_preload_libraries = '${lib}'" >>"$PG_CONF"
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
            max_workers=$((CPU_CORES + 4))
            ((max_workers < 8)) && max_workers=8
            ((max_workers > 16)) && max_workers=16
            ts_workers="$CPU_CORES"
            ((ts_workers < 2)) && ts_workers=2
            ((ts_workers > 8)) && ts_workers=8
            parallel_workers="$CPU_CORES"
            ((parallel_workers < 2)) && parallel_workers=2
            ((parallel_workers > 8)) && parallel_workers=8

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
            timeout 20 systemctl start "postgresql@${PG_VER}-${PG_CLUSTER_NAME}" 2>/dev/null ||
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
            set_pg_config "$PG_CONF" "shared_buffers" "$PG_SHARED_BUF"
            set_pg_config "$PG_CONF" "work_mem" "$PG_WORK_MEM"
            set_pg_config "$PG_CONF" "maintenance_work_mem" "$PG_MAINT_MEM"
            set_pg_config "$PG_CONF" "effective_cache_size" "$PG_EFF_CACHE"
            set_pg_config "$PG_CONF" "wal_buffers" "$PG_WAL_BUFS"
            set_pg_config "$PG_CONF" "checkpoint_completion_target" "$PG_CKPT"
            set_pg_config "$PG_CONF" "default_statistics_target" "$PG_STATS"
            set_pg_config "$PG_CONF" "random_page_cost" "$PG_RAND_COST"
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
                echo "host    ${DB_NAME}    ${DB_USER}    0.0.0.0/0               scram-sha-256" >>"$PG_HBA"
                echo "host    ${DB_NAME}    ${DB_USER}    ::0/0                   scram-sha-256" >>"$PG_HBA"
            elif [[ "$entry" =~ / ]]; then
                echo "host    ${DB_NAME}    ${DB_USER}    ${entry}    scram-sha-256" >>"$PG_HBA"
            else
                echo "host    ${DB_NAME}    ${DB_USER}    ${entry}/32             scram-sha-256" >>"$PG_HBA"
            fi
        done
    }
    run_step "Configurando pg_hba.conf (acesso remoto para ${#ZBX_SERVER_IPS[@]} entrada(s))" configure_pg_hba
    restart_postgres_cluster() {
        if command -v pg_ctlcluster >/dev/null 2>&1; then
            timeout 45 pg_ctlcluster "$PG_VER" "$PG_CLUSTER_NAME" restart
        else
            timeout 45 systemctl restart "postgresql@${PG_VER}-${PG_CLUSTER_NAME}" 2>/dev/null ||
                timeout 45 systemctl restart postgresql
        fi
    }
    wait_for_postgres_ready() {
        local timeout_s="${1:-30}" waited=0 cluster_service="postgresql@${PG_VER}-${PG_CLUSTER_NAME}"
        log_msg "INFO" "Aguardando PostgreSQL ${PG_VER}/${PG_CLUSTER_NAME} responder por até ${timeout_s}s"
        while ((waited < timeout_s)); do
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
            waited=$((waited + 2))
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
        postgres_psql_timeout 45 -tc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" |
            awk '$1==1{found=1} END{exit !found}' 2>/dev/null ||
            postgres_psql_timeout 45 -c "CREATE USER ${DB_USER_IDENT} WITH PASSWORD ${DB_PASS_SQL};"
        postgres_psql_timeout 45 -c "ALTER USER ${DB_USER_IDENT} WITH PASSWORD ${DB_PASS_SQL};"
        postgres_psql_timeout 45 -tc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" |
            awk '$1==1{found=1} END{exit !found}' 2>/dev/null ||
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
    if [[ "$INSTALL_AGENT" == "1" && (-f "$AG_F" || "$SIMULATE_MODE" == "1") ]]; then
        apply_db_agent_config() {
            set_config "$AG_F" "Server" "$AG_SERVER"
            set_config "$AG_F" "ServerActive" "$AG_SERVER_ACTIVE"
            set_config "$AG_F" "Hostname" "$AG_HOSTNAME"
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
            echo "$PSK_AGENT_KEY" >/etc/zabbix/zabbix_agent2.psk
            chown zabbix:zabbix /etc/zabbix/zabbix_agent2.psk
            chmod 600 /etc/zabbix/zabbix_agent2.psk
            set_config "$AG_F" "TLSAccept" "psk"
            set_config "$AG_F" "TLSConnect" "psk"
            set_config "$AG_F" "TLSPSKIdentity" "$PSK_AGENT_ID"
            set_config "$AG_F" "TLSPSKFile" "/etc/zabbix/zabbix_agent2.psk"
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
    start_certificate_export "db"
    [[ "$_CRITICAL_SERVICES_OK" != "1" ]] &&
        echo -e "${VERMELHO}${NEGRITO}⚠ UM OU MAIS SERVIÇOS CRÍTICOS NÃO ESTÃO ATIVOS. Verifique acima e execute: journalctl -xe --no-pager${RESET}\n"
    HOST_IP=$(hostname -I | awk '{print $1}')
    PG_CONF="${PG_CONF_FILE:-/etc/postgresql/${PG_VER}/${PG_CLUSTER_NAME}/postgresql.conf}"
    PG_HBA="${PG_HBA_FILE:-/etc/postgresql/${PG_VER}/${PG_CLUSTER_NAME}/pg_hba.conf}"
    echo -e "${VERDE}${NEGRITO}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${VERDE}${NEGRITO}║           CERTIFICADO — CAMADA DE BASE DE DADOS          ║${RESET}"
    echo -e "${VERDE}${NEGRITO}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo -e "\n${CIANO}${NEGRITO}▸ SISTEMA OPERACIONAL + HARDWARE${RESET}"
    command -v lsb_release >/dev/null 2>&1 &&
        printf "  %-34s %s\n" "Distribuição:" "$(lsb_release -ds)" ||
        printf "  %-34s %s\n" "Sistema:" "$OS_DISPLAY"
    printf "  %-34s %s\n" "Kernel:" "$(uname -r)"
    printf "  %-34s %s\n" "RAM total:" "${RAM_MB} MB"
    printf "  %-34s %s\n" "Núcleos CPU:" "${CPU_CORES}"
    echo -e "\n${CIANO}${NEGRITO}▸ REDE DO HOST${RESET}"
    printf "  %-34s %s\n" "IP desta máquina (BD):" "$HOST_IP"
    printf "  %-34s %s\n" "IPs autorizados (pg_hba.conf):" "$(
        IFS=', '
        echo "${ZBX_SERVER_IPS[*]}"
    )"
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
        systemctl is-active --quiet zabbix-agent2 2>/dev/null &&
            printf "  %-34s ${VERDE}%s${RESET}\n" "zabbix-agent2:" "ATIVO ✔" ||
            printf "  %-34s ${VERMELHO}%s${RESET}\n" "zabbix-agent2:" "FALHOU ✖"
    fi
    echo -e "\n${CIANO}${NEGRITO}▸ VERSÕES DOS PACOTES INSTALADOS${RESET}"
    PG_PKG_VER=$(package_version "postgresql-${PG_VER}")
    TSDB_PKG_VER=$(package_version "timescaledb-2-postgresql-${PG_VER}")
    TSDB_EXT_VER=$(postgres_psql_timeout 45 -d "${DB_NAME}" -tAc \
        "SELECT extversion FROM pg_extension WHERE extname='timescaledb';" 2>/dev/null | xargs || echo "N/D")
    printf "  %-34s %s\n" "postgresql-${PG_VER} (pacote):" "${PG_PKG_VER:-N/D}"
    printf "  %-34s %s\n" "timescaledb-2-postgresql-${PG_VER}:" "${TSDB_PKG_VER:-N/D}"
    printf "  %-34s %s\n" "TimescaleDB (extensão na BD):" "${TSDB_EXT_VER}"
    printf "  %-34s %s\n" "timescaledb-tune:" "${TSDB_TUNE_STATUS:-não executado}"
    [[ "$INSTALL_AGENT" == "1" ]] && printf "  %-34s %s\n" "zabbix-agent2:" "$(package_version_or_na zabbix-agent2)"
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
    printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "Porta DB:" "5432"
    printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "Nome da Base de Dados:" "$DB_NAME"
    printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "Utilizador:" "$DB_USER"
    printf "  ${NEGRITO}%-32s${RESET} ${VERMELHO}%s${RESET}\n" "Senha:" "$DB_PASS"
    printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "DBUser:" "$DB_USER"
    printf "  ${NEGRITO}%-32s${RESET} ${VERMELHO}%s${RESET}\n" "DBPassword:" "$DB_PASS"
    printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "PostgreSQL versão:" "$PG_VER"
    if [[ "$TSDB_AVAILABLE" == "1" ]]; then
        printf "  ${NEGRITO}%-32s${RESET} ${VERDE}%s${RESET}\n" "TimescaleDB:" "INSTALADO ✔  (importar timescaledb.sql no Server)"
    else
        printf "  ${NEGRITO}%-32s${RESET} ${AMARELO}%s${RESET}\n" "TimescaleDB:" "NÃO INSTALADO — repositório/pacote indisponível"
    fi
    echo -e "  ------------------------------------------------------------"
    if [[ "$INSTALL_AGENT" == "1" ]]; then
        echo -e "\n${AMARELO}${NEGRITO}▸ CREDENCIAIS PARA CADASTRAR O AGENT 2 DA BD${RESET}"
        echo -e "  ------------------------------------------------------------"
        printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "IP desta máquina:" "$HOST_IP"
        printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "Hostname Agente:" "$AG_HOSTNAME"
        printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "Server:" "$AG_SERVER"
        printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "ServerActive:" "$AG_SERVER_ACTIVE"
        printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "Versão repo Zabbix:" "$ZBX_AGENT_VERSION"
        if [[ "$USE_PSK" == "1" ]]; then
            printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "PSK Identity:" "$PSK_AGENT_ID"
            printf "  ${NEGRITO}%-32s${RESET} ${VERMELHO}%s${RESET}\n" "PSK Secret Key:" "$PSK_AGENT_KEY"
        fi
        echo -e "  ------------------------------------------------------------"
    fi
    print_install_warnings
    echo -e "\n${CIANO}${NEGRITO}▸ EXPORTAÇÃO JSON${RESET}"
    write_install_summary_json "db"
    print_support_commands "db"
    echo -e "\n${NEGRITO}Log completo:${RESET} $LOG_FILE\n"
}
