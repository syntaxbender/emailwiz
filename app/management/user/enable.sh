#!/bin/sh

user_enable() {
	require_root
	require_database
	[ "$#" -eq 1 ] || die "user enable requires ADDRESS."
	address=$(normalize_address "$1")
	q_address=$(sql_escape "$address")
	row=$(sql "SELECT m.home_path || '|' || m.uid || '|' || m.gid || '|' || d.enabled FROM mail_users u JOIN mailboxes m ON m.id = u.mailbox_id JOIN domains d ON d.id = u.domain_id WHERE u.email = '$q_address';")
	[ -n "$row" ] || die "User does not exist: $address"
	home=${row%%|*}
	mailbox_identity=${row#*|}
	mailbox_identity=${mailbox_identity%|*}
	domain_enabled=${row##*|}
	[ "$domain_enabled" -eq 1 ] || die "Enable the user's domain first."
	validate_home_path "$home"
	[ "$uid|$gid" = "$mailbox_identity" ] || die "Mailbox $home/Mail no longer matches the Unix user's UID/GID."
	validate_existing_mail_home "$home" "$uid" "$gid"
	sql "UPDATE mail_users SET enabled = 1, deleted_at = NULL WHERE email = '$q_address';"
	say "Enabled mail address $address."
}
