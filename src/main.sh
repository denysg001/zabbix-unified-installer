# shellcheck shell=bash

INSTALLER_VERSION="v5.5"
INSTALLER_LABEL="AUTOMACAO-ZBX-UNIFIED ${INSTALLER_VERSION}"

clear() { printf '\033c' 2>/dev/null || :; }

list_available_plugins() {
    local plugin_file plugin_name found=0
    if [[ -d src/plugins ]]; then
        for plugin_file in src/plugins/*.sh; do
            [[ -f "$plugin_file" ]] || continue
            plugin_name="$(basename "$plugin_file" .sh)"
            printf '  - %s\n' "$plugin_name"
            found=1
        done
    fi
    [[ "$found" == "1" ]] || printf '  Nenhum plugin disponível em src/plugins/.\n'
}

run_plugin() {
    local plugin_name="$1" plugin_file
    plugin_file="src/plugins/${plugin_name}.sh"
    if [[ ! -f "$plugin_file" ]]; then
        echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} plugin não encontrado: ${plugin_name}"
        echo "Plugins disponíveis:"
        list_available_plugins
        exit 1
    fi

    # shellcheck source=/dev/null
    source "$plugin_file"

    local required_fn
    for required_fn in plugin_nome plugin_descricao plugin_verificar_prerequisitos plugin_instalar; do
        if ! declare -F "$required_fn" >/dev/null 2>&1; then
            echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} plugin ${plugin_name} não implementa ${required_fn}()."
            exit 1
        fi
    done

    plugin_verificar_prerequisitos
    plugin_instalar
}

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
REQUESTED_PLUGIN=""

while [[ $# -gt 0 ]]; do
    case "$1" in
    --check | -c)
        CHECK_ONLY=1
        shift
        ;;
    --dry-run | -n)
        DRY_RUN=1
        shift
        ;;
    --doctor | -d)
        DOCTOR_MODE=1
        shift
        ;;
    --doctor-export)
        DOCTOR_MODE=1
        DOCTOR_EXPORT=1
        shift
        ;;
    --export)
        DOCTOR_EXPORT=1
        shift
        ;;
    --list-versions)
        LIST_VERSIONS=1
        shift
        ;;
    --list-supported-os)
        LIST_SUPPORTED_OS=1
        shift
        ;;
    --repo-check)
        REPO_CHECK=1
        shift
        ;;
    --safe)
        SAFE_MODE=1
        shift
        ;;
    --debug-services)
        DEBUG_SERVICES=1
        shift
        ;;
    --collect-support-bundle)
        COLLECT_SUPPORT_BUNDLE=1
        shift
        ;;
    --self-test)
        SELF_TEST_MODE=1
        shift
        ;;
    --version | -V)
        printf '%s\n' "$INSTALLER_VERSION"
        exit 0
        ;;
    --simulate | -s)
        SIMULATE_MODE=1
        shift
        ;;
    --wipe)
        WIPE_MODE=1
        shift
        ;;
    --wipe-db)
        WIPE_MODE=1
        WIPE_DB=1
        shift
        ;;
    --plugin=*)
        REQUESTED_PLUGIN="${1#--plugin=}"
        shift
        ;;
    --plugin)
        if [[ -z "${2:-}" ]]; then
            echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} --plugin requer um nome."
            exit 1
        fi
        REQUESTED_PLUGIN="$2"
        shift 2
        ;;
    --mode)
        if [[ -z "${2:-}" ]]; then
            echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} --mode requer um valor: db, server ou proxy."
            exit 1
        fi
        case "$2" in
        db | database | bd) REQUESTED_COMPONENT="db" ;;
        server | servidor) REQUESTED_COMPONENT="server" ;;
        proxy) REQUESTED_COMPONENT="proxy" ;;
        *)
            echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} modo inválido em --mode: $2"
            echo "Use: --mode db, --mode server ou --mode proxy."
            exit 1
            ;;
        esac
        shift 2
        ;;
    db | database | bd)
        REQUESTED_COMPONENT="db"
        shift
        ;;
    server | servidor)
        REQUESTED_COMPONENT="server"
        shift
        ;;
    proxy)
        REQUESTED_COMPONENT="proxy"
        shift
        ;;
    --help | -h)
        cat <<EOF
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
  --version, -V Mostra a versão do instalador e sai.
  --plugin <nome> Executa plugin disponível em src/plugins/.
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
  $0 --version  Mostra a versão do instalador
  $0 --plugin grafana Executa o plugin Grafana se existir em src/plugins/grafana.sh
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

if [[ -n "$REQUESTED_PLUGIN" ]]; then
    run_plugin "$REQUESTED_PLUGIN"
    exit 0
fi

detect_distro

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
mkdir -p "$VALIDATION_CACHE_DIR" 2>/dev/null || true
chmod 700 "$VALIDATION_CACHE_DIR" 2>/dev/null || true

if [[ "$CHECK_ONLY" != "1" && "$DRY_RUN" != "1" && "$SIMULATE_MODE" != "1" && "$LIST_VERSIONS" != "1" && "$LIST_SUPPORTED_OS" != "1" && "$DEBUG_SERVICES" != "1" && "$SELF_TEST_MODE" != "1" && "$EUID" -ne 0 ]]; then
    echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} O instalador precisa de permissões de root (sudo)."
    exit 1
fi

[[ "$LIST_VERSIONS" == "1" ]] && {
    show_supported_versions
    exit 0
}
[[ "$LIST_SUPPORTED_OS" == "1" ]] && {
    show_supported_os
    exit 0
}
[[ "$SELF_TEST_MODE" == "1" ]] && {
    run_self_test
    exit 0
}
[[ "$DEBUG_SERVICES" == "1" ]] && {
    run_debug_services
    exit 0
}
[[ "$COLLECT_SUPPORT_BUNDLE" == "1" ]] && {
    collect_support_bundle
    exit 0
}
[[ "$WIPE_MODE" == "1" ]] && {
    run_wipe_mode
    exit 0
}
[[ "$CHECK_ONLY" == "1" ]] && {
    run_check_mode
    exit 0
}

clear
echo -e "${VERMELHO}${NEGRITO}"
cat <<"EOF"
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
        1)
            COMPONENT="db"
            break
            ;;
        2)
            COMPONENT="server"
            break
            ;;
        3)
            COMPONENT="proxy"
            break
            ;;
        4)
            echo -e "\n${AMARELO}Saindo sem executar alterações.${RESET}"
            exit 0
            ;;
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

case "$COMPONENT" in
db) run_component_db ;;
server) run_component_server ;;
proxy) run_component_proxy ;;
*)
    echo -e "${VERMELHO}${NEGRITO}ERRO:${RESET} Componente inválido: ${COMPONENT:-vazio}"
    exit 1
    ;;
esac

exit 0
