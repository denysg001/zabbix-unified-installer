# shellcheck shell=bash

# Error and EXIT trap handling.
on_error() {
    local exit_code="$?"
    local line_no="${BASH_LINENO[0]:-${LINENO}}"
    local cmd="${BASH_COMMAND:-comando desconhecido}"
    local safe_cmd
    safe_cmd="$(redact_known_secrets "$cmd")"
    echo -e "\n\e[31m\e[1mERRO FATAL:\e[0m linha ${line_no}, código ${exit_code}." >&2
    echo -e "\e[33mComando:\e[0m ${safe_cmd}" >&2
    [[ -n "${LOG_FILE:-}" ]] && echo -e "\e[36mLog:\e[0m ${LOG_FILE}" >&2
    if [[ -n "${LOG_FILE:-}" ]]; then
        printf '[%s] [FATAL] linha %s, código %s — %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$line_no" "$exit_code" "$safe_cmd" \
            >>"$LOG_FILE" 2>/dev/null || true
    fi
    write_error_json "$exit_code" "$line_no" "$safe_cmd"
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
        "${_cmd}" >/dev/null 2>&1 || true
    done
}
add_exit_trap() {
    EXIT_TRAP_COMMANDS+=("$1")
    trap run_exit_traps EXIT
}
cleanup_install_lock() {
    [[ -n "${LOCK_FILE:-}" ]] && rm -f "$LOCK_FILE" 2>/dev/null || true
}
