#!/bin/bash
# Bring up the FTSC1000 touchscreen (Honor FMB-P).
#
# The vendor SSDT declares the touch power resource at \_SB.PC00.I2C5.PTPL
# and the panel at \_SB.PC00.I2C2.TPL1, so ACPI never runs PTPL._ON and the
# reset pad (GPP_A_12) stays low -> i2c 0x38 NAK. We call _ON ourselves.
#
# Usage: touchscreen-up.sh [--force]
#   --force  unbind/rebind even if the driver is already attached (resume path)
set -uo pipefail

DEV=i2c-FTSC1000:00
DRV=/sys/bus/i2c/drivers/i2c_hid_acpi
ACPI_DEV=/sys/bus/acpi/devices/FTSC1000:00
POWER_ON='\_SB.PC00.I2C5.PTPL._ON'
ADDR=0x38

force=0
[ "${1:-}" = "--force" ] && force=1

log() { echo "touchscreen-up: $*"; }
die() { log "ERROR: $*"; exit 1; }

is_bound() { [ -e "$DRV/$DEV" ]; }

# Wait for the ACPI i2c client (udev may still be creating it at boot)
for _ in $(seq 50); do
    [ -d "/sys/bus/i2c/devices/$DEV" ] && break
    sleep 0.2
done
if [ ! -d "/sys/bus/i2c/devices/$DEV" ]; then
    log "$DEV not enumerated (ACPI _STA off or namespace missing), nothing to do"
    exit 0
fi

if is_bound && [ $force -eq 0 ]; then
    log "already bound, nothing to do"
    exit 0
fi

bus=$(basename "$(dirname "$(readlink -f "/sys/bus/i2c/devices/$DEV")")")
bus=${bus#i2c-}

if [ $force -eq 1 ] && is_bound; then
    log "unbinding $DEV"
    echo "$DEV" > "$DRV/unbind"
    sleep 0.2
fi

# acpi_call is what lets userspace run an AML method
if [ ! -e /proc/acpi/call ]; then
    modprobe acpi_call || die "acpi_call module missing (pacman -S acpi_call)"
fi

if [ ! -e "$ACPI_DEV/path" ]; then
    die "$ACPI_DEV missing, ACPI namespace is broken"
fi

log "calling $POWER_ON"
if ! echo "$POWER_ON" > /proc/acpi/call; then
    die "write to /proc/acpi/call failed"
fi
ret=$(tr -d '\0' < /proc/acpi/call)
log "PTPL._ON -> ${ret:-<no result>}"

# AML sleeps 2 ms after power enable; give the controller time to boot
sleep 0.15

ack=0
for _ in $(seq 10); do
    if i2ctransfer -y "$bus" w1@$ADDR 0x00 2>/dev/null; then
        ack=1
        break
    fi
    sleep 0.1
done
[ $ack -eq 1 ] || die "$ADDR still NAK on i2c-$bus after PTPL._ON"
log "$ADDR ACK on i2c-$bus"

echo "$DEV" > "$DRV/bind" || die "bind $DEV failed"
sleep 0.5

is_bound || die "driver did not attach to $DEV"
name=$(cat "/sys/bus/i2c/devices/$DEV/name" 2>/dev/null)
log "bound: $name"

# Report the resulting input nodes for the caller/log
for h in /sys/bus/i2c/devices/$DEV/*/input/input*; do
    [ -d "$h" ] || continue
    log "input: $(cat "$h/name" 2>/dev/null) ($(basename "$h"))"
done

exit 0
