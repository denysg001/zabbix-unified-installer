#!/usr/bin/env bash
set -Eeuo pipefail

OUTDIR="dist"
OUTFILE="${OUTDIR}/AUTOMACAO-ZBX-UNIFIED.sh"
mkdir -p "$OUTDIR"

FILES=(
    src/core/colors.sh
    src/core/logging.sh
    src/core/traps.sh
    src/core/validation.sh
    src/core/config.sh
    src/core/system.sh
    src/distros/detect.sh
    src/distros/ubuntu.sh
    src/components/database.sh
    src/components/server.sh
    src/components/proxy.sh
    src/main.sh
)

for f in "${FILES[@]}"; do
    lines=$(grep -cv '^[[:space:]]*#\|^[[:space:]]*$' "$f" 2>/dev/null || true)
    lines="${lines:-0}"
    if [[ "$lines" -eq 0 ]]; then
        echo "AVISO: $f é placeholder — build incompleto, saindo."
        exit 0
    fi
done

{
    head -n 3 "${FILES[0]}"
    for f in "${FILES[@]}"; do
        echo ""
        echo "# ── $(basename "$f") ──────────────────────────────"
        tail -n +4 "$f"
    done
} > "$OUTFILE"

chmod +x "$OUTFILE"
bash -n "$OUTFILE"
echo "Build OK → $OUTFILE"
