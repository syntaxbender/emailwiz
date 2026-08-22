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
	mailbox_row=$(sql "SELECT m.id || '|' || m.home_path FROM mail_users u JOIN mailboxes m ON m.id = u.mailbox_id WHERE u.email = '$q_address';")
	mailbox_id=${mailbox_row%%|*}
	home=${mailbox_row#*|}
	sql "UPDATE mail_users SET enabled = 0, deleted_at = CURRENT_TIMESTAMP WHERE email = '$q_address';"
	if [ "$purge" -eq 1 ]; then
		home_users=$(sql "SELECT COUNT(*) FROM mail_users WHERE mailbox_id = $mailbox_id;")
		mail_purged=1
		if [ "$home_users" -gt 1 ]; then
			mail_purged=0
			warn "Another mail address uses $home; the shared Mail directory was retained."
		else
			safe_purge_mail_dir "$home"
		fi
		sql "DELETE FROM mail_users WHERE email = '$q_address';"
		[ "$mail_purged" -eq 0 ] || sql "DELETE FROM mailboxes WHERE id = $mailbox_id;"
		if [ "$mail_purged" -eq 1 ]; then
			say "Purged mail address $address and $home/Mail. The Unix account and home directory were retained."
		else
			say "Purged mail address $address; shared mail data was retained."
		fi
	else
		say "Disabled mail address $address; $home/Mail was retained."
	fi
}
