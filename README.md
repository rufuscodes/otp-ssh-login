# otp-login

Add two-factor authentication (TOTP) to SSH **and** GNOME (GDM) login on
Ubuntu / Debian.

Require a 6-digit code from an authenticator app (Google Authenticator, Authy,
1Password, Aegis, etc.) in addition to your normal credentials. SSH and GNOME
share one secret, so a single app entry unlocks both.

Tested on **Ubuntu 26.04 LTS / OpenSSH 9.x / GDM3**.

## What's included

| File | Purpose |
|------|---------|
| [`setup-ssh-otp.sh`](setup-ssh-otp.sh) | Install OpenSSH + Google Authenticator PAM, generate your TOTP secret, configure PAM + sshd |
| [`harden-ssh.sh`](harden-ssh.sh) | SSH hardening + fail2ban (run after the OTP script) |
| [`ssh-otp.md`](ssh-otp.md) | Full step-by-step tutorial, manual commands, and troubleshooting |
| [`setup-gnome-otp.sh`](setup-gnome-otp.sh) | Add the same TOTP factor to the GNOME (GDM) login screen |
| [`gnome-otp.md`](gnome-otp.md) | GNOME OTP tutorial, manual commands, and troubleshooting |

## Requirements

- Ubuntu / Debian with `sudo`
- An authenticator app on your phone

## Quick start

```bash
chmod +x setup-ssh-otp.sh harden-ssh.sh setup-gnome-otp.sh

./setup-ssh-otp.sh pass+otp   # scan the QR code when it appears
./harden-ssh.sh               # optional: hardening + fail2ban
./setup-gnome-otp.sh          # add the same factor to the GNOME login screen
```

> ⚠️ **Do not close your current SSH session until you've verified login in a
> second terminal.** Test the new login before disconnecting.

## Modes

`setup-ssh-otp.sh` accepts one argument:

| Mode | SSH asks for | Factors |
|------|--------------|---------|
| `pass+otp` (default) | password, then 6-digit code | 2 (know + have) |
| `key+otp` | SSH key, then 6-digit code | 2 (have + have) |
| `otp` | 6-digit code only | 1 (have) |

```bash
./setup-ssh-otp.sh pass+otp
./setup-ssh-otp.sh key+otp   # requires ~/.ssh/authorized_keys to be non-empty
./setup-ssh-otp.sh otp
```

The script **aborts safely** if you pick `key+otp` with an empty
`~/.ssh/authorized_keys`.

## What each script does

### `setup-ssh-otp.sh`

1. Installs `openssh-server` and `libpam-google-authenticator`
2. Backs up `/etc/pam.d/sshd` and `/etc/ssh/sshd_config`
3. Runs `google-authenticator` — **scan the QR code**, save the secret and
   emergency scratch codes
4. Configures PAM (`pam_google_authenticator.so`)
5. Writes `/etc/ssh/sshd_config.d/99-otp.conf`
6. Validates (`sshd -t`) and restarts `ssh`

### `harden-ssh.sh`

1. Writes `/etc/ssh/sshd_config.d/00-hardening.conf`:
   `PermitRootLogin no`, `MaxAuthTries 4`, `AllowUsers <you>`, `X11Forwarding no`,
   idle-session timeouts, and more
2. Installs and configures **fail2ban** with an `sshd` jail (systemd journal
   backend, with the Ubuntu `ssh.service` journalmatch fix)

## Verify

```bash
sudo sshd -T | grep -Ei 'kbdinteractiveauthentication|authenticationmethods'
sudo fail2ban-client status sshd
```

A working setup shows:

```
kbdinteractiveauthentication yes
authenticationmethods keyboard-interactive
```

## GNOME login OTP

After SSH OTP is working, add the same factor to the GDM login screen:

```bash
./setup-gnome-otp.sh          # every user must have a secret
./setup-gnome-otp.sh nullok   # only users WITH a secret are prompted
```

The script **reuses** your existing `~/.google_authenticator` (it will not
overwrite the secret SSH depends on). At the login screen you'll then be asked
for your password followed by the 6-digit code. See
[`gnome-otp.md`](gnome-otp.md) for the manual steps and troubleshooting.

## Locked out? Recover from the console

```bash
sudo mv /etc/ssh/sshd_config.d/99-otp.conf /etc/ssh/sshd_config.d/00-hardening.conf /tmp/
sudo systemctl restart ssh
```

This restores password-only login so you can fix the problem.

## Ubuntu gotcha (important)

Ubuntu ships `Include /etc/ssh/sshd_config.d/*.conf` at the **top** of
`/etc/ssh/sshd_config`, so main-config settings override drop-ins. If
`sshd -T` shows `kbdinteractiveauthentication no`, edit the main config:

```bash
sudo sed -i 's/^KbdInteractiveAuthentication no$/KbdInteractiveAuthentication yes/' /etc/ssh/sshd_config
sudo systemctl restart ssh
```

## Full walkthrough

See [`ssh-otp.md`](ssh-otp.md) for the manual step-by-step, every directive
explained, copy-paste one-command versions, and a troubleshooting table.
