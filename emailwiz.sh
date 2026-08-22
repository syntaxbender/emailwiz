#!/bin/sh

# Emailwiz installer entrypoint. Installation features live under app/installer;
# this stable wrapper only resolves and starts that application.

umask 0022

EMAILWIZ_REPO_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
EMAILWIZ_APP_DIR=$EMAILWIZ_REPO_DIR/app
EMAILWIZ_RUNTIME_MODE=development
EMAILWIZ_TEST_MODE=0
EMAILWIZ_INSTALL_PREFIX=/usr/local
EMAILWIZ_INSTALL_LIB_DIR=/usr/local/lib/emailwiz
EMAILWIZ_INSTALL_SBIN_DIR=/usr/local/sbin
EMAILWIZ_LETSENCRYPT_LIVE_ROOT=/etc/letsencrypt/live

[ -f "$EMAILWIZ_REPO_DIR/emailwizctl" ] || {
	printf '%s\n' 'emailwizctl was not found next to emailwiz.sh. Clone the repository and run emailwiz.sh from that checkout.' >&2
	exit 1
}
[ -f "$EMAILWIZ_APP_DIR/installer/main.sh" ] || {
	printf 'ERROR: Emailwiz installer modules were not found in %s. Clone the complete repository before installing.\n' "$EMAILWIZ_APP_DIR" >&2
	exit 1
}

# shellcheck source=app/installer/main.sh
. "$EMAILWIZ_APP_DIR/installer/main.sh"
emailwiz_installer_main "$@"
