#!/usr/bin/env bats

load helpers

@test "mask_secret masks non-empty secrets" {
    local output
    output="$(mask_secret "abcd1234efgh")"

    [[ "$output" == *"********"* ]]
    [[ "$output" != "abcd1234efgh" ]]
}

@test "mask_secret returns empty for empty input" {
    local output
    output="$(mask_secret "")"

    [ "$output" = "" ]
}

@test "json_escape escapes quotes backslashes and newlines" {
    local input expected
    input=$'a"b\\c\nnext'
    expected='a\"b\\c\nnext'

    local output
    output="$(json_escape "$input")"

    [ "$output" = "$expected" ]
}

@test "conf_value reads uncommented key values and preserves equals signs" {
    local conf
    conf="$(mktemp)"
    cat >"$conf" <<'EOF'
# Name=ignored
Name = value=with=equals
Other = keep
EOF

    local output
    output="$(conf_value "$conf" "Name")"
    [ "$output" = "value=with=equals" ]

    rm -f "$conf"
}

@test "conf_value returns empty for missing keys" {
    local conf
    conf="$(mktemp)"
    cat >"$conf" <<'EOF'
Name = present
EOF

    local output
    output="$(conf_value "$conf" "Missing")"
    [ "$output" = "" ]

    rm -f "$conf"
}
