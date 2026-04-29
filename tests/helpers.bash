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

json_escape() {
    local s="${1:-}"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/}
    printf '%s' "$s"
}

conf_value() {
    local file="$1" key="$2"
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
