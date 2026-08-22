#!/bin/sh

lookup_home_identity() {
	home=$1
	entries=$(getent passwd | awk -F: -v wanted="$home" '$6 == wanted { print $1 ":" $3 ":" $4 }')
	count=$(printf '%s\n' "$entries" | awk 'NF { count++ } END { print count + 0 }')
	[ "$count" -eq 1 ] || die "home_path must exactly match one existing Unix user's home directory: $home"
	printf '%s\n' "$entries"
}

validate_home_path() {
	home=$1
	case "$home" in "$HOME_ROOT"/*) ;; *) die "home_path must be an existing path below $HOME_ROOT: $home" ;; esac
	case "$home" in *[!a-zA-Z0-9_./-]*) die "home_path contains unsupported characters: $home" ;; esac
	[ -d "$home" ] || die "Unix home directory does not exist: $home"
	[ ! -L "$home" ] || die "Symlinked Unix home directories are not supported: $home"
	resolved_home=$(readlink -f "$home")
	[ "$resolved_home" = "$home" ] || die "home_path must be canonical and cannot contain symlink or '..' components: $home"
	identity=$(lookup_home_identity "$home")
	unix_user=${identity%%:*}
	rest=${identity#*:}
	uid=${rest%%:*}
	gid=${rest#*:}
	owner_uid=$(stat -c %u "$home")
	[ "$owner_uid" = "$uid" ] || die "Unix home $home is owned by UID $owner_uid, but /etc/passwd maps it to UID $uid."
}

prepare_mail_home() {
	home=$1
	uid=$2
	gid=$3
	mail_dir="$home/Mail"
	if [ -L "$mail_dir" ]; then
		die "Symlinked Mail directories are not supported: $mail_dir"
	elif [ -e "$mail_dir" ] && [ ! -d "$mail_dir" ]; then
		die "Mail path exists but is not a directory: $mail_dir"
	elif [ -d "$mail_dir" ]; then
		if [ -n "$(find "$mail_dir" -mindepth 1 -print -quit)" ]; then
			die "Mail directory is not empty; existing data was not touched: $mail_dir"
		fi
		warn "Reusing existing empty Mail directory: $mail_dir"
	else
		mkdir -m 0700 "$mail_dir"
	fi
	chown "$uid:$gid" "$mail_dir"
}

read_password() {
	from_stdin=$1
	if [ "$from_stdin" -eq 1 ]; then
		IFS= read -r password || die "Could not read password from stdin."
	else
		[ -t 0 ] || die "No terminal is available. Use --password-stdin."
		saved_stty=$(stty -g)
		trap 'stty "$saved_stty"' 0
		trap 'stty "$saved_stty"; exit 130' 1 2 15
		printf 'Password: ' >&2
		stty -echo
		if ! IFS= read -r password; then
			stty "$saved_stty"
			trap - 0 1 2 15
			die "Could not read password."
		fi
		stty echo
		printf '\nConfirm password: ' >&2
		stty -echo
		if ! IFS= read -r confirmation; then
			stty "$saved_stty"
			trap - 0 1 2 15
			die "Could not read password confirmation."
		fi
		stty "$saved_stty"
		trap - 0 1 2 15
		printf '\n' >&2
		[ "$password" = "$confirmation" ] || die "Passwords do not match."
	fi
	[ -n "$password" ] || die "Password cannot be empty."
	password_hash=$(printf '%s\n%s\n' "$password" "$password" | doveadm pw -s "$PASSWORD_SCHEME" 2>/dev/null | tail -n1)
	case "$password_hash" in
		\{*\}*) ;;
		*) die "Dovecot did not return a valid password hash." ;;
	esac
	password=''
	confirmation=''
}

safe_purge_mail_dir() {
	home=$1
	validate_home_path "$home"
	mail_dir="$home/Mail"
	[ -e "$mail_dir" ] || return 0
	[ -d "$mail_dir" ] || die "Expected Mail directory is not a directory: $mail_dir"
	[ ! -L "$mail_dir" ] || die "Refusing to purge symlinked Mail directory: $mail_dir"
	resolved_home=$(readlink -f "$home")
	resolved_mail=$(readlink -f "$mail_dir")
	[ "$resolved_mail" = "$resolved_home/Mail" ] || die "Refusing to purge unexpected Mail path: $resolved_mail"
	find -P "$mail_dir" -xdev -depth -delete
}
