# shellcheck shell=bash

# Proxy component: Zabbix Proxy with SQLite3 and optional local Agent 2.
run_component_proxy() {
    component_supported_or_die "proxy"

    if [[ "$SIMULATE_MODE" == "1" ]]; then
        LOG_FILE=""
    else
        init_install_log "proxy" "/var/log/zabbix_proxy_install_$(date +%Y%m%d_%H%M%S).log"
    fi
    log_msg "INFO" "Log iniciado para componente Proxy em ${LOG_FILE}"

    # Variáveis de estado
    T_UNREACH="45"
    T_PING="5"
    T_DISC="5"
    T_HTTP="1"
    T_PUNREACH="5"
    T_TRAP="5"
    T_APOLL="1"
    T_HAPOLL="1"
    T_SPOLL="10"
    T_BPOLL="1"
    T_ODBCPOLL="1"
    T_MAXC="1000"
    T_CFG_FREQ="10"
    T_SND_FREQ="1"
    T_OFFLINE="1"
    T_BUF_MOD="hybrid"
    T_BUF_SZ="16M"
    T_BUF_AGE="0"
    PROXY_PERF_PROFILE=""
    CLEAN_INSTALL=0
    UPDATE_SYSTEM=0
    ZBX_VERSION="7.0"
    PROXY_MODE="0"
    PROXY_TIMEZONE="${SYS_TIMEZONE:-America/Sao_Paulo}"

    clamp_int() {
        local value="$1" min="$2" max="$3"
        ((value < min)) && value="$min"
        ((value > max)) && value="$max"
        echo "$value"
    }
    calc_proxy_auto_performance() {
        if ((RAM_MB < 4096)); then
            PROXY_PERF_PROFILE="mínimo"
            T_CACHE="64M"
            T_HCACHE="64M"
            T_HICACHE="16M"
            T_DBSYNC="2"
            T_POLL=$(clamp_int $((CPU_CORES * 2)) 4 10)
            T_PREPROC=$(clamp_int $((CPU_CORES * 2)) 4 8)
        elif ((RAM_MB < 8192)); then
            PROXY_PERF_PROFILE="baixo"
            T_CACHE="128M"
            T_HCACHE="128M"
            T_HICACHE="32M"
            T_DBSYNC="2"
            T_POLL=$(clamp_int $((CPU_CORES * 3)) 10 20)
            T_PREPROC=$(clamp_int $((CPU_CORES * 3)) 8 16)
        elif ((RAM_MB <= 16384)); then
            PROXY_PERF_PROFILE="médio"
            T_CACHE="256M"
            T_HCACHE="256M"
            T_HICACHE="64M"
            T_DBSYNC="4"
            T_POLL=$(clamp_int $((CPU_CORES * 4)) 20 40)
            T_PREPROC=$(clamp_int $((CPU_CORES * 4)) 16 32)
        else
            PROXY_PERF_PROFILE="alto"
            T_CACHE="512M"
            T_HCACHE="512M"
            T_HICACHE="128M"
            T_DBSYNC="8"
            T_POLL=$(clamp_int $((CPU_CORES * 5)) 40 80)
            T_PREPROC=$(clamp_int $((CPU_CORES * 5)) 32 64)
        fi
    }
    calc_proxy_auto_performance
    ZBX_SERVER=""
    ZBX_HOSTNAME=""
    INSTALL_AGENT="0"
    ENABLE_REMOTE="0"
    USE_PSK="0"
    USE_TUNING="0"
    PSK_PROXY_ID=""
    PSK_AGENT_ID=""
    PSK_PROXY_KEY=""
    PSK_AGENT_KEY=""
    AG_SERVER="127.0.0.1"
    AG_SERVER_ACTIVE="127.0.0.1"
    AG_HOSTNAME=""
    AG_ALLOWKEY="0"

    # Banner Proxy
    clear
    echo -e "${VERMELHO}${NEGRITO}"
    cat <<"EOF"
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
            read -rp "   Valor Recomendado [0]: " pm_opt
            pm_opt=${pm_opt:-0}
            case "$pm_opt" in
            0)
                PROXY_MODE="0"
                break
                ;;
            1)
                PROXY_MODE="1"
                break
                ;;
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
            if validate_proxy_server_value "$ZBX_SERVER" "$PROXY_MODE" "Server do Proxy"; then
                break
            fi
        done
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
            local agent_default
            agent_default=$(first_endpoint_host "$ZBX_SERVER" 2>/dev/null || true)
            [[ -z "$agent_default" || "$PROXY_MODE" != "0" ]] && agent_default="127.0.0.1"
            echo -e "\n${AMARELO}Server${RESET} (Escuta Passiva autorizada no Agent 2)"
            echo -e "   Em Proxy ativo, use o IP/DNS real do Zabbix Server, não localhost."
            while true; do
                read -rp "   Valor Recomendado [${agent_default}]: " AG_SERVER
                AG_SERVER=${AG_SERVER:-$agent_default}
                if [[ "$PROXY_MODE" == "0" ]]; then
                    validate_proxy_server_value "$AG_SERVER" "$PROXY_MODE" "Server do Agente" && break
                else
                    validate_zabbix_identity "$AG_SERVER" "Server do Agente"
                    break
                fi
            done
            echo -e "\n${AMARELO}ServerActive${RESET} (Envio Ativo do Agent 2)"
            echo -e "   Em Proxy ativo, use o IP/DNS real do Zabbix Server, não localhost."
            while true; do
                read -rp "   Valor Recomendado [${agent_default}]: " AG_SERVER_ACTIVE
                AG_SERVER_ACTIVE=${AG_SERVER_ACTIVE:-$agent_default}
                if [[ "$PROXY_MODE" == "0" ]]; then
                    validate_proxy_server_value "$AG_SERVER_ACTIVE" "$PROXY_MODE" "ServerActive do Agente" && break
                else
                    validate_zabbix_identity "$AG_SERVER_ACTIVE" "ServerActive do Agente"
                    break
                fi
            done
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
            read -rp "   Valor Recomendado [${T_CACHE}]: " _v
            T_CACHE=${_v:-$T_CACHE}

            echo -e "\n${AMARELO}2. StartDBSyncers${RESET} (Limites: 1-100 | Padrão Zabbix: 4)"
            echo -e "   Número de instâncias que sincronizam ativamente a memória com a Base de Dados."
            read -rp "   Valor Recomendado [${T_DBSYNC}]: " _v
            T_DBSYNC=${_v:-$T_DBSYNC}

            echo -e "\n${AMARELO}3. HistoryCacheSize${RESET} (Limites: 128K-16G | Padrão Zabbix: 16M)"
            echo -e "   Tamanho da memória partilhada para guardar métricas recentes antes de escrever no disco."
            read -rp "   Valor Recomendado [${T_HCACHE}]: " _v
            T_HCACHE=${_v:-$T_HCACHE}

            echo -e "\n${AMARELO}4. HistoryIndexCacheSize${RESET} (Limites: 128K-16G | Padrão Zabbix: 4M)"
            echo -e "   Memória partilhada dedicada à indexação do histórico, que agiliza muito a procura."
            read -rp "   Valor Recomendado [${T_HICACHE}]: " _v
            T_HICACHE=${_v:-$T_HICACHE}

            echo -e "\n${AMARELO}5. Timeout${RESET} (Limites: 1-30 | Padrão Zabbix: 3)"
            echo -e "   Tempo máximo em segundos que o Proxy espera por respostas de rede ou agentes."
            read -rp "   Valor Recomendado [4]: " T_TOUT
            T_TOUT=${T_TOUT:-4}

            echo -e "\n${AMARELO}6. UnreachablePeriod${RESET} (Limites: 1-3600 | Padrão Zabbix: 45)"
            echo -e "   Segundos sem resposta até o Zabbix considerar que um host está incontactável."
            read -rp "   Valor Recomendado [45]: " T_UNREACH
            T_UNREACH=${T_UNREACH:-45}

            echo -e "\n${AMARELO}7. StartPingers${RESET} (Limites: 0-1000 | Padrão Zabbix: 1)"
            echo -e "   Número de processos em background que efetuam exclusivamente testes de ICMP (Ping)."
            read -rp "   Valor Recomendado [5]: " T_PING
            T_PING=${T_PING:-5}

            echo -e "\n${AMARELO}8. StartDiscoverers${RESET} (Limites: 0-1000 | Padrão Zabbix: 5)"
            echo -e "   Número de processos dedicados à pesquisa (Discovery) na rede."
            read -rp "   Valor Recomendado [5]: " T_DISC
            T_DISC=${T_DISC:-5}

            echo -e "\n${AMARELO}9. StartHTTPPollers${RESET} (Limites: 0-1000 | Padrão Zabbix: 1)"
            echo -e "   Número de processos dedicados a recolhas e testes de cenários Web HTTP."
            read -rp "   Valor Recomendado [1]: " T_HTTP
            T_HTTP=${T_HTTP:-1}

            echo -e "\n${AMARELO}10. StartPreprocessors${RESET} (Limites: 1-1000 | Padrão Zabbix: 16)"
            echo -e "   Threads focadas em converter, calcular e processar dados brutos antes da cache."
            read -rp "   Valor Recomendado [${T_PREPROC}]: " _v
            T_PREPROC=${_v:-$T_PREPROC}

            echo -e "\n${AMARELO}11. StartPollersUnreachable${RESET} (Limites: 0-1000 | Padrão Zabbix: 1)"
            echo -e "   Coletores passivos destacados só para equipamentos em estado 'caído', evitando atrasar os saudáveis."
            read -rp "   Valor Recomendado [5]: " T_PUNREACH
            T_PUNREACH=${T_PUNREACH:-5}

            echo -e "\n${AMARELO}12. StartTrappers${RESET} (Limites: 0-1000 | Padrão Zabbix: 5)"
            echo -e "   Processos dedicados a receber fluxos de Agentes Ativos e do Zabbix Sender."
            read -rp "   Valor Recomendado [5]: " T_TRAP
            T_TRAP=${T_TRAP:-5}

            echo -e "\n${AMARELO}13. StartPollers${RESET} (Limites: 0-1000 | Padrão Zabbix: 5)"
            echo -e "   Coletores passivos genéricos (adequados para Zabbix Agent 1 e scripts comuns)."
            read -rp "   Valor Recomendado [${T_POLL}]: " _v
            T_POLL=${_v:-$T_POLL}

            echo -e "\n${AMARELO}14. StartAgentPollers${RESET} (Limites: 0-1000 | Padrão Zabbix: 1)"
            echo -e "   Coletores assíncronos modernos de alta concorrência para o Zabbix Agent."
            read -rp "   Valor Recomendado [1]: " T_APOLL
            T_APOLL=${T_APOLL:-1}

            echo -e "\n${AMARELO}15. StartHTTPAgentPollers${RESET} (Limites: 0-1000 | Padrão Zabbix: 1)"
            echo -e "   Coletores assíncronos de alta concorrência para o HTTP Agent."
            read -rp "   Valor Recomendado [1]: " T_HAPOLL
            T_HAPOLL=${T_HAPOLL:-1}

            echo -e "\n${AMARELO}16. StartSNMPPollers${RESET} (Limites: 0-1000 | Padrão Zabbix: 1)"
            echo -e "   Coletores assíncronos de altíssima eficiência dedicados a queries de SNMP."
            read -rp "   Valor Recomendado [10]: " T_SPOLL
            T_SPOLL=${T_SPOLL:-10}

            echo -e "\n${AMARELO}17. StartBrowserPollers${RESET} (Limites: 0-1000 | Padrão Zabbix: 1)"
            echo -e "   Coletores assíncronos dedicados a itens de monitorização via Browser (Zabbix 7.0+)."
            read -rp "   Valor Recomendado [1]: " T_BPOLL
            T_BPOLL=${T_BPOLL:-1}

            echo -e "\n${AMARELO}18. StartODBCPollers${RESET} (Limites: 0-1000 | Padrão Zabbix: 1)"
            echo -e "   Coletores dedicados a itens de Base de Dados via ODBC (DB Monitor)."
            read -rp "   Valor Recomendado [1]: " T_ODBCPOLL
            T_ODBCPOLL=${T_ODBCPOLL:-1}

            echo -e "\n${AMARELO}19. MaxConcurrentChecksPerPoller${RESET} (Limites: 1-1000 | Padrão Zabbix: 1000)"
            echo -e "   Número máximo de métricas que UM único poller assíncrono consegue processar a cada ciclo."
            read -rp "   Valor Recomendado [1000]: " T_MAXC
            T_MAXC=${T_MAXC:-1000}

            echo -e "\n${AMARELO}20. ProxyConfigFrequency${RESET} (Limites: 1-604800 | Padrão Zabbix: 10)"
            echo -e "   Intervalo em segundos para que o Proxy (Ativo) descarregue configurações novas do Server."
            read -rp "   Valor Recomendado [10]: " T_CFG_FREQ
            T_CFG_FREQ=${T_CFG_FREQ:-10}

            echo -e "\n${AMARELO}21. DataSenderFrequency${RESET} (Limites: 1-3600 | Padrão Zabbix: 1)"
            echo -e "   Intervalo em segundos para que o Proxy (Ativo) envie os seus dados para o Server."
            read -rp "   Valor Recomendado [1]: " T_SND_FREQ
            T_SND_FREQ=${T_SND_FREQ:-1}

            echo -e "\n${AMARELO}22. ProxyOfflineBuffer${RESET} (Limites: 1-720 | Padrão Zabbix: 1)"
            echo -e "   Mantém os dados acumulados durante N 'Horas' caso a ligação ao Zabbix Server falhe."
            read -rp "   Valor Recomendado [1]: " T_OFFLINE
            T_OFFLINE=${T_OFFLINE:-1}

            echo -e "\n${AMARELO}23. ProxyBufferMode${RESET} (Opções: disk, memory, hybrid | Padrão Zabbix: disk)"
            echo -e "   Motor de cache. A opção 'hybrid' aproveita a RAM para aceleração bruta e descarrega no disco se encher."
            while true; do
                read -rp "   Valor Recomendado [hybrid]: " T_BUF_MOD
                T_BUF_MOD=${T_BUF_MOD:-hybrid}
                [[ "$T_BUF_MOD" =~ ^(disk|memory|hybrid)$ ]] && break
                echo "  Escolha 'disk', 'memory' ou 'hybrid'."
            done

            if [[ "$T_BUF_MOD" == "memory" || "$T_BUF_MOD" == "hybrid" ]]; then
                echo -e "\n${AMARELO}24. ProxyMemoryBufferSize${RESET} (Limites: 0, 128K-2G | Padrão Zabbix: 0)"
                echo -e "   Tamanho fixo da memória RAM alocada ao buffer (Modo Memory/Hybrid)."
                read -rp "   Valor Recomendado [16M]: " T_BUF_SZ
                T_BUF_SZ=${T_BUF_SZ:-16M}

                echo -e "\n${AMARELO}25. ProxyMemoryBufferAge${RESET} (Limites: 0, 600-864000 | Padrão Zabbix: 0)"
                echo -e "   Tempo limite (em segundos) que a cache fica na RAM antes de ser forçada para a BD."
                read -rp "   Valor Recomendado [0]: " T_BUF_AGE
                T_BUF_AGE=${T_BUF_AGE:-0}
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

    m_clean
    m_update
    m_version
    m_proxy_mode
    m_proxy_net
    m_agent
    m_security
    m_tuning
    m_timezone

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
        2) m_update ;; 3) m_version ;; 4) m_proxy_mode ;; 5 | 6) m_proxy_net ;;
        7) m_agent ;; 8 | 9) m_security ;; 10 | 11) m_tuning ;;
        12) m_timezone ;;
        13)
            echo -e "${VERMELHO}Instalação abortada pelo utilizador.${RESET}"
            exit 1
            ;;
        0) break ;;
        esac
    done

    # Pipeline
    confirm_execution_summary "Proxy"
    validate_compatibility_matrix "proxy"
    echo -e "\n${CIANO}${NEGRITO}A processar pipeline... Não cancele a operação!${RESET}\n"
    preflight_install_check "proxy" 2048 1024
    TOTAL_STEPS=15 # +1 para apt-mark hold
    [[ "$CLEAN_INSTALL" == "1" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 3))
    [[ "$UPDATE_SYSTEM" == "1" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
    [[ "$INSTALL_AGENT" == "1" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
    [[ "$USE_PSK" == "1" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
    _IS_CONTAINER=0
    systemd-detect-virt -c -q 2>/dev/null && _IS_CONTAINER=1 || true
    [[ "$_IS_CONTAINER" == "0" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 2)) # timedatectl + NTP
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

    setup_timezone_ntp "$PROXY_TIMEZONE"
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
    run_step "Baixando Repo Oficial Zabbix" _wget -q "$REPO_URL" -O /tmp/zbx_repo.deb
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
        set_config "$PX_F" "Server" "$ZBX_SERVER"
        set_config "$PX_F" "Hostname" "$ZBX_HOSTNAME"
        set_config "$PX_F" "DBName" "/var/lib/zabbix/zabbix_proxy.db"
        set_config "$PX_F" "LogType" "file"
        set_config "$PX_F" "LogFile" "/var/log/zabbix/zabbix_proxy.log"
        set_config "$PX_F" "EnableRemoteCommands" ""
        set_config "$PX_F" "AllowKey" ""
        set_config "$PX_F" "CacheSize" "$T_CACHE"
        set_config "$PX_F" "StartDBSyncers" "$T_DBSYNC"
        set_config "$PX_F" "HistoryCacheSize" "$T_HCACHE"
        set_config "$PX_F" "StartPollers" "$T_POLL"
        set_config "$PX_F" "StartPreprocessors" "$T_PREPROC"
        if [[ "$USE_TUNING" == "1" ]]; then
            set_config "$PX_F" "HistoryIndexCacheSize" "$T_HICACHE"
            set_config "$PX_F" "Timeout" "$T_TOUT"
            set_config "$PX_F" "UnreachablePeriod" "$T_UNREACH"
            set_config "$PX_F" "StartPingers" "$T_PING"
            set_config "$PX_F" "StartDiscoverers" "$T_DISC"
            set_config "$PX_F" "StartHTTPPollers" "$T_HTTP"
            set_config "$PX_F" "StartPollersUnreachable" "$T_PUNREACH"
            set_config "$PX_F" "StartTrappers" "$T_TRAP"
            set_config "$PX_F" "StartAgentPollers" "$T_APOLL"
            set_config "$PX_F" "StartHTTPAgentPollers" "$T_HAPOLL"
            set_config "$PX_F" "StartSNMPPollers" "$T_SPOLL"
            set_config "$PX_F" "StartBrowserPollers" "$T_BPOLL"
            set_config "$PX_F" "StartODBCPollers" "$T_ODBCPOLL"
            set_config "$PX_F" "MaxConcurrentChecksPerPoller" "$T_MAXC"
            set_config "$PX_F" "ProxyConfigFrequency" "$T_CFG_FREQ"
            set_config "$PX_F" "DataSenderFrequency" "$T_SND_FREQ"
            set_config "$PX_F" "ProxyOfflineBuffer" "$T_OFFLINE"
            set_config "$PX_F" "ProxyBufferMode" "$T_BUF_MOD"
            if [[ "$T_BUF_MOD" == "hybrid" || "$T_BUF_MOD" == "memory" ]]; then
                set_config "$PX_F" "ProxyMemoryBufferSize" "$T_BUF_SZ"
                set_config "$PX_F" "ProxyMemoryBufferAge" "$T_BUF_AGE"
            fi
        fi
        if [[ -f "$AG_F" && "$INSTALL_AGENT" == "1" ]]; then
            set_config "$AG_F" "Server" "$AG_SERVER"
            set_config "$AG_F" "ServerActive" "$AG_SERVER_ACTIVE"
            set_config "$AG_F" "Hostname" "$AG_HOSTNAME"
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
            echo "$PSK_PROXY_KEY" >/etc/zabbix/zabbix_proxy.psk
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
                echo "$PSK_AGENT_KEY" >/etc/zabbix/zabbix_agent2.psk
                chown zabbix:zabbix /etc/zabbix/zabbix_agent2.psk
                chmod 600 /etc/zabbix/zabbix_agent2.psk
            fi
        fi
        apply_psk() {
            set_config "$PX_F" "TLSAccept" "psk"
            [[ "$PROXY_MODE" == "0" ]] && set_config "$PX_F" "TLSConnect" "psk"
            set_config "$PX_F" "TLSPSKIdentity" "$PSK_PROXY_ID"
            set_config "$PX_F" "TLSPSKFile" "/etc/zabbix/zabbix_proxy.psk"
            if [[ -f "$AG_F" && "$INSTALL_AGENT" == "1" ]]; then
                set_config "$AG_F" "TLSAccept" "psk"
                set_config "$AG_F" "TLSConnect" "psk"
                set_config "$AG_F" "TLSPSKIdentity" "$PSK_AGENT_ID"
                set_config "$AG_F" "TLSPSKFile" "/etc/zabbix/zabbix_agent2.psk"
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
    start_certificate_export "proxy"
    [[ "$_CRITICAL_SERVICES_OK" != "1" ]] &&
        echo -e "${VERMELHO}${NEGRITO}⚠ UM OU MAIS SERVIÇOS CRÍTICOS NÃO ESTÃO ATIVOS. Verifique acima e execute: journalctl -xe --no-pager${RESET}\n"
    echo -e "${VERDE}${NEGRITO}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${VERDE}${NEGRITO}║                CERTIFICADO DE IMPLANTAÇÃO                ║${RESET}"
    echo -e "${VERDE}${NEGRITO}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo -e "\n${CIANO}${NEGRITO}▸ INFO DO SISTEMA OPERACIONAL${RESET}"
    command -v lsb_release >/dev/null 2>&1 &&
        printf "  %-34s %s\n" "Distribuição:" "$(lsb_release -ds)" ||
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
    PX_PKG_VER=$(package_version zabbix-proxy-sqlite3)
    SQLITE_VER=$(sqlite3 --version 2>/dev/null | awk '{print $1}' || true)
    printf "  %-34s %s\n" "zabbix-proxy-sqlite3:" "${PX_PKG_VER:-N/D}"
    printf "  %-34s %s\n" "sqlite3:" "${SQLITE_VER:-N/D}"
    if [[ "$INSTALL_AGENT" == "1" ]]; then
        AG_PKG_VER=$(package_version zabbix-agent2)
        printf "  %-34s %s\n" "zabbix-agent2:" "${AG_PKG_VER:-N/D}"
    fi
    echo -e "\n${CIANO}${NEGRITO}▸ ESTADO DOS SERVIÇOS${RESET}"
    systemctl is-active --quiet zabbix-proxy &&
        printf "  %-34s ${VERDE}%s${RESET}\n" "zabbix-proxy:" "ATIVO ✔" ||
        printf "  %-34s ${VERMELHO}%s${RESET}\n" "zabbix-proxy:" "FALHOU ✖"
    if [[ "$INSTALL_AGENT" == "1" ]]; then
        systemctl is-active --quiet zabbix-agent2 &&
            printf "  %-34s ${VERDE}%s${RESET}\n" "zabbix-agent2:" "ATIVO ✔" ||
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
        printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "IP:" "$HOST_IP"
        printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "Hostname:" "$ZBX_HOSTNAME"
        printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "Identity:" "$PSK_PROXY_ID"
        printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "Secret Key:" "$PSK_PROXY_KEY"
        if [[ "$INSTALL_AGENT" == "1" ]]; then
            echo -e "\n  ${VERDE}[ ZABBIX AGENT 2 ]${RESET}"
            printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "IP:" "$HOST_IP"
            printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "Hostname:" "$AG_HOSTNAME"
            printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "Identity:" "$PSK_AGENT_ID"
            printf "  ${NEGRITO}%-32s${RESET} ${CIANO}%s${RESET}\n" "Secret Key:" "$PSK_AGENT_KEY"
        fi
        echo -e "  ------------------------------------------------------------"
    fi
    print_install_warnings
    echo -e "\n${CIANO}${NEGRITO}▸ EXPORTAÇÃO JSON${RESET}"
    write_install_summary_json "proxy"
    print_support_commands "proxy"
    echo -e "\n${NEGRITO}Log completo:${RESET} $LOG_FILE\n"
}
