#!/bin/bash
# systemd-sleep hook: re-run the touchscreen power-on after resume.
# Installed to /usr/lib/systemd/system-sleep/honor-touchscreen by install-touchscreen.sh
case "${1:-}" in
    post) exec /usr/local/lib/honor-touchscreen/touchscreen-up.sh --force ;;
esac
exit 0
