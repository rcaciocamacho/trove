#!/bin/bash
# usbsync_pick.sh — service menu de Dolphin para USB Sync
# $1 = URL de la carpeta (file:///...), $2 = campo ("source" | "dest")
# Escribe la ruta elegida en pick_request.json para que el backend la capture.
set -e

URL="$1"
FIELD="$2"

# convertir file:///ruta → /ruta (y decodificar %20, etc.)
PATH_RAW="${URL#file://}"
PATH_DECODED=$(python3 -c "import sys, urllib.parse; print(urllib.parse.unquote(sys.argv[1]))" "$PATH_RAW")

DIR="$HOME/.local/state/usbsync"
mkdir -p "$DIR"
printf '{"ts": %s, "path": "%s", "field": "%s"}' "$(date +%s)" "$PATH_DECODED" "$FIELD" > "$DIR/pick_request.json"
