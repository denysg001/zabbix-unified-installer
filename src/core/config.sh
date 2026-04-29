# shellcheck shell=bash

# Shared configuration file helpers.
set_config() {
    local file=$1 param=$2 value=$3
    if [ ! -f "$file" ]; then
        mkdir -p "$(dirname "$file")" 2>/dev/null || true
        touch "$file" 2>/dev/null || {
            echo "Arquivo de configuração não encontrado e não foi possível criar: ${file}" >&2
            return 1
        }
        [[ -n "$value" ]] && echo "${param}=${value}" >>"$file"
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
        echo "${param}=${value}" >>"$file"
    fi
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
