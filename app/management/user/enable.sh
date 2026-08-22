#!/bin/sh

user_enable() {
	require_root
	require_database
	[ "$#" -eq 1 ] || die "user enable requires ADDRESS."
	address=$(normalize_address "$1")
	q_address=$(sql_escape "$address")
	row=$(sql "SELECT u.home_path || '|' || d.enabled FROM mail_users u JOIN domains d ON d.id = u.domain_id WHERE u.email = '$q_address';")
	[ -n "$row" ] || die "User does not exist: $address"
	home=${row%|*}
	domain_enabled=${row##*|}
	[ "$domain_enabled" -eq 1 ] || die "Enable the user's domain first."
	validate_home_path "$home"
	[ -d "$home/Mail" ] || die "Mail directory does not exist: $home/Mail"
	[ ! -L "$home/Mail" ] || die "Symlinked Mail directories are not supported: $home/Mail"
	sql "UPDATE mail_users SET enabled = 1, deleted_at = NULL WHERE email = '$q_address';"
	say "Enabled virtual mailbox $address."
}
