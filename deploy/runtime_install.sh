#!/bin/sh
# Install Axelera Voyager SDK 1.6.0 runtime on the Grinn board
# Requires: internet access from the board, metis.ko already loaded
#
# After this finishes you should be able to run:  axdevice

set -u
LOG=/tmp/axelera-runtime-install.log
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

log "=== Voyager SDK 1.6.0 runtime install START ==="

# --- 1. Sanity: driver must already be loaded ------------------------------
if ! lsmod | grep -q '^metis '; then
    log "ERROR: metis.ko is not loaded. Run board_install.sh first."
    exit 1
fi
if [ ! -e /dev/metis-0:1:0 ] && [ -z "$(ls /dev/metis* 2>/dev/null)" ]; then
    log "WARNING: no /dev/metis* device node present -- driver loaded but no device?"
fi

# --- 2. Install axelera-rt via pip -----------------------------------------
log "[1] pip install axelera-rt from Axelera PyPI ..."
pip3 install \
    --index-url https://software.axelera.ai/artifactory/api/pypi/axelera-pypi/simple/ \
    --extra-index-url https://pypi.org/simple/ \
    --upgrade \
    axelera-rt 2>&1 | tee -a "$LOG" | tail -5

# --- 3. Verify with axdevice -----------------------------------------------
if ! command -v axdevice >/dev/null 2>&1; then
    log "ERROR: axdevice not in PATH after install. Check pip output in $LOG."
    exit 1
fi

log "[2] running axdevice ..."
if axdevice 2>&1 | tee -a "$LOG"; then
    log "=== DONE ==="
    log "Runtime is operational. Use axdevice or the Voyager SDK Python API."
else
    log "ERROR: axdevice failed. Full log: $LOG"
    exit 1
fi
