#!/bin/sh

# Input, platform and certificate validation shared by management commands.

normalize_domain() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

validate_certificate_authenticator() {
	case "$1" in
		http-01|dns-acme|dns-cloudflare|external) ;;
		*) die "Certificate authenticator must be http-01, dns-acme, dns-cloudflare or external." ;;
	esac
}

validate_domain() {
	domain=$1
	[ ${#domain} -le 253 ] || die "Domain is longer than 253 characters: $domain"
	case "$domain" in
		''|.*|*.|*..*|*[!a-z0-9.-]*) die "Invalid domain: $domain" ;;
	esac
	old_ifs=$IFS
	IFS=.
	# Split the already validated domain on dots.
	# shellcheck disable=SC2086
	set -- $domain
	IFS=$old_ifs
	[ "$#" -ge 2 ] || die "Domain must contain at least one dot: $domain"
	for label do
		[ -n "$label" ] || die "Domain contains an empty label: $domain"
		[ ${#label} -le 63 ] || die "Domain label is longer than 63 characters: $label"
		case "$label" in
			-*|*-) die "Domain labels cannot start or end with '-': $label" ;;
		esac
	done
}

validate_localpart() {
	localpart=$1
	[ -n "$localpart" ] || die "Email local part cannot be empty."
	[ ${#localpart} -le 64 ] || die "Email local part is longer than 64 characters."
	case "$localpart" in
		.*|*.|*..*|*[!a-z0-9.]*) die "Unsupported email local part: $localpart (only letters, digits and dots are allowed)" ;;
	esac
}

canonicalize_localpart() {
	printf '%s' "$1" | tr -d '.'
}

normalize_address() {
	address=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
	case "$address" in
		*@*) ;;
		*) die "Expected a full email address (user@example.com): $address" ;;
	esac
	localpart=${address%@*}
	domain=${address#*@}
	case "$domain" in
		*@*) die "Invalid email address: $address" ;;
	esac
	validate_localpart "$localpart"
	validate_domain "$domain"
	printf '%s\n' "$address"
}

detect_dovecot() {
	require_command dovecot
	DOVECOT_VERSION=$(dovecot --version 2>/dev/null | awk 'NR == 1 { print $1 }')
	case "$DOVECOT_VERSION" in
		2.3|2.3.*) DOVECOT_FAMILY=2.3 ;;
		2.4|2.4.*) DOVECOT_FAMILY=2.4 ;;
		*) die "Unsupported Dovecot version '$DOVECOT_VERSION'. Supported configuration families: 2.3 and 2.4." ;;
	esac
}

validate_ubuntu_release() {
	[ "${EMAILWIZ_TEST_MODE:-0}" = 1 ] && return 0
	[ -r "$OS_RELEASE_FILE" ] || die "Cannot read operating system release information: $OS_RELEASE_FILE"
	ubuntu_id=$(sed -n 's/^ID=//p' "$OS_RELEASE_FILE" | tr -d '"' | head -n1)
	ubuntu_version=$(sed -n 's/^VERSION_ID=//p' "$OS_RELEASE_FILE" | tr -d '"' | head -n1)
	[ "$ubuntu_id" = ubuntu ] || die "Unsupported operating system '$ubuntu_id'. Emailwiz targets Ubuntu 22.04 and newer."
	[ -n "$ubuntu_version" ] || die "Ubuntu VERSION_ID is missing from $OS_RELEASE_FILE."
	dpkg --compare-versions "$ubuntu_version" ge 22.04 || die "Ubuntu $ubuntu_version is too old. Minimum supported version: 22.04."
}

validate_certificate_dir() {
	cert_dir=$1
	case "$cert_dir" in
		/*) ;;
		*) die "Certificate directory must be an absolute path: $cert_dir" ;;
	esac
	case "$cert_dir" in *[[:space:]]*) die "Certificate directory cannot contain whitespace: $cert_dir" ;; esac
	[ -f "$cert_dir/fullchain.pem" ] || die "Certificate chain not found: $cert_dir/fullchain.pem"
	[ -f "$cert_dir/privkey.pem" ] || die "Certificate key not found: $cert_dir/privkey.pem"
}

validate_certificate_hostname() {
	cert_dir=$1
	hostname=$2
	validate_certificate_dir "$cert_dir"
	[ "${EMAILWIZ_TEST_MODE:-0}" = 1 ] && return 0
	openssl x509 -in "$cert_dir/fullchain.pem" -noout -checkhost "$hostname" >/dev/null 2>&1 ||
		die "Certificate in $cert_dir is not valid for $hostname."
}

load_canonical_tls() {
	CANONICAL_MAIL_HOSTNAME=$(metadata_get canonical_mail_hostname || true)
	CANONICAL_CERT_DIR=$(metadata_get canonical_cert_dir || true)
	[ -n "$CANONICAL_MAIL_HOSTNAME" ] && [ -n "$CANONICAL_CERT_DIR" ] ||
		die "Canonical TLS is not configured. Run '$PROGRAM system tls HOSTNAME --cert-dir DIR'."
	validate_certificate_hostname "$CANONICAL_CERT_DIR" "$CANONICAL_MAIL_HOSTNAME"
}
