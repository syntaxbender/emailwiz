#!/bin/sh

user_add() {
	require_root
	require_database
	[ "$#" -ge 1 ] || die "user add requires ADDRESS."
	address=$(normalize_address "$1")
	shift
	home=''
	password_stdin=0
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--home)
				[ "$#" -ge 2 ] || die "--home requires a value."
				home=$2
				shift 2
				;;
			--password-stdin) password_stdin=1; shift ;;
			*) die "Unknown user add option: $1" ;;
		esac
	done
	[ -n "$home" ] || die "user add requires --home /home/USER."
	domain=${address#*@}
	localpart=${address%@*}
	domain_is_active "$domain" || die "Domain is not active: $domain"
	q_address=$(sql_escape "$address")
	[ "$(sql "SELECT COUNT(*) FROM mail_users WHERE email = '$q_address';")" -eq 0 ] || die "User already exists: $address"
	validate_home_path "$home"
	read_password "$password_stdin"
	prepare_mail_home "$home" "$uid" "$gid"
	q_domain=$(sql_escape "$domain")
	q_localpart=$(sql_escape "$localpart")
	q_hash=$(sql_escape "$password_hash")
	q_home=$(sql_escape "$home")
	sql "INSERT INTO mail_users(domain_id, localpart, email, password_hash, home_path, uid, gid) SELECT id, '$q_localpart', '$q_address', '$q_hash', '$q_home', $uid, $gid FROM domains WHERE name = '$q_domain' AND enabled = 1;"
	say "Created virtual mailbox $address -> $home/Mail (Unix owner: $unix_user, UID $uid, GID $gid)."
}
