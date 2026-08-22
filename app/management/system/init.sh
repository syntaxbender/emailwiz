#!/bin/sh

init_database() {
	require_command "$SQLITE3"
	mkdir -p "$STATE_DIR" "$DNS_DIR"
	chmod 0750 "$STATE_DIR"
	chmod 0755 "$DNS_DIR"

	"$SQLITE3" "$DB_PATH" <<'EOF'
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS domains (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL COLLATE NOCASE UNIQUE,
    dkim_selector TEXT NOT NULL DEFAULT 'mail',
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at TEXT
);
CREATE TABLE IF NOT EXISTS mail_users (
    id INTEGER PRIMARY KEY,
    domain_id INTEGER NOT NULL REFERENCES domains(id) ON DELETE RESTRICT,
    localpart TEXT NOT NULL COLLATE NOCASE,
    email TEXT NOT NULL COLLATE NOCASE UNIQUE,
    password_hash TEXT NOT NULL,
    home_path TEXT NOT NULL,
    uid INTEGER NOT NULL CHECK (uid >= 0),
    gid INTEGER NOT NULL CHECK (gid >= 0),
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at TEXT,
    UNIQUE(domain_id, localpart)
);
CREATE INDEX IF NOT EXISTS mail_users_domain_enabled_idx
    ON mail_users(domain_id, enabled);
CREATE INDEX IF NOT EXISTS mail_users_home_path_idx
    ON mail_users(home_path);
EOF

	# Schema version 1 stored a separate hostname and certificate on every
	# domain. Preserve the first (original/primary) domain as the canonical
	# system TLS identity, then remove the per-domain columns.
	if [ "$(sql "SELECT COUNT(*) FROM pragma_table_info('domains') WHERE name = 'mail_hostname';")" -gt 0 ]; then
		legacy_hostname=$(sql 'SELECT mail_hostname FROM domains ORDER BY id LIMIT 1;')
		legacy_cert_dir=$(sql 'SELECT cert_dir FROM domains ORDER BY id LIMIT 1;')
		if [ -n "$legacy_hostname" ] && [ -n "$legacy_cert_dir" ]; then
			[ -n "$(metadata_get canonical_mail_hostname || true)" ] || metadata_set canonical_mail_hostname "$legacy_hostname"
			[ -n "$(metadata_get canonical_cert_dir || true)" ] || metadata_set canonical_cert_dir "$legacy_cert_dir"
		fi
		"$SQLITE3" "$DB_PATH" <<'EOF'
PRAGMA foreign_keys = OFF;
BEGIN IMMEDIATE;
CREATE TABLE domains_emailwiz_v2 (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL COLLATE NOCASE UNIQUE,
    dkim_selector TEXT NOT NULL DEFAULT 'mail',
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at TEXT
);
INSERT INTO domains_emailwiz_v2(id, name, dkim_selector, enabled, created_at, deleted_at)
    SELECT id, name, dkim_selector, enabled, created_at, deleted_at FROM domains;
DROP TABLE domains;
ALTER TABLE domains_emailwiz_v2 RENAME TO domains;
COMMIT;
PRAGMA foreign_keys = ON;
EOF
		foreign_key_errors=$(sql 'PRAGMA foreign_key_check;')
		[ -z "$foreign_key_errors" ] || die "Database migration produced foreign-key errors: $foreign_key_errors"
	fi

	if [ "${EMAILWIZ_TEST_MODE:-0}" != 1 ]; then
		getent group emailwiz >/dev/null 2>&1 || groupadd --system emailwiz
		for account in postfix dovecot; do
			getent passwd "$account" >/dev/null 2>&1 || die "Required system account does not exist: $account"
			usermod -a -G emailwiz "$account"
		done
		chown root:emailwiz "$STATE_DIR" "$DB_PATH"
		chmod 0750 "$STATE_DIR"
		chmod 0640 "$DB_PATH"
	fi
}

write_postfix_lookup_configs() {
	mkdir -p "$POSTFIX_DIR"
	cat > "$POSTFIX_DIR/emailwiz-virtual-domains.cf" <<EOF
dbpath = $DB_PATH
query = SELECT 1 FROM domains WHERE name = lower('%s') AND enabled = 1
EOF
	cat > "$POSTFIX_DIR/emailwiz-virtual-mailboxes.cf" <<EOF
dbpath = $DB_PATH
query = SELECT 1 FROM mail_users u JOIN domains d ON d.id = u.domain_id WHERE u.email = lower('%s') AND u.enabled = 1 AND d.enabled = 1
EOF
	cat > "$POSTFIX_DIR/emailwiz-sender-logins.cf" <<EOF
dbpath = $DB_PATH
query = SELECT u.email FROM mail_users u JOIN domains d ON d.id = u.domain_id WHERE u.email = lower('%s') AND u.enabled = 1 AND d.enabled = 1
EOF
	chmod 0640 "$POSTFIX_DIR"/emailwiz-*.cf
	if [ "${EMAILWIZ_TEST_MODE:-0}" != 1 ]; then
		chown root:postfix "$POSTFIX_DIR"/emailwiz-*.cf
	fi
}

write_sieve_default() {
	mkdir -p "$SIEVE_DIR"
	spamassassin_enabled=$(metadata_get spamassassin_enabled || true)
	if [ "$spamassassin_enabled" = yes ]; then
		cat > "$SIEVE_DIR/default.sieve" <<'EOF'
require ["fileinto", "mailbox"];
if header :contains "X-Spam-Flag" "YES"
{
    fileinto :create "Junk";
}
EOF
	else
		cat > "$SIEVE_DIR/default.sieve" <<'EOF'
# SpamAssassin is disabled; retain normal Sieve delivery without a global rule.
keep;
EOF
	fi
	chmod 0644 "$SIEVE_DIR/default.sieve"
	if command -v sievec >/dev/null 2>&1; then
		sievec "$SIEVE_DIR/default.sieve"
	fi
}

write_renew_hook() {
	mkdir -p "$(dirname "$RENEW_HOOK")"
	cat > "$RENEW_HOOK" <<EOF
#!/bin/sh
set -eu
systemctl reload postfix
systemctl reload dovecot
EOF
	chmod 0755 "$RENEW_HOOK"
}

system_init() {
	require_root
	spamassassin=''
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--spamassassin)
				[ "$#" -ge 2 ] || die "--spamassassin requires a value."
				spamassassin=$2
				shift 2
				;;
			*) die "Unknown system init option: $1" ;;
		esac
	done
	validate_ubuntu_release
	detect_dovecot
	init_database
	if [ -z "$spamassassin" ]; then
		spamassassin=$(metadata_get spamassassin_enabled || true)
		spamassassin=${spamassassin:-no}
	fi
	case "$spamassassin" in yes|no) ;; *) die "SpamAssassin mode must be yes or no." ;; esac
	metadata_set schema_version 3
	metadata_delete certificate_mode
	metadata_set spamassassin_enabled "$spamassassin"
	metadata_set dovecot_version "$DOVECOT_VERSION"
	metadata_set dovecot_family "$DOVECOT_FAMILY"
	metadata_set mailbox_format maildir
	write_postfix_lookup_configs
	write_sieve_default
	write_renew_hook
	if [ -f "$DOVECOT_CONF" ] && [ ! -f "$DOVECOT_CONF.pre-emailwiz" ]; then
		cp -p "$DOVECOT_CONF" "$DOVECOT_CONF.pre-emailwiz"
	fi
	say "Initialized Emailwiz database at $DB_PATH (Dovecot $DOVECOT_VERSION, config family $DOVECOT_FAMILY)."
}
