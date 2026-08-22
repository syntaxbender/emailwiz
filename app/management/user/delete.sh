#!/bin/sh

user_delete() {
	require_root
	require_database
	[ "$#" -ge 1 ] || die "user delete requires ADDRESS."
	address=$(normalize_address "$1")
	shift
	purge=0
	while [ "$#" -gt 0 ]; do
		case "$1" in --purge) purge=1; shift ;; *) die "Unknown user delete option: $1" ;; esac
	done
	q_address=$(sql_escape "$address")
	[ "$(sql "SELECT COUNT(*) FROM mail_users WHERE email = '$q_address';")" -gt 0 ] || die "User does not exist: $address"
	home=$(sql "SELECT home_path FROM mail_users WHERE email = '$q_address';")
	sql "UPDATE mail_users SET enabled = 0, deleted_at = CURRENT_TIMESTAMP WHERE email = '$q_address';"
	if [ "$purge" -eq 1 ]; then
		q_home=$(sql_escape "$home")
		home_users=$(sql "SELECT COUNT(*) FROM mail_users WHERE home_path = '$q_home';")
		mail_purged=1
		if [ "$home_users" -gt 1 ]; then
			mail_purged=0
			warn "Another virtual mailbox uses $home; the shared Mail directory was retained."
		else
			safe_purge_mail_dir "$home"
		fi
		sql "DELETE FROM mail_users WHERE email = '$q_address';"
		if [ "$mail_purged" -eq 1 ]; then
			say "Purged virtual mailbox $address and $home/Mail. The Unix account and home directory were retained."
		else
			say "Purged virtual mailbox identity $address; shared mail data was retained."
		fi
	else
		say "Disabled virtual mailbox $address; $home/Mail was retained."
	fi
}
