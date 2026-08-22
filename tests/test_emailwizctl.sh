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
cat >/dev/null
printf '{SHA512-CRYPT}$6$testsalt$testhash\n'
EOF

cat > "$bin_dir/getent" <<EOF
#!/bin/sh
if [ "\${1:-}" = passwd ] && [ "\$#" -eq 1 ]; then
	printf 'alice:x:$uid:$gid::${test_root}/home/alice:/bin/sh\n'
	printf 'bob:x:$uid:$gid::${test_root}/home/bob:/bin/sh\n'
	exit 0
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
assert_sql 3 "SELECT value FROM metadata WHERE key = 'schema_version';"
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
if sh "$repo_dir/emailwiz.sh" --help | grep -Fi 'self-signed' >/dev/null; then
	printf 'Installer help still documents self-signed certificate generation.\n' >&2
	exit 1
fi
MOCK_DOVECOT_VERSION=2.3.16 "$ctl" domain add example.com --no-reload
MOCK_DOVECOT_VERSION=2.3.16 "$ctl" domain add example.net --no-reload

assert_contains 'auth_username_format = %Lu' "$EMAILWIZ_DOVECOT_CONF"
assert_contains 'driver = sqlite' "$EMAILWIZ_DOVECOT_SQL_CONF"
assert_contains "ssl_cert = <$test_root/certs/mail.example.com/fullchain.pem" "$EMAILWIZ_DOVECOT_CONF"
if grep -F 'local_name ' "$EMAILWIZ_DOVECOT_CONF" >/dev/null; then
	printf 'Canonical TLS configuration unexpectedly contains a per-domain local_name block.\n' >&2
	exit 1
fi
assert_contains "smtpd_tls_cert_file=$test_root/certs/mail.example.com/fullchain.pem" "$MOCK_COMMAND_LOG"
assert_contains 'myhostname=mail.example.com' "$MOCK_COMMAND_LOG"
assert_contains 'tls_server_sni_maps =' "$MOCK_COMMAND_LOG"
assert_sql 2 'SELECT COUNT(*) FROM domains WHERE enabled = 1;'
assert_sql 0 "SELECT COUNT(*) FROM pragma_table_info('domains') WHERE name IN ('mail_hostname', 'cert_dir');"
cp "$EMAILWIZ_DOVECOT_CONF" "$test_root/dovecot-2.3.conf"
cp "$EMAILWIZ_DOVECOT_SQL_CONF" "$test_root/emailwiz-sql-2.3.conf.ext"

printf 'correct horse battery staple\n' | MOCK_DOVECOT_VERSION=2.3.16 "$ctl" user add \
	alice@example.com --home "$test_root/home/alice" --password-stdin
assert_sql "$test_root/home/alice" "SELECT home_path FROM mail_users WHERE email = 'alice@example.com';"
assert_sql "$uid|$gid" "SELECT uid || '|' || gid FROM mail_users WHERE email = 'alice@example.com';"

# A second virtual identity may intentionally share the still-empty Mail path.
printf 'another password\n' | MOCK_DOVECOT_VERSION=2.3.16 "$ctl" user add \
	alias@example.net --home "$test_root/home/alice" --password-stdin
assert_sql 2 "SELECT COUNT(*) FROM mail_users WHERE home_path = '$test_root/home/alice';"

# Non-empty pre-existing mail is never adopted or modified.
mkdir "$test_root/home/bob/Mail"
printf 'existing mail\n' > "$test_root/home/bob/Mail/existing"
if printf 'password\n' | MOCK_DOVECOT_VERSION=2.3.16 "$ctl" user add \
	bob@example.com --home "$test_root/home/bob" --password-stdin >/dev/null 2>&1; then
	printf 'A non-empty existing Mail directory was unexpectedly accepted.\n' >&2
	exit 1
fi
assert_sql 0 "SELECT COUNT(*) FROM mail_users WHERE email = 'bob@example.com';"

"$ctl" user delete alice@example.com
assert_sql 0 "SELECT enabled FROM mail_users WHERE email = 'alice@example.com';"
"$ctl" user enable alice@example.com
assert_sql 1 "SELECT enabled FROM mail_users WHERE email = 'alice@example.com';"

MOCK_DOVECOT_VERSION=2.4.2 "$ctl" system render --no-reload
assert_contains 'dovecot_config_version = 2.4.0' "$EMAILWIZ_DOVECOT_CONF"
assert_contains 'sqlite_readonly = yes' "$EMAILWIZ_DOVECOT_CONF"
assert_contains 'auth_username_format = %{user | lower}' "$EMAILWIZ_DOVECOT_CONF"
assert_contains 'ssl_server_cert_file = ' "$EMAILWIZ_DOVECOT_CONF"
assert_contains 'sieve_script default {' "$EMAILWIZ_DOVECOT_CONF"
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

# Purging one shared identity retains physical mail; purging the final one removes it.
"$ctl" user delete alias@example.net --purge
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
[ "$("$bin_dir/sqlite3" "$migration_db" "SELECT value FROM metadata WHERE key = 'schema_version';")" = 3 ] || {
	printf 'Migrated database does not use schema metadata version 3.\n' >&2
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
[ "$("$bin_dir/sqlite3" "$migration_db" "SELECT COUNT(*) FROM pragma_table_info('domains') WHERE name IN ('mail_hostname', 'cert_dir');")" = 0 ] || {
	printf 'Legacy per-domain TLS columns were not removed.\n' >&2
	exit 1
}
[ -z "$("$bin_dir/sqlite3" "$migration_db" 'PRAGMA foreign_key_check;')" ] || {
	printf 'Legacy migration left invalid foreign keys.\n' >&2
	exit 1
}

printf 'emailwizctl integration tests passed\n'
[ "${EMAILWIZ_TEST_KEEP_ROOT:-0}" != 1 ] || printf 'test_root=%s\n' "$test_root"
