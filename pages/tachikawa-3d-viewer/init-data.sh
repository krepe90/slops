#!/usr/bin/env bash
# Initialize the PLATEAU 2025 (V5) 3D Tiles data this viewer needs.
# Idempotent: re-running skips work that is already complete. Pass --force to redo.
set -euo pipefail

# --- Configuration -----------------------------------------------------------
# PLATEAU 立川市 (city code 13202), 2025 / V5 — the "3D Tiles, MVT" package.
# Dataset: https://www.geospatial.jp/ckan/dataset/plateau-13202-tachikawa-shi-2025
readonly DATA_URL='https://assets.cms.plateau.reearth.io/assets/9b/66c55a-4499-44ca-857d-b54d4eece5ba/13202_tachikawa-shi_pref_2025_3dtiles_mvt_1_op.zip'
readonly EXPECTED_ZIP_BYTES=339740006

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DATA_DIR="${SCRIPT_DIR}/data"
readonly ZIP_PATH="${DATA_DIR}/tachikawa_3dtiles_2025.zip"
readonly EXTRACT_DIR="${DATA_DIR}/extracted_2025"
# Relative path of the tileset the viewer loads — keep in sync with TILESET_URL in main.js.
readonly TILESET_REL='13202_tachikawa-shi_pref_2025_citygml_1_op_bldg_3dtiles_lod2/tileset.json'
readonly TILESET_PATH="${EXTRACT_DIR}/${TILESET_REL}"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

# --- Helpers -----------------------------------------------------------------
log() { printf '\033[36m▸ %s\033[0m\n' "$*"; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# stat byte size, portable across BSD/macOS (-f%z) and GNU/Linux (-c%s).
file_size() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1"; }

# --- Steps -------------------------------------------------------------------
download_zip() {
    if [[ $FORCE -eq 0 && -f "$ZIP_PATH" && "$(file_size "$ZIP_PATH")" == "$EXPECTED_ZIP_BYTES" ]]; then
        log "ZIP already present with expected size — skipping download."
        return
    fi
    log "Downloading 2025 dataset (~340 MB)…"
    # Download to a .part file so an interrupted run never leaves a truncated ZIP.
    curl -fL --retry 3 -o "${ZIP_PATH}.part" "$DATA_URL" || die "download failed"
    mv "${ZIP_PATH}.part" "$ZIP_PATH"

    local got; got="$(file_size "$ZIP_PATH")"
    [[ "$got" == "$EXPECTED_ZIP_BYTES" ]] \
        || die "size mismatch: expected ${EXPECTED_ZIP_BYTES} bytes, got ${got}"
}

extract_zip() {
    if [[ $FORCE -eq 0 && -f "$TILESET_PATH" ]]; then
        log "Already extracted — skipping (use --force to redo)."
        return
    fi
    log "Extracting into ${EXTRACT_DIR} (~2.6 GB on disk)…"
    mkdir -p "$EXTRACT_DIR"
    unzip -q -o "$ZIP_PATH" -d "$EXTRACT_DIR" || die "extraction failed"
}

verify() {
    [[ -f "$TILESET_PATH" ]] \
        || die "tileset.json missing at expected path: ${TILESET_PATH}"
    log "OK — viewer tileset present:"
    printf '   %s\n' "$TILESET_PATH"
}

# --- Main --------------------------------------------------------------------
require_cmd curl
require_cmd unzip
mkdir -p "$DATA_DIR"
download_zip
extract_zip
verify
log "Data initialized. Serve this folder (e.g. 'python3 -m http.server') and open index.html."
