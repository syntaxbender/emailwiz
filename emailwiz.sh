#!/bin/sh

# BEFORE INSTALLING

# Have an Ubuntu 22.04 or newer server with a static IP and DNS records (usually
# A/AAAA) that point your domain name to it.

# NOTE WHILE INSTALLING

# On installation of Postfix, select "Internet Site" and put in TLD (without
# `mail.` before it).

# AFTER INSTALLING

# More DNS records will be given to you to install. One of them will be
# different for every installation and is uniquely generated on your machine.

umask 0022

usage() {
	cat <<'EOF'
Usage: emailwiz.sh [OPTIONS]

  --with-spamassassin     Install SpamAssassin and filter inbound SMTP mail.
  --without-spamassassin  Do not install or configure SpamAssassin (default).
  --certbot-authenticator METHOD
                          http-01 (default), dns-acme or dns-cloudflare.
  --acme-dns-client PATH  Absolute acme-dns-client path for dns-acme
                          (default: /usr/local/bin/acme-dns-client).
  --cloudflare-credentials FILE
                          Root-only INI file containing a Cloudflare API token.
EOF
}

use_spamassassin=no
certbot_authenticator=http-01
acme_dns_client=/usr/local/bin/acme-dns-client
acme_dns_client_explicit=0
cloudflare_credentials=''
while [ "$#" -gt 0 ]; do
	case "$1" in
		--with-spamassassin) use_spamassassin=yes ;;
		--without-spamassassin) use_spamassassin=no ;;
		--certbot-authenticator)
			[ "$#" -ge 2 ] || { usage >&2; printf '%s\n' 'Missing value for --certbot-authenticator.' >&2; exit 1; }
			certbot_authenticator=$2
			shift
			;;
		--acme-dns-client)
			[ "$#" -ge 2 ] || { usage >&2; printf '%s\n' 'Missing value for --acme-dns-client.' >&2; exit 1; }
			acme_dns_client=$2
			acme_dns_client_explicit=1
			shift
			;;
		--cloudflare-credentials)
			[ "$#" -ge 2 ] || { usage >&2; printf '%s\n' 'Missing value for --cloudflare-credentials.' >&2; exit 1; }
			cloudflare_credentials=$2
			shift
			;;
		-h|--help) usage; exit 0 ;;
		*) usage >&2; printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
	esac
	shift
done

case "$certbot_authenticator" in
	http-01)
		[ "$acme_dns_client_explicit" -eq 0 ] || { printf '%s\n' '--acme-dns-client requires dns-acme.' >&2; exit 1; }
		[ -z "$cloudflare_credentials" ] || { printf '%s\n' '--cloudflare-credentials requires dns-cloudflare.' >&2; exit 1; }
		;;
	dns-acme)
		[ -z "$cloudflare_credentials" ] || { printf '%s\n' '--cloudflare-credentials cannot be combined with dns-acme.' >&2; exit 1; }
		;;
	dns-cloudflare)
		[ "$acme_dns_client_explicit" -eq 0 ] || { printf '%s\n' '--acme-dns-client cannot be combined with dns-cloudflare.' >&2; exit 1; }
		[ -n "$cloudflare_credentials" ] || { printf '%s\n' 'dns-cloudflare requires --cloudflare-credentials FILE.' >&2; exit 1; }
		;;
	*) printf 'Unknown Certbot authenticator: %s\n' "$certbot_authenticator" >&2; exit 1 ;;
esac

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
[ -f "$script_dir/emailwizctl" ] || {
	echo "emailwizctl was not found next to emailwiz.sh. Clone the repository and run emailwiz.sh from that checkout."
	exit 1
}
[ -f "$script_dir/lib/certbot.sh" ] || {
	echo "lib/certbot.sh was not found next to emailwiz.sh. Clone the complete repository before installing."
	exit 1
}
# shellcheck source=lib/certbot.sh
. "$script_dir/lib/certbot.sh"

case "$certbot_authenticator" in
	dns-acme) emailwiz_certbot_validate_acme_dns_client "$acme_dns_client" ;;
	dns-cloudflare) emailwiz_certbot_validate_cloudflare_credentials "$cloudflare_credentials" ;;
esac

install_packages="postfix postfix-sqlite dovecot-imapd dovecot-pop3d dovecot-lmtpd dovecot-sieve dovecot-sqlite sqlite3 opendkim opendkim-tools net-tools fail2ban bind9-host"
if [ "$use_spamassassin" = yes ]; then
	install_packages="$install_packages spamassassin spamc"
fi

systemctl -q stop dovecot
systemctl -q stop postfix
# Package names intentionally expand as separate arguments.
# shellcheck disable=SC2086
apt-get purge '?config-files' -y $install_packages
# Package names intentionally expand as separate arguments.
# shellcheck disable=SC2086
apt-get install -y $install_packages

install -m 0755 "$script_dir/emailwizctl" /usr/local/sbin/emailwizctl

domain="$(cat /etc/mailname)"
subdom=mail
maildomain="$subdom.$domain"

allow_suboptimal_ciphers="yes" #yes no

# Fail early on unsupported Ubuntu/Dovecot versions and initialize the virtual
# domain database before changing service configuration.
emailwizctl system init --spamassassin "$use_spamassassin"

# The canonical hostname needs a public address for mail clients, MX delivery,
# SMTP identity and PTR/rDNS consistency, independently of ACME challenge type.
ipv4=$(host "$maildomain" 2>/dev/null | awk '/ has address / { print $NF; exit }')
ipv6=$(host "$maildomain" 2>/dev/null | awk '/ has IPv6 address / { print $NF; exit }')
[ -n "$ipv4$ipv6" ] || {
	printf '\033[0;31mPlease point %s to your server with an A and/or AAAA record.\033[0m\n' "$maildomain"
	exit 1
}

# Open required mail ports. TCP/80 is deliberately left to the administrator;
# the HTTP-01 flow prints the firewall prerequisite without changing it.
for port in 993 465 25 587 110 995; do
	ufw allow "$port" 2>/dev/null
done

certdir=$(emailwiz_certbot_run "$maildomain" "$certbot_authenticator" \
	"$acme_dns_client" "$cloudflare_credentials")

[ ! -f "$certdir/fullchain.pem" ] && echo "Error locating or installing SSL certificate." && exit 1
[ ! -f "$certdir/privkey.pem" ] && echo "Error locating or installing SSL certificate." && exit 1
[ ! -f "$certdir/cert.pem" ] && echo "Error locating or installing SSL certificate." && exit 1

[ ! -d "$certdir" ] && echo "Error locating or installing SSL certificate." && exit 1

# TLS identity belongs to the mail system, not to an individual hosted domain.
emailwizctl system tls "$maildomain" --cert-dir "$certdir" \
	--authenticator "$certbot_authenticator" --no-reload
emailwizctl domain add "$domain" --no-reload

echo "Configuring Postfix's main.cf..."

# Adding additional vars to fix an issue with receiving emails (relay access denied) and adding it to mydestination.
postconf -e "myhostname = $maildomain"
postconf -e "mail_name = $domain"  #This is for the smtpd_banner
postconf -e "mydomain = $domain"
# These variables are expanded by Postfix, not by this shell.
# shellcheck disable=SC2016
postconf -e 'mydestination = $myhostname, mail, localhost.localdomain, localhost, localhost.$mydomain'

# Change the cert/key files to the default locations of the Let's Encrypt cert/key
postconf -e "smtpd_tls_key_file=$certdir/privkey.pem"
postconf -e "smtpd_tls_cert_file=$certdir/fullchain.pem"
postconf -e "smtp_tls_CAfile=$certdir/cert.pem"

# Enable, but do not require TLS. Requiring it with other servers would cause
# mail delivery problems and requiring it locally would cause many other
# issues.
postconf -e 'smtpd_tls_security_level = may'
postconf -e 'smtp_tls_security_level = may'

# TLS required for authentication.
postconf -e 'smtpd_tls_auth_only = yes'

# Exclude insecure and obsolete encryption protocols.
postconf -e 'smtpd_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1'
postconf -e 'smtp_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1'
postconf -e 'smtpd_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1'
postconf -e 'smtp_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1'

# Exclude suboptimal ciphers.
if [ "$allow_suboptimal_ciphers" = "no" ]; then
	postconf -e 'tls_preempt_cipherlist = yes'
	postconf -e 'smtpd_tls_exclude_ciphers = aNULL, LOW, EXP, MEDIUM, ADH, AECDH, MD5, DSS, ECDSA, CAMELLIA128, 3DES, CAMELLIA256, RSA+AES, eNULL'
fi

# Here we tell Postfix to look to Dovecot for authenticating users/passwords.
# Dovecot will be putting an authentication socket in /var/spool/postfix/private/auth
postconf -e 'smtpd_sasl_auth_enable = yes'
postconf -e 'smtpd_sasl_type = dovecot'
postconf -e 'smtpd_sasl_path = private/auth'

# helo, sender, relay and recipient restrictions
postconf -e 'smtpd_sender_login_maps = proxy:sqlite:/etc/postfix/emailwiz-sender-logins.cf'
postconf -e 'smtpd_sender_restrictions = reject_sender_login_mismatch, permit_sasl_authenticated, permit_mynetworks, reject_unknown_reverse_client_hostname, reject_unknown_sender_domain'
postconf -e 'smtpd_recipient_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_unauth_destination, reject_unknown_recipient_domain'
postconf -e 'smtpd_relay_restrictions = permit_sasl_authenticated, reject_unauth_destination'
postconf -e 'smtpd_helo_required = yes'
postconf -e 'smtpd_helo_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_invalid_helo_hostname, reject_non_fqdn_helo_hostname, reject_unknown_helo_hostname'

# Hosted domains and recipient existence are resolved from SQLite. Dovecot LMTP
# performs final delivery using each virtual user's database-mapped UID/GID.
postconf -e 'virtual_mailbox_domains = proxy:sqlite:/etc/postfix/emailwiz-virtual-domains.cf'
postconf -e 'virtual_mailbox_maps = proxy:sqlite:/etc/postfix/emailwiz-virtual-mailboxes.cf'
postconf -e 'virtual_transport = lmtp:unix:private/dovecot-lmtp'
postconf -e 'mailbox_command ='

# Prevent "Received From:" header in sent emails in order to prevent leakage of public ip addresses
postconf -e "header_checks = regexp:/etc/postfix/header_checks"

# strips "Received From:" in sent emails
echo "/^Received:.*/     IGNORE
/^X-Originating-IP:/    IGNORE" >> /etc/postfix/header_checks

# master.cf
echo "Configuring Postfix's master.cf..."

sed -i '/^\s*-o/d;/^\s*submission/d;/^\s*smtp/d;/^\s*spamassassin[[:space:]]/d;/^\s*user=debian-spamd[[:space:]]/d' /etc/postfix/master.cf

echo "smtp unix - - n - - smtp
smtp inet n - y - - smtpd" >> /etc/postfix/master.cf

if [ "$use_spamassassin" = yes ]; then
	echo "  -o content_filter=spamassassin" >> /etc/postfix/master.cf
fi

echo "
submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_tls_auth_only=yes
  -o smtpd_tls_wrappermode=no
  -o smtpd_enforce_tls=yes
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o smtpd_sender_restrictions=reject_sender_login_mismatch
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject_unauth_destination
smtps     inet  n       -       y       -       -       smtpd
  -o syslog_name=postfix/smtps
  -o smtpd_tls_wrappermode=yes
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
  -o smtpd_recipient_restrictions=permit_mynetworks,permit_sasl_authenticated,reject" >> /etc/postfix/master.cf

if [ "$use_spamassassin" = yes ]; then
	echo "spamassassin unix -     n       n       -       -       pipe
  user=debian-spamd argv=/usr/bin/spamc -f -e /usr/sbin/sendmail -oi -f \${sender} \${recipient}" >> /etc/postfix/master.cf
fi

echo "Dovecot $(dovecot --version) configuration was generated by emailwizctl."

# OpenDKIM

# A lot of the big name email services, like Google, will automatically reject
# as spam unfamiliar and unauthenticated email addresses. As in, the server
# will flatly reject the email, not even delivering it to someone's Spam
# folder.

# OpenDKIM is a way to authenticate your email so you can send to such services
# without a problem.

# emailwizctl generated the domain key and rebuilt these tables from SQLite.
echo 'Configuring OpenDKIM...'
grep -q '127.0.0.1' /etc/postfix/dkim/trustedhosts 2>/dev/null ||
	echo '127.0.0.1
10.1.0.0/16' >> /etc/postfix/dkim/trustedhosts

# ...and source it from opendkim.conf
grep -q '^KeyTable' /etc/opendkim.conf 2>/dev/null || echo 'KeyTable file:/etc/postfix/dkim/keytable
SigningTable refile:/etc/postfix/dkim/signingtable
InternalHosts refile:/etc/postfix/dkim/trustedhosts' >> /etc/opendkim.conf

sed -i '/^#Canonicalization/s/simple/relaxed\/simple/' /etc/opendkim.conf
sed -i '/^#Canonicalization/s/^#//' /etc/opendkim.conf

sed -i '/Socket/s/^#*/#/' /etc/opendkim.conf
grep -q '^Socket\s*inet:12301@localhost' /etc/opendkim.conf || echo 'Socket inet:12301@localhost' >> /etc/opendkim.conf

# OpenDKIM daemon settings, removing previously activated socket.
sed -i '/^SOCKET/d' /etc/default/opendkim && echo "SOCKET=\"inet:12301@localhost\"" >> /etc/default/opendkim

# Here we add to postconf the needed settings for working with OpenDKIM
echo 'Configuring Postfix with OpenDKIM settings...'
postconf -e 'smtpd_sasl_security_options = noanonymous, noplaintext'
postconf -e 'smtpd_sasl_tls_security_options = noanonymous'
postconf -e "myhostname = $maildomain"
postconf -e 'milter_default_action = accept'
postconf -e 'milter_protocol = 6'
postconf -e 'smtpd_milters = inet:localhost:12301'
postconf -e 'non_smtpd_milters = inet:localhost:12301'
postconf -e 'mailbox_command ='

# Long-term fix to prevent SMTP smuggling
postconf -e 'smtpd_forbid_bare_newline = normalize'
# This variable is expanded by Postfix, not by this shell.
# shellcheck disable=SC2016
postconf -e 'smtpd_forbid_bare_newline_exclusions = $mynetworks'

# A fix for "Opendkim won't start: can't open PID file?", as specified here: https://serverfault.com/a/847442
/lib/opendkim/opendkim.service.generate
systemctl daemon-reload

# Enable fail2ban security for dovecot and postfix.
[ ! -f /etc/fail2ban/jail.d/emailwiz.local ] && echo "[postfix]
enabled = true
[postfix-sasl]
enabled = true
[sieve]
enabled = true
[dovecot]
enabled = true" > /etc/fail2ban/jail.d/emailwiz.local

sed -i "s|^backend = auto$|backend = systemd|" /etc/fail2ban/jail.conf

# Enable SpamAssassin and its update cronjob only when requested.
if [ "$use_spamassassin" = yes ]; then
	if [ -f /etc/default/spamassassin ]; then
		sed -i "s|^CRON=0|CRON=1|" /etc/default/spamassassin
		printf "Restarting spamassassin..."
		service spamassassin restart && printf " ...done\\n"
		systemctl enable spamassassin
	elif [ -f /etc/default/spamd ]; then
		sed -i "s|^CRON=0|CRON=1|" /etc/default/spamd
		printf "Restarting spamd..."
		service spamd restart && printf " ...done\\n"
		systemctl enable spamd
	else
		printf "!!! Neither /etc/default/spamassassin nor /etc/default/spamd exists; SpamAssassin setup cannot continue.\\n" >&2
		exit 1
	fi
else
	printf "SpamAssassin was not requested; inbound mail will bypass local spam classification.\\n"
fi

# Re-render after all Postfix/OpenDKIM settings are present and validate the
# Dovecot syntax selected for the installed 2.3 or 2.4 release.
emailwizctl system render --no-reload

for x in opendkim dovecot postfix fail2ban; do
	printf "Restarting %s..." "$x"
	service "$x" restart && printf " ...done\\n"
	systemctl enable "$x"
done

dns_records=$(cat "/var/lib/emailwiz/dns/$domain.txt")
cp "/var/lib/emailwiz/dns/$domain.txt" "$HOME/dns_emailwizard"

printf '%b' "\033[31m
 _   _
| \ | | _____      ___
|  \| |/ _ \ \ /\ / (_)
| |\  | (_) \ V  V / _
|_| \_|\___/ \_/\_/ (_)\033[0m

Add these records on either your registrar's site or your DNS server:
\033[32m
$dns_records
\033[0m
NOTE: You may need to omit the \`.$domain\` portion at the beginning if
inputting them in a registrar's web interface.

Also, these are now saved to \033[34m~/dns_emailwizard\033[0m in case you want them in a file.

Once you do that, create at least one virtual mailbox with emailwizctl. Check the README for how to add users/accounts
and how to log in.\n"
