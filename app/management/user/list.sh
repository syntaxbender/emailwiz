#!/bin/sh

user_list() {
	require_database
	all=0
	domain=''
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--all) all=1; shift ;;
			--domain)
				[ "$#" -ge 2 ] || die "--domain requires a value."
				domain=$(normalize_domain "$2")
				validate_domain "$domain"
				shift 2
				;;
			*) die "Unknown user list option: $1" ;;
		esac
	done
	conditions='1 = 1'
	[ "$all" -eq 1 ] || conditions="$conditions AND u.enabled = 1 AND d.enabled = 1"
	if [ -n "$domain" ]; then
		q_domain=$(sql_escape "$domain")
		conditions="$conditions AND d.name = '$q_domain'"
	fi
	"$SQLITE3" -header -column "$DB_PATH" "SELECT u.email, u.home_path, u.uid, u.gid, CASE u.enabled WHEN 1 THEN 'active' ELSE 'disabled' END AS status, CASE d.enabled WHEN 1 THEN 'active' ELSE 'domain-disabled' END AS domain_status FROM mail_users u JOIN domains d ON d.id = u.domain_id WHERE $conditions ORDER BY u.email;"
}
