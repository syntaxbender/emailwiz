#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
postfix_installer="$repo_dir/app/installer/postfix.sh"

grep -F "postconf -e 'recipient_delimiter = +'" "$postfix_installer" >/dev/null || {
	printf 'Postfix does not enable +tag recipient handling.\n' >&2
	exit 1
}

printf 'Postfix recipient handling tests passed\n'
