#!/bin/sh
# Axelera Metis driver install script for Grinn Genio700 SBC
# Target kernel: 5.15.47-mtk+gd011e19cfc68 (MediaTek Genio BSP, Yocto kirkstone)
# Driver: axelera-ai-hub/axelera-driver release/v1.6 (single metis.ko)
#
# Logs every step to /tmp/axelera-install.log

set -u
LOG=/tmp/axelera-install.log
KVER=$(uname -r)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODDIR="/lib/modules/${KVER}/extra"
UDEVRULES="/etc/udev/rules.d/72-axelera.rules"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

log "=== Axelera Metis install START ==="
log "Running from: $SCRIPT_DIR"
log "Kernel:       $KVER"

if [ "$KVER" != "5.15.47-mtk+gd011e19cfc68" ]; then
    log "WARNING: this package was built for kernel 5.15.47-mtk+gd011e19cfc68."
    log "         Running on a different kernel may fail with vermagic errors."
fi

# --- Sanity: card present? -------------------------------------------------
if ! lspci -n 2>/dev/null | grep -q '1f9d:1100'; then
    log "WARNING: no PCI device 1f9d:1100 (Axelera Metis) detected on the bus."
fi

# --- Step 1: install metis.ko ----------------------------------------------
log "[1] installing metis.ko -> ${MODDIR}/metis.ko"
mkdir -p "$MODDIR"
cp -f "${SCRIPT_DIR}/metis.ko" "${MODDIR}/metis.ko"
/sbin/depmod -a "$KVER" && log "[1] depmod OK" || log "[1] depmod FAILED rc=$?"

# --- Step 2: install udev rules --------------------------------------------
log "[2] installing udev rules -> $UDEVRULES"
cp -f "${SCRIPT_DIR}/72-axelera.rules" "$UDEVRULES"
# Create the 'axelera' group referenced by the rules if it doesn't exist
getent group axelera >/dev/null 2>&1 || groupadd -f axelera 2>/dev/null || true
udevadm control --reload-rules 2>/dev/null || true

# --- Step 3: load module ---------------------------------------------------
# IMPORTANT: on this kernel the first load takes ~5-10 s due to BTF
# processing + ftrace patching of ~110 function entries.  Do NOT abort
# early -- a timeout of 30 s is safe.
if lsmod | grep -q '^metis '; then
    log "[3] metis already loaded, skipping insmod"
else
    log "[3] insmod metis (this may take up to 10 s, be patient)..."
    timeout 30 /sbin/insmod "${MODDIR}/metis.ko"
    rc=$?
    log "[3] insmod rc=$rc"
    if [ "$rc" -ne 0 ]; then
        log "[3] FAILED. Last dmesg lines:"
        dmesg | tail -20 | tee -a "$LOG"
        exit 1
    fi
fi

# --- Step 4: trigger udev --------------------------------------------------
log "[4] udev trigger"
udevadm trigger 2>/dev/null || true
udevadm settle --timeout=5 2>/dev/null || true

# --- Step 5: verification --------------------------------------------------
log "=== DONE ==="
log "Loaded Axelera modules:"
lsmod | grep -E '^(metis|axl)' | tee -a "$LOG" || log "  (none)"
log "Device nodes:"
ls -l /dev/metis* /dev/axl* 2>/dev/null | tee -a "$LOG" || log "  (none)"
log "Last dmesg lines:"
dmesg | tail -15 | tee -a "$LOG"

echo ""
echo "Install complete. Full log: cat $LOG"
echo "To verify with the Voyager SDK runtime (once installed):"
echo "    axdevice"
