#!/bin/sh

system_version() {
	require_database
	detect_dovecot
	configured=$(metadata_get dovecot_family || true)
	spamassassin=$(metadata_get spamassassin_enabled || true)
	canonical_hostname=$(metadata_get canonical_mail_hostname || true)
	certificate_authenticator=$(metadata_get certificate_authenticator || true)
	printf 'installed=%s\ndetected_family=%s\nconfigured_family=%s\nspamassassin=%s\ncanonical_mail_hostname=%s\ncertificate_authenticator=%s\n' \
		"$DOVECOT_VERSION" "$DOVECOT_FAMILY" "${configured:-not-rendered}" "${spamassassin:-no}" \
		"${canonical_hostname:-not-configured}" "${certificate_authenticator:-not-configured}"
}
