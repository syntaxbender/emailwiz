#!/bin/sh

# SQLite access shared by the management features.

sql_escape() {
	printf '%s' "$1" | sed "s/'/''/g"
}

sql() {
	"$SQLITE3" "$DB_PATH" "PRAGMA foreign_keys = ON; $1"
}

database_exists() {
	[ -f "$DB_PATH" ]
}

require_database() {
	database_exists || die "Emailwiz is not initialized. Run '$PROGRAM system init' first."
}

metadata_get() {
	key=$(sql_escape "$1")
	sql "SELECT value FROM metadata WHERE key = '$key';"
}

metadata_set() {
	key=$(sql_escape "$1")
	value=$(sql_escape "$2")
	sql "INSERT INTO metadata(key, value) VALUES('$key', '$value') ON CONFLICT(key) DO UPDATE SET value = excluded.value;"
}

metadata_delete() {
	key=$(sql_escape "$1")
	sql "DELETE FROM metadata WHERE key = '$key';"
}

domain_exists() {
	domain=$(sql_escape "$1")
	[ "$(sql "SELECT COUNT(*) FROM domains WHERE name = '$domain';")" -gt 0 ]
}

domain_is_active() {
	domain=$(sql_escape "$1")
	[ "$(sql "SELECT COUNT(*) FROM domains WHERE name = '$domain' AND enabled = 1;")" -gt 0 ]
}

active_domain_count() {
	sql 'SELECT COUNT(*) FROM domains WHERE enabled = 1;'
}
