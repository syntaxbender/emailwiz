#!/bin/sh

# Application composition root: load feature modules once, then dispatch CLI.

# shellcheck source=bootstrap.sh
. "$EMAILWIZ_APP_DIR/management/bootstrap.sh"
# shellcheck source=system/init.sh
. "$EMAILWIZ_APP_DIR/management/system/init.sh"
# shellcheck source=system/render.sh
. "$EMAILWIZ_APP_DIR/management/system/render.sh"
# shellcheck source=system/tls.sh
. "$EMAILWIZ_APP_DIR/management/system/tls.sh"
# shellcheck source=system/version.sh
. "$EMAILWIZ_APP_DIR/management/system/version.sh"
# shellcheck source=domain/common.sh
. "$EMAILWIZ_APP_DIR/management/domain/common.sh"
# shellcheck source=domain/add.sh
. "$EMAILWIZ_APP_DIR/management/domain/add.sh"
# shellcheck source=domain/list.sh
. "$EMAILWIZ_APP_DIR/management/domain/list.sh"
# shellcheck source=domain/delete.sh
. "$EMAILWIZ_APP_DIR/management/domain/delete.sh"
# shellcheck source=domain/enable.sh
. "$EMAILWIZ_APP_DIR/management/domain/enable.sh"
# shellcheck source=user/common.sh
. "$EMAILWIZ_APP_DIR/management/user/common.sh"
# shellcheck source=user/add.sh
. "$EMAILWIZ_APP_DIR/management/user/add.sh"
# shellcheck source=user/list.sh
. "$EMAILWIZ_APP_DIR/management/user/list.sh"
# shellcheck source=user/passwd.sh
. "$EMAILWIZ_APP_DIR/management/user/passwd.sh"
# shellcheck source=user/delete.sh
. "$EMAILWIZ_APP_DIR/management/user/delete.sh"
# shellcheck source=user/enable.sh
. "$EMAILWIZ_APP_DIR/management/user/enable.sh"

emailwiz_management_usage() {
	cat <<'EOF'
Usage:
  emailwizctl system init [--spamassassin yes|no]
  emailwizctl system tls HOSTNAME --cert-dir DIR [--authenticator METHOD] [--no-reload]
  emailwizctl system render [--no-reload]
  emailwizctl system version

  emailwizctl domain add DOMAIN [--no-reload]
  emailwizctl domain list [--all]
  emailwizctl domain delete DOMAIN [--purge] [--no-reload]
  emailwizctl domain enable DOMAIN [--no-reload]

  emailwizctl user add ADDRESS --home /home/USER [--password-stdin]
  emailwizctl user list [--domain DOMAIN] [--all]
  emailwizctl user passwd ADDRESS [--password-stdin]
  emailwizctl user delete ADDRESS [--purge]
  emailwizctl user enable ADDRESS

Passwords are prompted for by default. Use --password-stdin for automation.
All domains use the system's canonical mail hostname and TLS certificate.
Each domain receives its own DKIM key.
EOF
}

emailwiz_management_main() {
	[ "$#" -gt 0 ] || { emailwiz_management_usage; exit 1; }
	group=$1
	shift
	case "$group" in
		system)
			[ "$#" -gt 0 ] || die "system requires a subcommand."
			command_name=$1
			shift
			case "$command_name" in
				init) system_init "$@" ;;
				tls) system_tls "$@" ;;
				render) system_render "$@" ;;
				version) [ "$#" -eq 0 ] || die "system version takes no arguments."; system_version ;;
				*) die "Unknown system subcommand: $command_name" ;;
			esac
			;;
		domain)
			[ "$#" -gt 0 ] || die "domain requires a subcommand."
			command_name=$1
			shift
			case "$command_name" in
				add) domain_add "$@" ;;
				list) domain_list "$@" ;;
				delete) domain_delete "$@" ;;
				enable) domain_enable "$@" ;;
				*) die "Unknown domain subcommand: $command_name" ;;
			esac
			;;
		user)
			[ "$#" -gt 0 ] || die "user requires a subcommand."
			command_name=$1
			shift
			case "$command_name" in
				add) user_add "$@" ;;
				list) user_list "$@" ;;
				passwd) user_passwd "$@" ;;
				delete) user_delete "$@" ;;
				enable) user_enable "$@" ;;
				*) die "Unknown user subcommand: $command_name" ;;
			esac
			;;
		-h|--help|help) emailwiz_management_usage ;;
		*) die "Unknown command group: $group" ;;
	esac
}
