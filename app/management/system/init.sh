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
CREATE TABLE IF NOT EXISTS mailboxes (
    id INTEGER PRIMARY KEY,
    storage_id TEXT NOT NULL UNIQUE,
    home_path TEXT NOT NULL UNIQUE,
    uid INTEGER NOT NULL CHECK (uid >= 0),
    gid INTEGER NOT NULL CHECK (gid >= 0),
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS mail_users (
    id INTEGER PRIMARY KEY,
    mailbox_id INTEGER NOT NULL REFERENCES mailboxes(id) ON DELETE RESTRICT,
    domain_id INTEGER NOT NULL REFERENCES domains(id) ON DELETE RESTRICT,
    localpart TEXT NOT NULL COLLATE NOCASE,
    canonical_localpart TEXT NOT NULL COLLATE NOCASE,
    email TEXT NOT NULL COLLATE NOCASE UNIQUE,
    password_hash TEXT,
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at TEXT,
    UNIQUE(domain_id, canonical_localpart)
);
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

	# Schema versions through 3 kept filesystem ownership and the password in
	# one row. Version 5 separates the shared physical mailbox from independently
	# authenticated addresses. A NULL password marks a delivery-only alias.
	if [ "$(sql "SELECT COUNT(*) FROM pragma_table_info('mail_users') WHERE name = 'mailbox_id';")" -eq 0 ]; then
		invalid_legacy_address=$(sql "SELECT email FROM mail_users WHERE localpart = '' OR length(localpart) > 64 OR localpart LIKE '.%' OR localpart LIKE '%.' OR instr(localpart, '..') > 0 OR lower(localpart) GLOB '*[^a-z0-9.]*' LIMIT 1;")
		[ -z "$invalid_legacy_address" ] || die "Legacy user uses a local part unsupported by schema 5: $invalid_legacy_address"
		identity_conflict=$(sql "SELECT d.name || ': ' || group_concat(u.email, ', ') FROM mail_users u JOIN domains d ON d.id = u.domain_id GROUP BY u.domain_id, replace(lower(u.localpart), '.', '') HAVING COUNT(*) > 1 LIMIT 1;")
		[ -z "$identity_conflict" ] || die "Legacy dotted-address collision must be resolved before migration: $identity_conflict"
		ownership_conflict=$(sql "SELECT home_path FROM mail_users GROUP BY home_path HAVING MIN(uid) <> MAX(uid) OR MIN(gid) <> MAX(gid) LIMIT 1;")
		[ -z "$ownership_conflict" ] || die "Legacy users disagree on UID/GID for shared home: $ownership_conflict"

		"$SQLITE3" "$DB_PATH" <<'EOF'
PRAGMA foreign_keys = OFF;
BEGIN IMMEDIATE;
INSERT INTO mailboxes(storage_id, home_path, uid, gid, created_at)
    SELECT lower(hex(randomblob(16))), home_path, MIN(uid), MIN(gid), MIN(created_at)
    FROM mail_users
    GROUP BY home_path;
CREATE TABLE mail_users_emailwiz_v5 (
    id INTEGER PRIMARY KEY,
    mailbox_id INTEGER NOT NULL REFERENCES mailboxes(id) ON DELETE RESTRICT,
    domain_id INTEGER NOT NULL REFERENCES domains(id) ON DELETE RESTRICT,
    localpart TEXT NOT NULL COLLATE NOCASE,
    canonical_localpart TEXT NOT NULL COLLATE NOCASE,
    email TEXT NOT NULL COLLATE NOCASE UNIQUE,
    password_hash TEXT,
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at TEXT,
    UNIQUE(domain_id, canonical_localpart)
);
INSERT INTO mail_users_emailwiz_v5(
    id, mailbox_id, domain_id, localpart, canonical_localpart, email,
    password_hash, enabled, created_at, deleted_at
)
SELECT u.id, m.id, u.domain_id, lower(u.localpart),
       replace(lower(u.localpart), '.', ''), lower(u.email),
       u.password_hash, u.enabled, u.created_at, u.deleted_at
FROM mail_users u
JOIN mailboxes m ON m.home_path = u.home_path;
DROP TABLE mail_users;
ALTER TABLE mail_users_emailwiz_v5 RENAME TO mail_users;
COMMIT;
PRAGMA foreign_keys = ON;
EOF
	fi

	# Version 4 mailboxes did not have a stable internal Dovecot identity and
	# required every address to have a password. Rebuild both tables once so
	# multiple credentials can safely resolve to one Dovecot storage user.
	if [ "$(sql "SELECT COUNT(*) FROM pragma_table_info('mailboxes') WHERE name = 'storage_id';")" -eq 0 ]; then
		"$SQLITE3" "$DB_PATH" <<'EOF'
PRAGMA foreign_keys = OFF;
BEGIN IMMEDIATE;
CREATE TABLE mailboxes_emailwiz_v5 (
    id INTEGER PRIMARY KEY,
    storage_id TEXT NOT NULL UNIQUE,
    home_path TEXT NOT NULL UNIQUE,
    uid INTEGER NOT NULL CHECK (uid >= 0),
    gid INTEGER NOT NULL CHECK (gid >= 0),
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO mailboxes_emailwiz_v5(id, storage_id, home_path, uid, gid, created_at)
    SELECT id, lower(hex(randomblob(16))), home_path, uid, gid, created_at FROM mailboxes;
CREATE TABLE mail_users_emailwiz_v5 (
    id INTEGER PRIMARY KEY,
    mailbox_id INTEGER NOT NULL REFERENCES mailboxes(id) ON DELETE RESTRICT,
    domain_id INTEGER NOT NULL REFERENCES domains(id) ON DELETE RESTRICT,
    localpart TEXT NOT NULL COLLATE NOCASE,
    canonical_localpart TEXT NOT NULL COLLATE NOCASE,
    email TEXT NOT NULL COLLATE NOCASE UNIQUE,
    password_hash TEXT,
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at TEXT,
    UNIQUE(domain_id, canonical_localpart)
);
INSERT INTO mail_users_emailwiz_v5(
    id, mailbox_id, domain_id, localpart, canonical_localpart, email,
    password_hash, enabled, created_at, deleted_at
)
    SELECT id, mailbox_id, domain_id, localpart, canonical_localpart, email,
           password_hash, enabled, created_at, deleted_at FROM mail_users;
DROP TABLE mail_users;
DROP TABLE mailboxes;
ALTER TABLE mailboxes_emailwiz_v5 RENAME TO mailboxes;
ALTER TABLE mail_users_emailwiz_v5 RENAME TO mail_users;
COMMIT;
PRAGMA foreign_keys = ON;
EOF
	fi

	# Handle a partially upgraded schema that already has storage_id but still
	# carries the version 4 NOT NULL password constraint.
	if [ "$(sql "SELECT \"notnull\" FROM pragma_table_info('mail_users') WHERE name = 'password_hash';")" -eq 1 ]; then
		"$SQLITE3" "$DB_PATH" <<'EOF'
PRAGMA foreign_keys = OFF;
BEGIN IMMEDIATE;
CREATE TABLE mail_users_emailwiz_v5 (
    id INTEGER PRIMARY KEY,
    mailbox_id INTEGER NOT NULL REFERENCES mailboxes(id) ON DELETE RESTRICT,
    domain_id INTEGER NOT NULL REFERENCES domains(id) ON DELETE RESTRICT,
    localpart TEXT NOT NULL COLLATE NOCASE,
    canonical_localpart TEXT NOT NULL COLLATE NOCASE,
    email TEXT NOT NULL COLLATE NOCASE UNIQUE,
    password_hash TEXT,
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at TEXT,
    UNIQUE(domain_id, canonical_localpart)
);
INSERT INTO mail_users_emailwiz_v5
    SELECT id, mailbox_id, domain_id, localpart, canonical_localpart, email,
           password_hash, enabled, created_at, deleted_at FROM mail_users;
DROP TABLE mail_users;
ALTER TABLE mail_users_emailwiz_v5 RENAME TO mail_users;
COMMIT;
PRAGMA foreign_keys = ON;
EOF
	fi

	"$SQLITE3" "$DB_PATH" <<'EOF'
CREATE INDEX IF NOT EXISTS mail_users_domain_enabled_idx
    ON mail_users(domain_id, enabled);
CREATE INDEX IF NOT EXISTS mail_users_mailbox_idx
    ON mail_users(mailbox_id);
EOF
	foreign_key_errors=$(sql 'PRAGMA foreign_key_check;')
	[ -z "$foreign_key_errors" ] || die "Database migration produced foreign-key errors: $foreign_key_errors"

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
query = SELECT 1 FROM mail_users u JOIN domains d ON d.id = u.domain_id WHERE u.canonical_localpart = replace(lower(substr('%s', 1, instr('%s', '@') - 1)), '.', '') AND d.name = lower(substr('%s', instr('%s', '@') + 1)) AND u.enabled = 1 AND d.enabled = 1
EOF
	cat > "$POSTFIX_DIR/emailwiz-sender-logins.cf" <<EOF
dbpath = $DB_PATH
query = SELECT u.email FROM mail_users u JOIN domains d ON d.id = u.domain_id WHERE u.email = lower('%s') AND u.password_hash IS NOT NULL AND u.enabled = 1 AND d.enabled = 1
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
	metadata_set schema_version 5
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
