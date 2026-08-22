#!/bin/sh

user_add() {
	require_root
	require_database
	[ "$#" -ge 1 ] || die "user add requires ADDRESS."
	address=$(normalize_address "$1")
	shift
	unix_user=''
	password_stdin=0
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--unix-user)
				[ "$#" -ge 2 ] || die "--unix-user requires a value."
				unix_user=$2
				shift 2
				;;
			--password-stdin) password_stdin=1; shift ;;
			*) die "Unknown user add option: $1" ;;
		esac
	done
	[ -n "$unix_user" ] || die "user add requires --unix-user USER."
	domain=${address#*@}
	localpart=${address%@*}
	canonical_localpart=$(canonicalize_localpart "$localpart")
	domain_is_active "$domain" || die "Domain is not active: $domain"
	q_address=$(sql_escape "$address")
	q_domain=$(sql_escape "$domain")
	q_canonical_localpart=$(sql_escape "$canonical_localpart")
	conflicting_address=$(sql "SELECT u.email FROM mail_users u JOIN domains d ON d.id = u.domain_id WHERE d.name = '$q_domain' AND u.canonical_localpart = '$q_canonical_localpart' LIMIT 1;")
	[ -z "$conflicting_address" ] || die "Address conflicts with existing dotted identity: $conflicting_address"
	resolve_unix_user "$unix_user"
	q_home=$(sql_escape "$home")
	mailbox_row=$(sql "SELECT id || '|' || uid || '|' || gid FROM mailboxes WHERE home_path = '$q_home';")
	[ -z "$mailbox_row" ] || die "The Unix user's mailbox is already managed. Add another address with '$PROGRAM alias add ADDRESS --to TARGET'."
	read_password "$password_stdin"
	q_localpart=$(sql_escape "$localpart")
	q_hash=$(sql_escape "$password_hash")
	prepare_mail_home "$home" "$uid" "$gid"
	sql "INSERT INTO mailboxes(storage_id, home_path, uid, gid) VALUES(lower(hex(randomblob(16))), '$q_home', $uid, $gid);"
	mailbox_id=$(sql "SELECT id FROM mailboxes WHERE home_path = '$q_home';")
	sql "INSERT INTO mail_users(mailbox_id, domain_id, localpart, canonical_localpart, email, password_hash) SELECT $mailbox_id, id, '$q_localpart', '$q_canonical_localpart', '$q_address', '$q_hash' FROM domains WHERE name = '$q_domain' AND enabled = 1;"
	say "Created mail user $address -> $home/Mail (Unix owner: $unix_user, UID $uid, GID $gid)."
}
