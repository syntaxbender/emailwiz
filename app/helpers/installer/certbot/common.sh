#!/bin/sh

emailwiz_certbot_error() {
	printf 'ERROR: %s\n' "$*" >&2
	return 1
}

emailwiz_certbot_require_absolute_path() {
	path=$1
	label=$2
	case "$path" in
		/*) ;;
		*) emailwiz_certbot_error "$label must be an absolute path: $path" ;;
	esac
}

emailwiz_certbot_verify_output() {
	cert_dir=$1
	if [ ! -f "$cert_dir/fullchain.pem" ]; then
		emailwiz_certbot_error "Certificate chain was not created: $cert_dir/fullchain.pem"
		return 1
	fi
	if [ ! -f "$cert_dir/privkey.pem" ]; then
		emailwiz_certbot_error "Certificate key was not created: $cert_dir/privkey.pem"
		return 1
	fi
	if [ ! -f "$cert_dir/cert.pem" ]; then
		emailwiz_certbot_error "Leaf certificate was not created: $cert_dir/cert.pem"
		return 1
	fi
}
