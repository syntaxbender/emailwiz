#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
postfix_installer="$repo_dir/app/installer/postfix.sh"

grep -F 'sendmail -oi -f \${sender} -- \${recipient}' "$postfix_installer" >/dev/null || {
	printf 'SpamAssassin reinjection does not terminate sendmail option processing before the recipient.\n' >&2
	exit 1
}

if grep -F 'sendmail -oi -f \${sender} \${recipient}' "$postfix_installer" >/dev/null; then
	printf 'Unsafe SpamAssassin reinjection without -- is still present.\n' >&2
	exit 1
fi

printf 'Postfix installer security tests passed\n'
