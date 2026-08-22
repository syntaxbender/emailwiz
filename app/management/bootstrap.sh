#!/bin/sh

# Runtime configuration for the management application.

PROGRAM=${0##*/}
STATE_DIR=${EMAILWIZ_STATE_DIR:-/var/lib/emailwiz}
DB_PATH=${EMAILWIZ_DB_PATH:-$STATE_DIR/emailwiz.sqlite3}
DNS_DIR=${EMAILWIZ_DNS_DIR:-$STATE_DIR/dns}
DOVECOT_CONF=${EMAILWIZ_DOVECOT_CONF:-/etc/dovecot/dovecot.conf}
DOVECOT_SQL_CONF=${EMAILWIZ_DOVECOT_SQL_CONF:-/etc/dovecot/emailwiz-sql.conf.ext}
POSTFIX_DIR=${EMAILWIZ_POSTFIX_DIR:-/etc/postfix}
OPENDKIM_KEYTABLE=${EMAILWIZ_OPENDKIM_KEYTABLE:-$POSTFIX_DIR/dkim/keytable}
OPENDKIM_SIGNINGTABLE=${EMAILWIZ_OPENDKIM_SIGNINGTABLE:-$POSTFIX_DIR/dkim/signingtable}
DKIM_ROOT=${EMAILWIZ_DKIM_ROOT:-$POSTFIX_DIR/dkim}
SIEVE_DIR=${EMAILWIZ_SIEVE_DIR:-/var/lib/dovecot/sieve}
HOME_ROOT=${EMAILWIZ_HOME_ROOT:-/home}
RENEW_HOOK=${EMAILWIZ_RENEW_HOOK:-/etc/letsencrypt/renewal-hooks/deploy/emailwiz}
OS_RELEASE_FILE=${EMAILWIZ_OS_RELEASE_FILE:-/etc/os-release}
SQLITE3=${SQLITE3:-sqlite3}
PASSWORD_SCHEME=SHA512-CRYPT

# EMAILWIZ_APP_DIR is resolved by the entrypoint before this file is sourced.
# shellcheck source=../helpers/common.sh
. "$EMAILWIZ_APP_DIR/helpers/common.sh"
# shellcheck source=../helpers/database.sh
. "$EMAILWIZ_APP_DIR/helpers/database.sh"
# shellcheck source=../helpers/validation.sh
. "$EMAILWIZ_APP_DIR/helpers/validation.sh"
