#!/bin/sh

# Shared process-level helpers. This file is sourced by application entrypoints.

say() {
	printf '%s\n' "$*"
}

warn() {
	printf 'WARNING: %s\n' "$*" >&2
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

require_root() {
	if [ "${EMAILWIZ_TEST_MODE:-0}" != 1 ] && [ "$(id -u)" -ne 0 ]; then
		die "This command must be run as root."
	fi
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}
