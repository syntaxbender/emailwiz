#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/emailwiz-test.XXXXXX")
cleanup() {
	[ "${EMAILWIZ_TEST_KEEP_ROOT:-0}" = 1 ] && return 0
	find -P "${test_root:?}" -xdev -depth -delete
}
trap cleanup EXIT HUP INT TERM

bin_dir="$test_root/bin"
mkdir -p "$bin_dir" "$test_root/etc/dovecot" "$test_root/etc/postfix/dkim" \
	"$test_root/home/alice" "$test_root/home/bob" "$test_root/certs/mail.example.com"

uid=$(id -u)
gid=$(id -g)

cat > "$bin_dir/sqlite3" <<EOF
#!/bin/sh
exec python3 "$repo_dir/tests/sqlite3-shim.py" "\$@"
EOF

cat > "$bin_dir/dovecot" <<'EOF'
#!/bin/sh
printf '%s\n' "${MOCK_DOVECOT_VERSION:-2.3.16}"
EOF

cat > "$bin_dir/doveconf" <<'EOF'
#!/bin/sh
exit 0
EOF

cat > "$bin_dir/postmap" <<'EOF'
#!/bin/sh
for argument do
	case "$argument" in hash:*) map=${argument#hash:} ;; esac
done
: "${map:?missing hash map}"
: > "$map.db"
EOF

cat > "$bin_dir/postconf" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${MOCK_COMMAND_LOG:?}"
EOF

cat > "$bin_dir/postfix" <<'EOF'
#!/bin/sh
exit 0
EOF

cat > "$bin_dir/systemctl" <<'EOF'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "${MOCK_COMMAND_LOG:?}"
EOF

cat > "$bin_dir/sievec" <<'EOF'
#!/bin/sh
: > "$1.svbin"
EOF

cat > "$bin_dir/opendkim-genkey" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
	case "$1" in
		-D) directory=$2; shift 2 ;;
		-s) selector=$2; shift 2 ;;
		*) shift ;;
	esac
done
: "${directory:?}"
: "${selector:?}"
printf 'private-key\n' > "$directory/$selector.private"
printf '%s._domainkey IN TXT ( "v=DKIM1; k=rsa; " "p=TESTKEY" )\n' "$selector" > "$directory/$selector.txt"
EOF

cat > "$bin_dir/doveadm" <<'EOF'
#!/bin/sh
IFS= read -r test_password
cat >/dev/null
printf '{SHA512-CRYPT}$6$testsalt$%s\n' "$test_password"
EOF

cat > "$bin_dir/getent" <<EOF
#!/bin/sh
if [ "\${1:-}" = passwd ]; then
	case "\$#:\${2:-}" in
		1:)
			printf 'alice:x:$uid:$gid::${test_root}/home/alice:/bin/sh\n'
			printf 'bob:x:$uid:$gid::${test_root}/home/bob:/bin/sh\n'
			printf 'nohome:x:$uid:$gid:::/bin/sh\n'
			exit 0
			;;
		2:alice) printf 'alice:x:$uid:$gid::${test_root}/home/alice:/bin/sh\n'; exit 0 ;;
		2:bob) printf 'bob:x:$uid:$gid::${test_root}/home/bob:/bin/sh\n'; exit 0 ;;
		2:nohome) printf 'nohome:x:$uid:$gid:::/bin/sh\n'; exit 0 ;;
	esac
fi
exit 1
EOF

chmod +x "$bin_dir"/* "$repo_dir/tests/sqlite3-shim.py"
printf 'certificate\n' > "$test_root/certs/mail.example.com/fullchain.pem"
printf 'key\n' > "$test_root/certs/mail.example.com/privkey.pem"
: > "$test_root/etc/dovecot/dovecot.conf"
: > "$test_root/commands.log"

export PATH="$bin_dir:$PATH"
export MOCK_COMMAND_LOG="$test_root/commands.log"
export EMAILWIZ_TEST_MODE=1
export EMAILWIZ_STATE_DIR="$test_root/state"
export EMAILWIZ_DB_PATH="$test_root/state/emailwiz.sqlite3"
export EMAILWIZ_DNS_DIR="$test_root/state/dns"
export EMAILWIZ_DOVECOT_CONF="$test_root/etc/dovecot/dovecot.conf"
export EMAILWIZ_DOVECOT_SQL_CONF="$test_root/etc/dovecot/emailwiz-sql.conf.ext"
export EMAILWIZ_POSTFIX_DIR="$test_root/etc/postfix"
export EMAILWIZ_OPENDKIM_KEYTABLE="$test_root/etc/postfix/dkim/keytable"
export EMAILWIZ_OPENDKIM_SIGNINGTABLE="$test_root/etc/postfix/dkim/signingtable"
export EMAILWIZ_DKIM_ROOT="$test_root/etc/postfix/dkim"
export EMAILWIZ_SIEVE_DIR="$test_root/state/sieve"
export EMAILWIZ_RENEW_HOOK="$test_root/renewal-hooks/deploy/emailwiz"
export EMAILWIZ_HOME_ROOT="$test_root/home"
export SQLITE3="$bin_dir/sqlite3"

ctl="$repo_dir/emailwizctl"

EMAILWIZ_APP_DIR="$test_root/missing-app" "$ctl" --help >/dev/null || {
	printf 'The checkout launcher accepted an EMAILWIZ_APP_DIR override.\n' >&2
	exit 1
}

production_runtime=$(
	EMAILWIZ_RUNTIME_MODE=production \
	EMAILWIZ_APP_DIR="$repo_dir/app" \
	EMAILWIZ_TEST_MODE=1 \
	EMAILWIZ_STATE_DIR="$test_root/unsafe-state" \
	SQLITE3="$bin_dir/sqlite3" \
	sh -c '. "$1/management/bootstrap.sh"; printf "%s|%s|%s\n" "$STATE_DIR" "$EMAILWIZ_TEST_MODE" "$SQLITE3"' \
		sh "$repo_dir/app"
)
[ "$production_runtime" = '/var/lib/emailwiz|0|sqlite3' ] || {
	printf 'Production runtime accepted test/path overrides: %s\n' "$production_runtime" >&2
	exit 1
}

assert_contains() {
	needle=$1
	file=$2
	grep -F "$needle" "$file" >/dev/null || {
		printf 'Expected to find %s in %s\n' "$needle" "$file" >&2
		exit 1
	}
}

assert_sql() {
	expected=$1
	query=$2
	actual=$("$bin_dir/sqlite3" "$EMAILWIZ_DB_PATH" "$query")
	[ "$actual" = "$expected" ] || {
		printf 'SQL assertion failed. Expected %s, got %s\n' "$expected" "$actual" >&2
		exit 1
	}
}

MOCK_DOVECOT_VERSION=2.3.16 "$ctl" system init
assert_sql no "SELECT value FROM metadata WHERE key = 'spamassassin_enabled';"
assert_sql 5 "SELECT value FROM metadata WHERE key = 'schema_version';"
assert_sql 0 "SELECT COUNT(*) FROM metadata WHERE key = 'certificate_mode';"
assert_contains 'keep;' "$EMAILWIZ_SIEVE_DIR/default.sieve"
if MOCK_DOVECOT_VERSION=2.3.16 "$ctl" domain add example.com --no-reload >/dev/null 2>&1; then
	printf 'A domain was unexpectedly added before canonical TLS was configured.\n' >&2
	exit 1
fi
assert_sql 0 'SELECT COUNT(*) FROM domains;'
MOCK_DOVECOT_VERSION=2.3.16 "$ctl" system tls mail.example.com \
	--cert-dir "$test_root/certs/mail.example.com" --authenticator http-01 --no-reload
assert_sql mail.example.com "SELECT value FROM metadata WHERE key = 'canonical_mail_hostname';"
assert_sql "$test_root/certs/mail.example.com" "SELECT value FROM metadata WHERE key = 'canonical_cert_dir';"
assert_sql http-01 "SELECT value FROM metadata WHERE key = 'certificate_authenticator';"
if MOCK_DOVECOT_VERSION=2.3.16 "$ctl" system tls mail.example.com \
	--cert-dir "$test_root/certs/mail.example.com" --authenticator invalid --no-reload >/dev/null 2>&1; then
	printf 'An invalid certificate authenticator was unexpectedly accepted.\n' >&2
	exit 1
fi
if grep -F 'X-Spam-Flag' "$EMAILWIZ_SIEVE_DIR/default.sieve" >/dev/null; then
	printf 'Disabled SpamAssassin unexpectedly installed the global spam Sieve rule.\n' >&2
	exit 1
fi
MOCK_DOVECOT_VERSION=2.3.16 "$ctl" system init --spamassassin yes
assert_sql yes "SELECT value FROM metadata WHERE key = 'spamassassin_enabled';"
assert_contains 'X-Spam-Flag' "$EMAILWIZ_SIEVE_DIR/default.sieve"
# Omitting the option on a later init preserves the selected mode.
MOCK_DOVECOT_VERSION=2.3.16 "$ctl" system init
assert_sql yes "SELECT value FROM metadata WHERE key = 'spamassassin_enabled';"
if MOCK_DOVECOT_VERSION=2.3.16 "$ctl" system init --spamassassin invalid >/dev/null 2>&1; then
	printf 'An invalid SpamAssassin mode was unexpectedly accepted.\n' >&2
	exit 1
fi
sh "$repo_dir/emailwiz.sh" --help | grep -F -- '--with-spamassassin' >/dev/null || {
	printf 'Installer help does not document the SpamAssassin option.\n' >&2
	exit 1
}
sh "$repo_dir/emailwiz.sh" --help | grep -F -- '--certbot-authenticator' >/dev/null || {
	printf 'Installer help does not document Certbot authenticator selection.\n' >&2
	exit 1
}
EMAILWIZ_APP_DIR="$test_root/missing-installer-app" \
	EMAILWIZ_TEST_MODE=1 \
	EMAILWIZ_INSTALL_PREFIX="$test_root/unsafe-prefix" \
	sh "$repo_dir/emailwiz.sh" --help >/dev/null || {
	printf 'The installer entrypoint accepted production path/test overrides.\n' >&2
	exit 1
}
if sh "$repo_dir/emailwiz.sh" --help | grep -Fi 'self-signed' >/dev/null; then
	printf 'Installer help still documents self-signed certificate generation.\n' >&2
	exit 1
fi

# The installer deploys the same modular application tree used from a checkout.
EMAILWIZ_APP_DIR="$repo_dir/app"
EMAILWIZ_REPO_DIR=$repo_dir
export EMAILWIZ_APP_DIR EMAILWIZ_REPO_DIR
# shellcheck source=../app/installer/packages.sh
. "$repo_dir/app/installer/packages.sh"
install_prefix="$test_root/installed/usr/local"
EMAILWIZ_INSTALL_PREFIX="$install_prefix" emailwiz_installer_install_application
unset EMAILWIZ_APP_DIR
EMAILWIZ_APP_DIR="$test_root/missing-installed-app" \
	"$install_prefix/sbin/emailwizctl" --help | grep -F 'emailwizctl domain add' >/dev/null || {
	printf 'The installed modular management application could not be loaded.\n' >&2
	exit 1
}
EMAILWIZ_APP_DIR="$test_root/missing-installed-app" \
	"$install_prefix/sbin/emailwizctl" --help | grep -F 'emailwizctl alias add ADDRESS --to TARGET [--passwd|--password-stdin]' >/dev/null || {
	printf 'The installed application does not expose alias management.\n' >&2
	exit 1
}
# Continue exercising the checkout entrypoint rather than the installed copy.
export EMAILWIZ_APP_DIR="$repo_dir/app"

MOCK_DOVECOT_VERSION=2.3.16 "$ctl" domain add example.com --no-reload
MOCK_DOVECOT_VERSION=2.3.16 "$ctl" domain add example.net --no-reload

assert_contains 'auth_username_format = %Lu' "$EMAILWIZ_DOVECOT_CONF"
assert_contains 'auth_username_chars = abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.@' "$EMAILWIZ_DOVECOT_CONF"
assert_contains 'recipient_delimiter = +' "$EMAILWIZ_DOVECOT_CONF"
assert_contains 'postmaster_address = postmaster@mail.example.com' "$EMAILWIZ_DOVECOT_CONF"
assert_contains 'driver = sqlite' "$EMAILWIZ_DOVECOT_SQL_CONF"
assert_contains "'mailbox.' || m.storage_id || '@emailwiz.internal' AS user" "$EMAILWIZ_DOVECOT_SQL_CONF"
assert_contains 'password_query = SELECT u.email AS user' "$EMAILWIZ_DOVECOT_SQL_CONF"
assert_contains 'u.password_hash IS NOT NULL' "$EMAILWIZ_DOVECOT_SQL_CONF"
assert_contains 'u.password_hash IS NOT NULL' "$EMAILWIZ_POSTFIX_DIR/emailwiz-sender-logins.cf"
assert_contains "ssl_cert = <$test_root/certs/mail.example.com/fullchain.pem" "$EMAILWIZ_DOVECOT_CONF"
if grep -F 'local_name ' "$EMAILWIZ_DOVECOT_CONF" >/dev/null; then
	printf 'Canonical TLS configuration unexpectedly contains a per-domain local_name block.\n' >&2
	exit 1
fi
assert_contains "smtpd_tls_cert_file=$test_root/certs/mail.example.com/fullchain.pem" "$MOCK_COMMAND_LOG"
assert_contains 'myhostname=mail.example.com' "$MOCK_COMMAND_LOG"
assert_contains 'recipient_delimiter = +' "$MOCK_COMMAND_LOG"
assert_contains 'tls_server_sni_maps =' "$MOCK_COMMAND_LOG"
assert_sql 2 'SELECT COUNT(*) FROM domains WHERE enabled = 1;'
assert_sql 0 "SELECT COUNT(*) FROM pragma_table_info('domains') WHERE name IN ('mail_hostname', 'cert_dir');"
cp "$EMAILWIZ_DOVECOT_CONF" "$test_root/dovecot-2.3.conf"
cp "$EMAILWIZ_DOVECOT_SQL_CONF" "$test_root/emailwiz-sql-2.3.conf.ext"

printf 'correct horse battery staple\n' | MOCK_DOVECOT_VERSION=2.3.16 "$ctl" user add \
	alice@example.com --unix-user alice --password-stdin
assert_sql "$test_root/home/alice" "SELECT m.home_path FROM mail_users u JOIN mailboxes m ON m.id = u.mailbox_id WHERE u.email = 'alice@example.com';"
assert_sql "$uid|$gid" "SELECT m.uid || '|' || m.gid FROM mail_users u JOIN mailboxes m ON m.id = u.mailbox_id WHERE u.email = 'alice@example.com';"
assert_sql 32 "SELECT length(storage_id) FROM mailboxes;"

# Additional addresses must explicitly target the existing mailbox. A
# delivery-only alias has no password; --password-stdin creates a login alias.
printf 'mail already delivered\n' > "$test_root/home/alice/Mail/existing"
if printf 'password\n' | MOCK_DOVECOT_VERSION=2.3.16 "$ctl" user add \
	duplicate@example.com --unix-user alice --password-stdin >/dev/null 2>&1; then
	printf 'user add unexpectedly reused an already managed Unix mailbox.\n' >&2
	exit 1
fi
MOCK_DOVECOT_VERSION=2.3.16 "$ctl" alias add \
	info@example.net --to alice@example.com
printf 'another password\n' | MOCK_DOVECOT_VERSION=2.3.16 "$ctl" user add \
	ahmet.mehmet@example.com --unix-user alice --password-stdin >/dev/null 2>&1 && {
	printf 'user add unexpectedly created a second identity on the managed mailbox.\n' >&2
	exit 1
}
printf 'another password\n' | MOCK_DOVECOT_VERSION=2.3.16 "$ctl" alias add \
	ahmet.mehmet@example.com --to alice@example.com --password-stdin
assert_sql 1 "SELECT COUNT(*) FROM mailboxes WHERE home_path = '$test_root/home/alice';"
assert_sql 3 "SELECT COUNT(*) FROM mail_users u JOIN mailboxes m ON m.id = u.mailbox_id WHERE m.home_path = '$test_root/home/alice';"
assert_sql 2 "SELECT COUNT(DISTINCT password_hash) FROM mail_users WHERE email IN ('alice@example.com', 'ahmet.mehmet@example.com');"
assert_sql 1 "SELECT COUNT(*) FROM mail_users WHERE email = 'info@example.net' AND password_hash IS NULL;"
"$ctl" user list --all > "$test_root/user-list.txt"
assert_contains 'no-login' "$test_root/user-list.txt"
assert_contains 'login' "$test_root/user-list.txt"
assert_sql ahmetmehmet "SELECT canonical_localpart FROM mail_users WHERE email = 'ahmet.mehmet@example.com';"
assert_sql ahmet.mehmet@example.com "SELECT u.email FROM mail_users u JOIN domains d ON d.id = u.domain_id WHERE u.canonical_localpart = replace(lower('ah.metmehmet'), '.', '') AND d.name = 'example.com';"
storage_user=$("$bin_dir/sqlite3" "$EMAILWIZ_DB_PATH" "SELECT 'mailbox.' || storage_id || '@emailwiz.internal' FROM mailboxes;")
assert_sql "$storage_user|$storage_user" "SELECT group_concat(storage_user, '|') FROM (SELECT 'mailbox.' || m.storage_id || '@emailwiz.internal' AS storage_user FROM mail_users u JOIN mailboxes m ON m.id = u.mailbox_id WHERE u.email IN ('alice@example.com', 'ahmet.mehmet@example.com') ORDER BY u.email);"
assert_sql 0 "SELECT COUNT(*) FROM mail_users WHERE email = 'info@example.net' AND password_hash IS NOT NULL;"

# Dotted spellings are one canonical identity and cannot be registered twice.
if printf 'password\n' | MOCK_DOVECOT_VERSION=2.3.16 "$ctl" user add \
	ah.metmehmet@example.com --unix-user bob --password-stdin >/dev/null 2>&1; then
	printf 'A dotted variant was unexpectedly registered as a second identity.\n' >&2
	exit 1
fi
for invalid_address in invalid_user@example.com invalid-user@example.com invalid%user@example.com invalid+user@example.com; do
	if MOCK_DOVECOT_VERSION=2.3.16 "$ctl" alias add \
		"$invalid_address" --to alice@example.com >/dev/null 2>&1; then
		printf 'An unsupported local part was unexpectedly accepted: %s\n' "$invalid_address" >&2
		exit 1
	fi
done
if MOCK_DOVECOT_VERSION=2.3.16 "$ctl" alias add missing-target@example.com \
	--to nobody@example.com >/dev/null 2>&1; then
	printf 'An alias with a missing target was unexpectedly accepted.\n' >&2
	exit 1
fi

# Non-empty pre-existing mail is never adopted or modified.
mkdir "$test_root/home/bob/Mail"
printf 'existing mail\n' > "$test_root/home/bob/Mail/existing"
if printf 'password\n' | MOCK_DOVECOT_VERSION=2.3.16 "$ctl" user add \
	bob@example.com --unix-user bob --password-stdin >/dev/null 2>&1; then
	printf 'A non-empty existing Mail directory was unexpectedly accepted.\n' >&2
	exit 1
fi
assert_sql 0 "SELECT COUNT(*) FROM mail_users WHERE email = 'bob@example.com';"

# User creation resolves home/UID/GID from an existing Unix account.
if "$ctl" user add missing@example.com --unix-user missing >/dev/null 2>&1; then
	printf 'A missing Unix user was unexpectedly accepted.\n' >&2
	exit 1
fi
if "$ctl" user add nohome@example.com --unix-user nohome >/dev/null 2>&1; then
	printf 'A Unix user without a configured home was unexpectedly accepted.\n' >&2
	exit 1
fi
if "$ctl" user add legacy@example.com --home "$test_root/home/alice" >/dev/null 2>&1; then
	printf 'The removed --home option was unexpectedly accepted.\n' >&2
	exit 1
fi

"$ctl" user delete alice@example.com
assert_sql 0 "SELECT enabled FROM mail_users WHERE email = 'alice@example.com';"
"$ctl" user enable alice@example.com
assert_sql 1 "SELECT enabled FROM mail_users WHERE email = 'alice@example.com';"

MOCK_DOVECOT_VERSION=2.4.2 "$ctl" system render --no-reload
assert_contains 'dovecot_config_version = 2.4.0' "$EMAILWIZ_DOVECOT_CONF"
assert_contains 'sqlite_readonly = yes' "$EMAILWIZ_DOVECOT_CONF"
assert_contains 'auth_username_format = %{user | lower}' "$EMAILWIZ_DOVECOT_CONF"
assert_contains 'auth_username_chars = abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.@' "$EMAILWIZ_DOVECOT_CONF"
assert_contains 'recipient_delimiter = +' "$EMAILWIZ_DOVECOT_CONF"
assert_contains 'postmaster_address = postmaster@mail.example.com' "$EMAILWIZ_DOVECOT_CONF"
assert_contains 'ssl_server_cert_file = ' "$EMAILWIZ_DOVECOT_CONF"
assert_contains 'sieve_script default {' "$EMAILWIZ_DOVECOT_CONF"
assert_contains "'mailbox.' || m.storage_id || '@emailwiz.internal' AS user" "$EMAILWIZ_DOVECOT_CONF"
assert_contains 'u.password_hash IS NOT NULL' "$EMAILWIZ_DOVECOT_CONF"
cp "$EMAILWIZ_DOVECOT_CONF" "$test_root/dovecot-2.4.conf"
[ ! -e "$EMAILWIZ_DOVECOT_SQL_CONF" ] || {
	printf 'Dovecot 2.4 should not retain the 2.3 external SQL config.\n' >&2
	exit 1
}

if [ "${EMAILWIZ_DOCKER_TEST:-0}" = 1 ]; then
	cp "$test_root/dovecot-2.3.conf" "$test_root/parser-2.3.conf"
	cp "$test_root/dovecot-2.4.conf" "$test_root/parser-2.4.conf"
	cp "$test_root/emailwiz-sql-2.3.conf.ext" "$EMAILWIZ_DOVECOT_SQL_CONF"
	sed -i 's/user = postfix/user = vmail/g;s/group = postfix/group = vmail/g' \
		"$test_root/parser-2.3.conf" "$test_root/parser-2.4.conf"
	docker run --rm -v "$test_root:$test_root:ro" --entrypoint /usr/bin/doveconf \
		dovecot/dovecot:2.3.21 -c "$test_root/parser-2.3.conf" -n >/dev/null
	docker run --rm -v "$test_root:$test_root:ro" --entrypoint /dovecot/bin/doveconf \
		dovecot/dovecot:2.4.2-root -c "$test_root/parser-2.4.conf" -n >/dev/null
fi

if MOCK_DOVECOT_VERSION=2.5.0 "$ctl" system render --no-reload >/dev/null 2>&1; then
	printf 'Unsupported Dovecot 2.5 unexpectedly rendered.\n' >&2
	exit 1
fi

# Purging aliases retains physical mail; purging the final address removes it.
"$ctl" user delete info@example.net --purge
"$ctl" user delete ahmet.mehmet@example.com --purge
[ -d "$test_root/home/alice/Mail" ] || {
	printf 'Shared Mail directory was unexpectedly purged.\n' >&2
	exit 1
}
"$ctl" user delete alice@example.com --purge
[ ! -e "$test_root/home/alice/Mail" ] || {
	printf 'Purged Mail directory still exists.\n' >&2
	exit 1
}
assert_sql 0 "SELECT COUNT(*) FROM mail_users WHERE email = 'alice@example.com';"

MOCK_DOVECOT_VERSION=2.4.2 "$ctl" domain delete example.net --purge --no-reload
assert_sql 0 "SELECT COUNT(*) FROM domains WHERE name = 'example.net';"
[ ! -e "$test_root/etc/postfix/dkim/example.net" ] || {
	printf 'Purged DKIM directory still exists.\n' >&2
	exit 1
}

if MOCK_DOVECOT_VERSION=2.4.2 "$ctl" domain delete example.com --no-reload >/dev/null 2>&1; then
	printf 'The last active domain was unexpectedly disabled.\n' >&2
	exit 1
fi

assert_contains 'v=spf1 mx a:mail.example.com -all' "$EMAILWIZ_DNS_DIR/example.com.txt"
assert_contains 'v=spf1 mx a:mail.example.com -all' "$EMAILWIZ_DNS_DIR/example.net.txt"
assert_contains "$(printf 'example.net\tMX\t10\tmail.example.com\t300')" "$EMAILWIZ_DNS_DIR/example.net.txt"

# Version 1 databases are upgraded from per-domain TLS columns to one
# canonical system TLS identity without losing domain or mailbox rows.
migration_root="$test_root/migration"
migration_db="$migration_root/state/emailwiz.sqlite3"
mkdir -p "$migration_root/state" "$migration_root/etc/dovecot" \
	"$migration_root/etc/postfix/dkim" "$migration_root/sieve"
: > "$migration_root/etc/dovecot/dovecot.conf"
"$bin_dir/sqlite3" "$migration_db" <<EOF
CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
INSERT INTO metadata VALUES('certificate_mode', 'letsencrypt');
CREATE TABLE domains (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL COLLATE NOCASE UNIQUE,
    mail_hostname TEXT NOT NULL COLLATE NOCASE UNIQUE,
    cert_dir TEXT NOT NULL,
    dkim_selector TEXT NOT NULL DEFAULT 'mail',
    enabled INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at TEXT
);
CREATE TABLE mail_users (
    id INTEGER PRIMARY KEY,
    domain_id INTEGER NOT NULL REFERENCES domains(id) ON DELETE RESTRICT,
    localpart TEXT NOT NULL COLLATE NOCASE,
    email TEXT NOT NULL COLLATE NOCASE UNIQUE,
    password_hash TEXT NOT NULL,
    home_path TEXT NOT NULL,
    uid INTEGER NOT NULL,
    gid INTEGER NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at TEXT,
    UNIQUE(domain_id, localpart)
);
INSERT INTO domains(id, name, mail_hostname, cert_dir)
VALUES(7, 'legacy.example', 'mail.legacy.example', '$test_root/certs/mail.example.com');
INSERT INTO mail_users(id, domain_id, localpart, email, password_hash, home_path, uid, gid)
VALUES(9, 7, 'alice', 'alice@legacy.example', 'hash', '$test_root/home/alice', $uid, $gid);
EOF
EMAILWIZ_STATE_DIR="$migration_root/state" \
EMAILWIZ_DB_PATH="$migration_db" \
EMAILWIZ_DNS_DIR="$migration_root/state/dns" \
EMAILWIZ_DOVECOT_CONF="$migration_root/etc/dovecot/dovecot.conf" \
EMAILWIZ_DOVECOT_SQL_CONF="$migration_root/etc/dovecot/emailwiz-sql.conf.ext" \
EMAILWIZ_POSTFIX_DIR="$migration_root/etc/postfix" \
EMAILWIZ_OPENDKIM_KEYTABLE="$migration_root/etc/postfix/dkim/keytable" \
EMAILWIZ_OPENDKIM_SIGNINGTABLE="$migration_root/etc/postfix/dkim/signingtable" \
EMAILWIZ_DKIM_ROOT="$migration_root/etc/postfix/dkim" \
EMAILWIZ_SIEVE_DIR="$migration_root/sieve" \
EMAILWIZ_RENEW_HOOK="$migration_root/renewal-hooks/deploy/emailwiz" \
MOCK_DOVECOT_VERSION=2.3.16 "$ctl" system init
[ "$("$bin_dir/sqlite3" "$migration_db" "SELECT value FROM metadata WHERE key = 'schema_version';")" = 5 ] || {
	printf 'Migrated database does not use schema metadata version 5.\n' >&2
	exit 1
}
[ "$("$bin_dir/sqlite3" "$migration_db" "SELECT COUNT(*) FROM metadata WHERE key = 'certificate_mode';")" = 0 ] || {
	printf 'Legacy certificate_mode metadata was not removed.\n' >&2
	exit 1
}
[ "$("$bin_dir/sqlite3" "$migration_db" "SELECT value FROM metadata WHERE key = 'canonical_mail_hostname';")" = mail.legacy.example ] || {
	printf 'Legacy canonical hostname was not migrated.\n' >&2
	exit 1
}
[ "$("$bin_dir/sqlite3" "$migration_db" "SELECT COUNT(*) FROM mail_users WHERE id = 9 AND domain_id = 7;")" = 1 ] || {
	printf 'Legacy mailbox row was not retained during migration.\n' >&2
	exit 1
}
[ "$("$bin_dir/sqlite3" "$migration_db" "SELECT COUNT(*) FROM mailboxes m JOIN mail_users u ON u.mailbox_id = m.id WHERE u.id = 9 AND m.home_path = '$test_root/home/alice' AND m.uid = $uid AND m.gid = $gid;")" = 1 ] || {
	printf 'Legacy filesystem mapping was not moved to the mailbox table.\n' >&2
	exit 1
}
[ "$("$bin_dir/sqlite3" "$migration_db" "SELECT length(storage_id) FROM mailboxes;")" = 32 ] || {
	printf 'Legacy mailbox did not receive a stable internal storage ID.\n' >&2
	exit 1
}
[ "$("$bin_dir/sqlite3" "$migration_db" "SELECT \"notnull\" FROM pragma_table_info('mail_users') WHERE name = 'password_hash';")" = 0 ] || {
	printf 'Migrated password_hash does not allow delivery-only aliases.\n' >&2
	exit 1
}
[ "$("$bin_dir/sqlite3" "$migration_db" "SELECT canonical_localpart || '|' || password_hash FROM mail_users WHERE id = 9;")" = 'alice|hash' ] || {
	printf 'Legacy authentication identity was not retained during migration.\n' >&2
	exit 1
}
[ "$("$bin_dir/sqlite3" "$migration_db" "SELECT COUNT(*) FROM pragma_table_info('domains') WHERE name IN ('mail_hostname', 'cert_dir');")" = 0 ] || {
	printf 'Legacy per-domain TLS columns were not removed.\n' >&2
	exit 1
}
[ -z "$("$bin_dir/sqlite3" "$migration_db" 'PRAGMA foreign_key_check;')" ] || {
	printf 'Legacy migration left invalid foreign keys.\n' >&2
	exit 1
}

# Version 4 databases gain stable internal storage identities and nullable
# password hashes without losing existing mailbox/address relationships.
v4_root="$test_root/v4-migration"
v4_db="$v4_root/state/emailwiz.sqlite3"
mkdir -p "$v4_root/state" "$v4_root/etc/dovecot" \
	"$v4_root/etc/postfix/dkim" "$v4_root/sieve"
: > "$v4_root/etc/dovecot/dovecot.conf"
"$bin_dir/sqlite3" "$v4_db" <<EOF
CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
INSERT INTO metadata VALUES('schema_version', '4');
CREATE TABLE domains (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL COLLATE NOCASE UNIQUE,
    dkim_selector TEXT NOT NULL DEFAULT 'mail',
    enabled INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at TEXT
);
CREATE TABLE mailboxes (
    id INTEGER PRIMARY KEY,
    home_path TEXT NOT NULL UNIQUE,
    uid INTEGER NOT NULL,
    gid INTEGER NOT NULL,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE mail_users (
    id INTEGER PRIMARY KEY,
    mailbox_id INTEGER NOT NULL REFERENCES mailboxes(id) ON DELETE RESTRICT,
    domain_id INTEGER NOT NULL REFERENCES domains(id) ON DELETE RESTRICT,
    localpart TEXT NOT NULL COLLATE NOCASE,
    canonical_localpart TEXT NOT NULL COLLATE NOCASE,
    email TEXT NOT NULL COLLATE NOCASE UNIQUE,
    password_hash TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at TEXT,
    UNIQUE(domain_id, canonical_localpart)
);
INSERT INTO domains(id, name) VALUES(1, 'v4.example');
INSERT INTO mailboxes(id, home_path, uid, gid)
VALUES(2, '$test_root/home/alice', $uid, $gid);
INSERT INTO mail_users(id, mailbox_id, domain_id, localpart, canonical_localpart, email, password_hash)
VALUES(3, 2, 1, 'alice', 'alice', 'alice@v4.example', 'v4-hash');
EOF
EMAILWIZ_STATE_DIR="$v4_root/state" \
EMAILWIZ_DB_PATH="$v4_db" \
EMAILWIZ_DNS_DIR="$v4_root/state/dns" \
EMAILWIZ_DOVECOT_CONF="$v4_root/etc/dovecot/dovecot.conf" \
EMAILWIZ_DOVECOT_SQL_CONF="$v4_root/etc/dovecot/emailwiz-sql.conf.ext" \
EMAILWIZ_POSTFIX_DIR="$v4_root/etc/postfix" \
EMAILWIZ_OPENDKIM_KEYTABLE="$v4_root/etc/postfix/dkim/keytable" \
EMAILWIZ_OPENDKIM_SIGNINGTABLE="$v4_root/etc/postfix/dkim/signingtable" \
EMAILWIZ_DKIM_ROOT="$v4_root/etc/postfix/dkim" \
EMAILWIZ_SIEVE_DIR="$v4_root/sieve" \
EMAILWIZ_RENEW_HOOK="$v4_root/renewal-hooks/deploy/emailwiz" \
MOCK_DOVECOT_VERSION=2.3.16 "$ctl" system init
[ "$("$bin_dir/sqlite3" "$v4_db" "SELECT value FROM metadata WHERE key = 'schema_version';")" = 5 ] || {
	printf 'Version 4 database was not upgraded to schema 5.\n' >&2
	exit 1
}
[ "$("$bin_dir/sqlite3" "$v4_db" "SELECT length(m.storage_id) || '|' || u.password_hash FROM mailboxes m JOIN mail_users u ON u.mailbox_id = m.id WHERE u.id = 3;")" = '32|v4-hash' ] || {
	printf 'Version 4 storage identity or password was not retained.\n' >&2
	exit 1
}
[ "$("$bin_dir/sqlite3" "$v4_db" "SELECT \"notnull\" FROM pragma_table_info('mail_users') WHERE name = 'password_hash';")" = 0 ] || {
	printf 'Version 4 password constraint was not relaxed for aliases.\n' >&2
	exit 1
}
[ -z "$("$bin_dir/sqlite3" "$v4_db" 'PRAGMA foreign_key_check;')" ] || {
	printf 'Version 4 migration left invalid foreign keys.\n' >&2
	exit 1
}

printf 'emailwizctl integration tests passed\n'
[ "${EMAILWIZ_TEST_KEEP_ROOT:-0}" != 1 ] || printf 'test_root=%s\n' "$test_root"
