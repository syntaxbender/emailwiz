#!/bin/sh

user_passwd() {
	require_root
	require_database
	[ "$#" -ge 1 ] || die "user passwd requires ADDRESS."
	address=$(normalize_address "$1")
	shift
	password_stdin=0
	while [ "$#" -gt 0 ]; do
		case "$1" in --password-stdin) password_stdin=1; shift ;; *) die "Unknown user passwd option: $1" ;; esac
	done
	q_address=$(sql_escape "$address")
	[ "$(sql "SELECT COUNT(*) FROM mail_users WHERE email = '$q_address';")" -gt 0 ] || die "User does not exist: $address"
	read_password "$password_stdin"
	q_hash=$(sql_escape "$password_hash")
	sql "UPDATE mail_users SET password_hash = '$q_hash' WHERE email = '$q_address';"
	say "Updated password for $address."
}
