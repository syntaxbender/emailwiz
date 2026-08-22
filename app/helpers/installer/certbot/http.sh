#!/bin/sh

emailwiz_certbot_http_method() {
	listeners=$(netstat -ltnp 2>/dev/null | awk '$4 ~ /:80$/ { print }')
	has_nginx=0
	has_apache=0
	case "$listeners" in *nginx*) has_nginx=1 ;; esac
	case "$listeners" in *apache*|*httpd*) has_apache=1 ;; esac
	if [ "$has_nginx" -eq 1 ] && [ "$has_apache" -eq 1 ]; then
		emailwiz_certbot_error "Both Nginx and Apache appear to listen on TCP/80; HTTP-01 selection is ambiguous."
	elif [ "$has_nginx" -eq 1 ]; then
		printf '%s\n' nginx
	elif [ "$has_apache" -eq 1 ]; then
		printf '%s\n' apache
	elif [ -z "$listeners" ]; then
		printf '%s\n' standalone
	else
		emailwiz_certbot_error "TCP/80 is occupied by an unsupported process. Free it for Certbot standalone or use Nginx/Apache."
	fi
}

emailwiz_certbot_run_http() {
	hostname=$1
	printf '%s\n' "Emailwiz does not modify firewall rules for HTTP-01." >&2
	printf '%s\n' "Ensure inbound TCP/80 is allowed by UFW and any provider firewall (for example: sudo ufw allow 80/tcp)." >&2
	http_method=$(emailwiz_certbot_http_method) || return 1
	case "$http_method" in
		nginx)
			printf '%s\n' "HTTP-01 method selected: Nginx (active TCP/80 listener detected)." >&2
			apt-get install -y certbot python3-certbot-nginx >&2
			certbot certonly --nginx --cert-name "$hostname" -d "$hostname" \
				--non-interactive --register-unsafely-without-email --agree-tos >&2
			;;
		apache)
			printf '%s\n' "HTTP-01 method selected: Apache (active TCP/80 listener detected)." >&2
			apt-get install -y certbot python3-certbot-apache >&2
			certbot certonly --apache --cert-name "$hostname" -d "$hostname" \
				--non-interactive --register-unsafely-without-email --agree-tos >&2
			;;
		standalone)
			printf '%s\n' "HTTP-01 method selected: Certbot standalone (TCP/80 is currently unused)." >&2
			apt-get install -y certbot >&2
			certbot certonly --standalone --cert-name "$hostname" -d "$hostname" \
				--non-interactive --register-unsafely-without-email --agree-tos >&2
			;;
	esac
}
