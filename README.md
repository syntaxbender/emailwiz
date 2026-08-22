# Emailwiz

Emailwiz installs a small multi-domain mail server on Ubuntu. Postfix remains
the SMTP server, Dovecot provides IMAP/POP3, authentication and LMTP delivery,
and SQLite stores virtual domains and mailbox identities.

## Installed inventory

| Component | Purpose |
| --- | --- |
| Postfix + `postfix-sqlite` | SMTP, recipient checks, authenticated submission and SQLite lookup maps |
| Dovecot IMAP/POP3/LMTP + `dovecot-sqlite` | Client access, SQLite password authentication and delivery as the mapped Unix UID/GID |
| SQLite | Virtual domain, mailbox, password-hash and home-path database |
| OpenDKIM | A separate DKIM key and signing rule for every hosted domain |
| Certbot | One Let's Encrypt certificate for the canonical mail hostname; HTTP-01, acme-dns and Cloudflare DNS-01 are supported |
| SpamAssassin (optional) | Inbound spam classification when explicitly enabled during installation |
| Pigeonhole Sieve | User filtering; moves SpamAssassin-marked messages into `Junk` when that option is enabled |
| Fail2ban | Postfix and Dovecot login protection |

Postfix is not replaced by SQLite. SQLite replaces the old PAM/Unix-account
mailbox database and supplies Postfix's virtual lookup tables.

## Supported Ubuntu and Dovecot versions

The installer requires Ubuntu 22.04 or newer and detects the installed version
with `dovecot --version`. It generates independent configurations for the 2.3
and 2.4 syntax families.

| Ubuntu release | Ubuntu package family | Generated configuration |
| --- | --- | --- |
| 22.04 LTS | Dovecot 2.3.16 | Dovecot 2.3 syntax and external SQLite config |
| 24.04 LTS | Dovecot 2.3.21 | Dovecot 2.3 syntax and external SQLite config |
| 25.10 | Dovecot 2.4.1 | Dovecot 2.4 syntax with version headers and inline SQLite settings |
| 26.04 LTS | Dovecot 2.4.2 | Dovecot 2.4 syntax with version headers and inline SQLite settings |

The package versions above follow the current [Ubuntu package
index](https://packages.ubuntu.com/en/dovecot-core). A PPA or backport is also
handled correctly because selection uses the Dovecot version, not the Ubuntu
codename. Versions outside the 2.3/2.4 families are rejected until a matching
configuration generator exists. Dovecot documents the incompatible 2.4 syntax
changes in its [2.3 to 2.4 upgrade
guide](https://doc.dovecot.org/2.4.2/installation/upgrade/2.3-to-2.4.html).

Run this after an operating-system upgrade to regenerate and validate the
configuration for the newly installed Dovecot version:

```sh
sudo emailwizctl system render
sudo emailwizctl system version
```

## Storage and identity model

Emailwiz separates public addresses, authentication credentials and physical
mailboxes. A mailbox stores one opaque internal Dovecot identity plus the home
path and UID/GID of one existing Unix user. Multiple public addresses may
resolve to it:

```text
alice@example.com + password --------+
support@example.net + password ------+-> one internal Dovecot user
info@example.net + no password -------+             |
                                                    +-> /home/mehmet/Mail
```

Mail stays in the original Emailwiz layout:

```text
/home/mehmet/Mail
/home/mehmet/Mail/Inbox
```

The Unix account must already exist. Emailwiz never creates it and never reads
or copies its `/etc/shadow` password. Public login addresses are authenticated
against their own SQLite password hash and then canonicalized to the mailbox's
single internal Dovecot user. Delivery-only aliases have a NULL password and
therefore cannot authenticate. Dovecot uses only the mailbox UID/GID to access
the files, so it never receives multiple mail users with the same home.

This follows Dovecot's rule that [different mail users must not share one
home](https://doc.dovecot.org/main/core/config/auth/users/virtual.html). The
documented [userdb `user`
result](https://doc.dovecot.org/2.4.0/core/config/auth/userdb.html) changes every
public login/delivery address to one canonical storage user only when mailbox
storage is opened. SMTP authentication retains the registered public address
so Postfix can enforce sender ownership. The behavior is integration-tested
against the official Dovecot 2.3 and 2.4 Docker images.

When a mailbox is created:

- `--unix-user` must name an existing Unix account whose `/etc/passwd` home is
  below `/home`.
- Emailwiz reads `home_path`, UID and GID from that account; the caller does not
  provide a filesystem path.
- A missing `Mail` directory is created and assigned to that Unix UID/GID.
- An existing empty `Mail` directory is reused with a warning.
- An existing non-empty, unmanaged `Mail` directory causes an error and is
  never changed.
- Existing mail is not migrated automatically.

`user add` creates a new physical mailbox and refuses to reuse an already
managed Unix home. Additional addresses must explicitly select an existing
target with `alias add --to`. A login alias has its own password but resolves to
the target's internal storage user. A delivery-only alias has no password.
Purging an alias removes only its address row; physical mail is retained until
the final address using that mailbox is purged.

Email local parts follow consumer-Gmail-style dot canonicalization:

- New addresses accept only letters, digits and dots before `@`.
- Dots are ignored for uniqueness, login and inbound recipient lookup. If
  `ahmet.mehmet@example.com` is registered, `ah.metmehmet@example.com` resolves
  to it and cannot be registered separately.
- The originally registered spelling remains the managed public address;
  Dovecot uses a separate opaque internal storage identity.
- `+tag` is accepted only for inbound delivery. It is not accepted when
  registering or logging in.
- Canonicalization never removes dots from the domain name.

## Application architecture

The public entrypoints are intentionally small and stable:

- `emailwiz.sh` starts the one-time installer application.
- `emailwizctl` starts the ongoing management application.

Implementation is grouped by responsibility rather than kept in either
entrypoint:

```text
app/
├── installer/                 package and service installation features
├── management/
│   ├── domain/                one module per domain lifecycle command
│   ├── user/                  one module per mail-user lifecycle command
│   ├── alias/                 delivery-only and independently authenticated aliases
│   └── system/                initialization, TLS, rendering and versioning
└── helpers/
    ├── common.sh              shared process helpers
    ├── database.sh            shared SQLite access
    ├── validation.sh          shared input/platform validation
    └── installer/certbot/     HTTP-01, acme-dns and Cloudflare adapters
```

The installer copies this tree to `/usr/local/lib/emailwiz` and installs only
the `emailwizctl` launcher in `/usr/local/sbin`. Commands run from a repository
checkout and commands run after installation therefore use the same modules.
The checkout launcher resolves its adjacent `app` tree, while the installed
launcher resolves `../lib/emailwiz` from its own location. Production module,
state, database and configuration paths cannot be overridden through process
environment variables; those overrides are limited to the development/test
runtime.

## Installation

The installer now needs `emailwizctl`, so clone the repository instead of
downloading only `emailwiz.sh`:

```sh
git clone https://github.com/syntaxbender/emailwiz.git
cd emailwiz
sudo sh emailwiz.sh
```

Let's Encrypt HTTP-01 is the default authenticator. Emailwiz detects the
process actively listening on TCP/80 and selects the Nginx or Apache Certbot
plugin accordingly. If TCP/80 is unused, it selects Certbot standalone. An
unknown listener causes an error instead of an unsafe standalone attempt.

Emailwiz does not add or remove the TCP/80 UFW rule. In HTTP-01 mode it prints
a reminder that TCP/80 must be reachable through UFW and any hosting-provider
firewall. DNS-01 modes do not require TCP/80.

SpamAssassin is disabled by default. Enable it explicitly if this server should
classify inbound port 25 mail locally:

```sh
sudo sh emailwiz.sh --with-spamassassin
```

Without that flag, the SpamAssassin packages, Postfix content filter and global
`X-Spam-Flag` to `Junk` Sieve rule are omitted. `--without-spamassassin` is also
accepted when automation should state the default choice explicitly.

Before installation:

1. Set `/etc/mailname` to the initial bare domain, such as `example.com`.
2. Point `mail.example.com` to the server with an A and/or AAAA record.
3. Ensure ports 25, 110, 465, 587, 993 and 995 are allowed by the hosting provider.
4. For HTTP-01 only, also allow inbound TCP/80 in UFW and the provider firewall.
5. Configure PTR/rDNS for the server's primary mail hostname.

The installer initializes SQLite, obtains one TLS certificate for the canonical
mail hostname, adds the initial domain, generates its DKIM key and prints the
required MX/SPF/DKIM/DMARC records. DNS output is retained under
`/var/lib/emailwiz/dns/`.

Self-signed certificate generation is not supported. The installer uses Let's
Encrypt by default. An externally managed certificate can still be attached
later with `emailwizctl system tls`.

### acme-dns DNS-01

Install `acme-dns-client`, register only the canonical hostname and create the
CNAME it requests before running Emailwiz:

```sh
sudo acme-dns-client register \
  -d mail.example.com \
  -s https://auth.acme-dns.example

sudo acme-dns-client check -d mail.example.com

sudo sh emailwiz.sh \
  --certbot-authenticator dns-acme \
  --acme-dns-client /usr/local/bin/acme-dns-client
```

The client must be an absolute, root-owned executable that is not writable by
group or other users. `_acme-challenge.mail.example.com` must publicly resolve
as the CNAME created during registration. The Certbot renewal lineage retains
the absolute authentication-hook path.

### Cloudflare DNS-01

Use a Cloudflare API token restricted to `Zone:DNS:Edit` for the relevant DNS
zone. Store it outside the repository:

```ini
# /etc/letsencrypt/credentials/cloudflare.ini
dns_cloudflare_api_token = REPLACE_WITH_TOKEN
```

Protect and pass that file to the installer:

```sh
sudo chmod 0600 /etc/letsencrypt/credentials/cloudflare.ini

sudo sh emailwiz.sh \
  --certbot-authenticator dns-cloudflare \
  --cloudflare-credentials /etc/letsencrypt/credentials/cloudflare.ini
```

The installer adds the matching Certbot Cloudflare plugin, verifies that the
credentials file is root-owned with mode `0600`, and never places the token in
command arguments, logs or SQLite. Certbot stores only the credentials-file
path in its renewal configuration. See the official
[`certbot-dns-cloudflare` documentation](https://certbot-dns-cloudflare.readthedocs.io/en/stable/).

The old standalone `adddomain.sh` command remains as a compatibility wrapper
for `emailwizctl domain add`.

## Domain management

All hosted domains use the canonical hostname selected during installation,
such as `mail.example.com`, for MX and client connections. Only that hostname
needs an A/AAAA record and TLS certificate. Every hosted domain still receives
its own DKIM key, SPF record and DMARC record.

```sh
sudo emailwizctl domain add example.net
sudo emailwizctl domain list
sudo emailwizctl domain list --all
```

To replace or externally manage the system certificate, configure it at the
system level and then render the services. The certificate must cover the
canonical hostname and its directory must contain `fullchain.pem` and
`privkey.pem`:

```sh
sudo emailwizctl system tls mail.example.com \
  --cert-dir /etc/custom-certs/mail.example.com
```

Domain deletion is soft by default. It disables reception/login while keeping
the DKIM key and every mailbox record:

```sh
sudo emailwizctl domain delete example.net
sudo emailwizctl domain enable example.net
```

Permanent deletion requires all users under the domain to be purged first:

```sh
sudo emailwizctl domain delete example.net --purge
```

`--purge` removes the database domain and its DKIM material. The canonical
system certificate is never owned by an individual domain and is therefore
never removed by domain deletion.

## Mail-user management

Create the Unix account yourself, then map the virtual mailbox to its home:

```sh
sudo useradd -m mehmet
sudo emailwizctl user add alice@example.com --unix-user mehmet
```

Add a delivery-only alias to the same mailbox:

```sh
sudo emailwizctl alias add info@example.net --to alice@example.com
```

It receives mail in `/home/mehmet/Mail` but cannot log in or send as
`info@example.net`.

Add an independently authenticated alias by passing the boolean `--passwd`
option:

```sh
sudo emailwizctl alias add support@example.net --to alice@example.com --passwd
```

`--passwd` never takes the password as an argument. It opens the same hidden,
confirmed terminal prompt used by `user add`, so the password is not written to
shell history. For automation, provide exactly one line on standard input:

```sh
printf '%s\n' "$ALIAS_PASSWORD" |
  sudo emailwizctl alias add support@example.net --to alice@example.com \
    --password-stdin
```

The login alias has its own password and sending identity, but resolves to the
same internal Dovecot user and reads/writes the same physical Maildir.
Running `emailwizctl user passwd ADDRESS` on a delivery-only alias assigns a
password and promotes it to a login alias.

The password is prompted for without echoing. Automation can supply exactly
one line on standard input:

```sh
printf '%s\n' "$MAIL_PASSWORD" |
  sudo emailwizctl user add alice@example.com --unix-user mehmet --password-stdin
```

Other management commands:

```sh
sudo emailwizctl user list
sudo emailwizctl user list --domain example.com --all
sudo emailwizctl user passwd alice@example.com
sudo emailwizctl user delete alice@example.com
sudo emailwizctl user enable alice@example.com
sudo emailwizctl user delete alice@example.com --purge
```

Soft deletion only disables authentication and delivery. User purge deletes
the database identity and, for the final identity mapped to that home, exactly
`<home_path>/Mail`; it retains the Unix account and every other file in the
home directory. Symlinked or unexpected paths are rejected.

## Address behavior cases

### Registration

| Case | Result |
| --- | --- |
| `user add mehmet@example.com --unix-user mehmet` | Creates one mailbox and prompts for its first login password |
| A second `user add` with `--unix-user mehmet` | Rejected; additional addresses must use `alias add --to` |
| `alias add info@example.com --to mehmet@example.com` | Creates a delivery-only alias with no password |
| `alias add ahmet@example.com --to mehmet@example.com --passwd` | Prompts for an independent password and creates a login alias |
| `ahmet.mehmet@example.com` exists, then `ah.metmehmet@example.com` is added | Rejected as a canonical dotted-address collision |
| `ahmet@example.com` and `ahmet@example.net` | Allowed because domains are independent |
| A new local part containing `_`, `-`, `%` or `+` | Rejected |

### Login

| Login attempt | Result |
| --- | --- |
| Registered address plus its own password | Accepted and mapped to the mailbox's internal Dovecot user |
| A dotted spelling such as `ah.metmehmet@example.com` plus the registered identity's password | Accepted after dot canonicalization |
| Login alias plus the target user's password | Rejected; every login address has an independent password |
| Delivery-only alias such as `info@example.com` | Rejected because its password hash is NULL |
| `ahmet.mehmet+shop@example.com` | Rejected because `+tag` is delivery-only |
| Wrong password, disabled address or disabled domain | Rejected |

### Inbound delivery

| Recipient | Result |
| --- | --- |
| Exact registered address | Delivered to the mapped mailbox |
| Dotted variant such as `ah.metmehmet@example.com` | Delivered to the same mailbox after dot canonicalization |
| `ahmet.mehmet+shop@example.com` | Delivered to the same mailbox after removing `+shop` |
| Dotted plus tagged address | Tag removal and dot canonicalization resolve the same mailbox |
| Delivery-only or login alias | Delivered to the target mailbox |
| Unknown canonical address, disabled address or disabled domain | Rejected during SMTP recipient validation |

All login addresses mapped to one mailbox intentionally share its messages,
folders, read/deleted state, Sieve rules and quota. They differ only in public
address, authentication password and permitted SMTP sender identity.

## Client settings

For `alice@example.net` use the full email address as the username and the
server's canonical hostname (here `mail.example.com`) for both protocols:

| Setting | Value |
| --- | --- |
| Username | `alice@example.net` |
| SMTP server | `mail.example.com` |
| SMTP port | 465 (implicit TLS) or 587 (STARTTLS) |
| IMAP server | `mail.example.com` |
| IMAP port | 993 |

The same hostname should also be used for PTR/rDNS and Postfix's SMTP
identity. Hosted address domains remain independent in SQLite even though they
share this transport identity.

## Tests

The integration suite uses temporary paths and does not modify system mail
configuration:

```sh
tests/test_emailwizctl.sh
tests/test_certbot.sh

# Optional: also parse both configs with the official Dovecot Docker images.
EMAILWIZ_DOCKER_TEST=1 tests/test_emailwizctl.sh
```

The suites cover all three Certbot authenticators, HTTP listener selection,
credential safeguards, both generated Dovecot syntax families, SQLite
mappings, canonical TLS with multiple hosted domains, UID/GID home mapping,
soft deletion and guarded purge behavior.
