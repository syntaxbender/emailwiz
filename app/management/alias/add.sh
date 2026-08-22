#!/bin/sh

alias_add() {
	require_root
	require_database
	[ "$#" -ge 1 ] || die "alias add requires ADDRESS."
	address=$(normalize_address "$1")
	shift
	target=''
	password_mode=none
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--to)
				[ "$#" -ge 2 ] || die "--to requires an address."
				target=$(normalize_address "$2")
				shift 2
				;;
			--passwd)
				[ "$password_mode" = none ] || die "Choose only one password input mode."
				password_mode=prompt
				shift
				;;
			--password-stdin)
				[ "$password_mode" = none ] || die "Choose only one password input mode."
				password_mode=stdin
				shift
				;;
			*) die "Unknown alias add option: $1" ;;
		esac
	done
	[ -n "$target" ] || die "alias add requires --to TARGET."
	[ "$address" != "$target" ] || die "Alias address and target must be different."

	domain=${address#*@}
	localpart=${address%@*}
	canonical_localpart=$(canonicalize_localpart "$localpart")
	domain_is_active "$domain" || die "Domain is not active: $domain"
	q_domain=$(sql_escape "$domain")
	q_canonical_localpart=$(sql_escape "$canonical_localpart")
	conflicting_address=$(sql "SELECT u.email FROM mail_users u JOIN domains d ON d.id = u.domain_id WHERE d.name = '$q_domain' AND u.canonical_localpart = '$q_canonical_localpart' LIMIT 1;")
	[ -z "$conflicting_address" ] || die "Address conflicts with existing dotted identity: $conflicting_address"

	q_target=$(sql_escape "$target")
	target_row=$(sql "SELECT u.mailbox_id || '|' || m.home_path FROM mail_users u JOIN mailboxes m ON m.id = u.mailbox_id JOIN domains d ON d.id = u.domain_id WHERE u.email = '$q_target' AND u.enabled = 1 AND d.enabled = 1;")
	[ -n "$target_row" ] || die "Active alias target does not exist: $target"
	mailbox_id=${target_row%%|*}
	home=${target_row#*|}

	q_address=$(sql_escape "$address")
	q_localpart=$(sql_escape "$localpart")
	if [ "$password_mode" = none ]; then
		password_sql=NULL
	else
		if [ "$password_mode" = stdin ]; then
			read_password 1
		else
			read_password 0
		fi
		q_hash=$(sql_escape "$password_hash")
		password_sql="'$q_hash'"
	fi
	sql "INSERT INTO mail_users(mailbox_id, domain_id, localpart, canonical_localpart, email, password_hash) SELECT $mailbox_id, id, '$q_localpart', '$q_canonical_localpart', '$q_address', $password_sql FROM domains WHERE name = '$q_domain' AND enabled = 1;"
	if [ "$password_mode" = none ]; then
		say "Created delivery-only alias $address -> $target ($home/Mail)."
	else
		say "Created login alias $address -> $target ($home/Mail)."
	fi
}
