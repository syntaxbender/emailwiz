#!/bin/sh

ensure_dkim_key() {
	domain=$1
	selector=$2
	domain_dir="$DKIM_ROOT/$domain"
	mkdir -p "$domain_dir"
	if [ ! -f "$domain_dir/$selector.private" ] || [ ! -f "$domain_dir/$selector.txt" ]; then
		opendkim-genkey -D "$domain_dir" -d "$domain" -s "$selector"
	fi
	if [ "${EMAILWIZ_TEST_MODE:-0}" != 1 ]; then
		chgrp -R opendkim "$domain_dir"
		chmod -R g+r "$domain_dir"
	fi
}

write_dns_records() {
	domain=$1
	hostname=$2
	selector=$3
	pval=$(tr -d '\n' < "$DKIM_ROOT/$domain/$selector.txt" | sed 's/k=rsa.* "p=/k=rsa; p=/;s/"[[:space:]]*"//g;s/"[[:space:]]*).*//' | grep -o 'p=.*')
	output="$DNS_DIR/$domain.txt"
	{
		printf '%s._domainkey.%s\tTXT\tv=DKIM1; k=rsa; %s\n' "$selector" "$domain" "$pval"
		printf '_dmarc.%s\tTXT\tv=DMARC1; p=reject; rua=mailto:dmarc@%s; fo=1\n' "$domain" "$domain"
		printf '%s\tTXT\tv=spf1 mx a:%s -all\n' "$domain" "$hostname"
		printf '%s\tMX\t10\t%s\t300\n' "$domain" "$hostname"
	} > "$output"
	chmod 0644 "$output"
	say "=== ADD THE FOLLOWING DNS RECORDS ==="
	cat "$output"
	say "Records were also stored in $output"
}

safe_remove_dkim_dir() {
	domain=$1
	target="$DKIM_ROOT/$domain"
	[ -e "$target" ] || return 0
	[ ! -L "$target" ] || die "Refusing to purge symlinked DKIM directory: $target"
	resolved=$(readlink -f "$target")
	expected=$(readlink -f "$DKIM_ROOT")/$domain
	[ "$resolved" = "$expected" ] || die "Refusing to purge unexpected DKIM path: $resolved"
	find -P "$target" -xdev -depth -delete
}
