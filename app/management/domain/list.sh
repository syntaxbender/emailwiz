#!/bin/sh

domain_list() {
	require_database
	all=0
	while [ "$#" -gt 0 ]; do
		case "$1" in --all) all=1; shift ;; *) die "Unknown domain list option: $1" ;; esac
	done
	where='WHERE enabled = 1'
	[ "$all" -eq 0 ] || where=''
	"$SQLITE3" -header -column "$DB_PATH" "SELECT name AS domain, CASE enabled WHEN 1 THEN 'active' ELSE 'disabled' END AS status, dkim_selector FROM domains $where ORDER BY name;"
}
