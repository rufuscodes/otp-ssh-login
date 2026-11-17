# SSH OTP (Two-Factor Authentication) — Step by Step

Add a Time-based One-Time Password (TOTP) as a second factor to SSH logins.
After setup, logging in over SSH requires your normal credentials **and** a
6-digit code from an authenticator app (Google Authenticator, Authy, 1Password,
Aegis, etc.).

Tested on **Ubuntu 26.04 LTS / OpenSSH 9.x**. Concepts apply to any
Debian/Ubuntu release.

---

## 1. Choose your mode

| Mode | SSH asks for | Factors | Security | Best when |
|------|--------------|---------|----------|-----------|
| `pass+otp` | password, then 6-digit code | 2 (know + have) | Strong | No SSH key set up (most common) |
| `key+otp` | SSH key, then 6-digit code | 2 (have + have) | Strongest | You already use SSH keys |
| `otp` | 6-digit code only | 1 (have) | Weakest | Rare; not recommended |

This tutorial walks through **`pass+otp`** by default and notes the one-line
differences for the other modes.

---

## 2. Prerequisites

- A user account with `sudo`
- An authenticator app on your phone
- **A second terminal/session open to the host while you work** — do not
  close your current session until you confirm the new login works.

---

## 3. Install the packages

```bash
sudo apt-get update
sudo apt-get install -y openssh-server libpam-google-authenticator
```

- `openssh-server` — the SSH daemon
- `libpam-google-authenticator` — the PAM module that checks TOTP codes

If `openssh-server` was already installed, skip to step 4.

```bash
sudo systemctl enable --now ssh
```

---

## 4. Generate your TOTP secret

Run the generator **as your own user** (not root):

```bash
google-authenticator
```

It asks several questions. Recommended answers:

| Prompt | Answer | Why |
|--------|--------|-----|
| "Do you want authentication tokens to be time-based?" | `y` | TOTP (30-second codes) |
| "Do you want to disallow multiple uses of the same token?" | `y` | Prevent replay of a used code |
| "By default, a new token is generated every 30 seconds… (rate-limit)?" | `y` | Throttle brute-force |
| "Do you want to limit attackers to 3 logins every 30s?" | `y` | 3 attempts / 30s |
| "Do you want to enable rate-limiting?" | `y` | Same as above |
| "Do you want to increase the original token time-window?" | `n` | Accept ±1 code (default) is fine |
| "Do you want me to update your `~/.google_authenticator` file?" | `y` | Write the secret |

It then prints:

- A **QR code** — scan it with your authenticator app
- Your **secret key** — back this up (or re-scan later)
- **Emergency scratch codes** — save these somewhere safe; each works once
  if you lose your phone

The secret lives at `~/.google_authenticator` (mode `600`, owned by you).

> Non-interactive equivalent (scripted):
> ```bash
> google-authenticator --time-based --disallow-reuse --force \
>   --rate-limit=3 --rate-time=30 --window-size=3 --issuer="$(hostname)"
> ```

---

## 5. Configure PAM

Back up, then edit the SSH PAM file:

```bash
sudo cp -a /etc/pam.d/sshd /etc/pam.d/sshd.bak
sudo nano /etc/pam.d/sshd
```

### For `pass+otp` (password → then code)

Find the line `@include common-auth` and add the Google Authenticator line
**directly after it**:

```
# Standard Un*x authentication.
@include common-auth
auth required pam_google_authenticator.so
```

### For `otp` (code only) or `key+otp` (key → then code)

Replace the `@include common-auth` line with the Google Authenticator line:

```
auth required pam_google_authenticator.so
```

Leave the `account`, `session`, and `password` includes untouched.

**Why this works:** `@include common-auth` runs `pam_unix` (asks the account
password). The `pam_google_authenticator.so` line then asks for the 6-digit
code. Both must succeed.

---

## 6. Configure sshd

Use a drop-in file so upgrades don't clobber your changes:

```bash
sudo tee /etc/ssh/sshd_config.d/99-otp.conf >/dev/null <<'EOF'
UsePAM yes
KbdInteractiveAuthentication yes
PasswordAuthentication no
PubkeyAuthentication yes
EOF
```

Then add the `AuthenticationMethods` line for your mode:

```bash
# pass+otp  or  otp  (code is the only interactive factor):
echo "AuthenticationMethods keyboard-interactive" | sudo tee -a /etc/ssh/sshd_config.d/99-otp.conf

# key+otp  (key first, then code):
echo "AuthenticationMethods publickey,keyboard-interactive" | sudo tee -a /etc/ssh/sshd_config.d/99-otp.conf
```

Directive meanings:

| Directive | Value | Why |
|-----------|-------|-----|
| `UsePAM` | `yes` | Route auth through PAM (runs the TOTP check) |
| `KbdInteractiveAuthentication` | `yes` | Enable the PAM question/answer channel |
| `PasswordAuthentication` | `no` | Disable the old single-factor "password" method (forces PAM path) |
| `PubkeyAuthentication` | `yes` | Keep SSH keys working |
| `AuthenticationMethods` | see above | Which factors are required, in order |

> Note: `ChallengeResponseAuthentication` is a **deprecated alias** of
> `KbdInteractiveAuthentication` on OpenSSH 8.7+. Use the new name.

---

## 7. Validate and restart

```bash
# Syntax check (must print nothing)
sudo sshd -t

# Show the EFFECTIVE settings — confirm each line
sudo sshd -T | grep -Ei '^(usepam|kbdinteractiveauthentication|passwordauthentication|pubkeyauthentication|authenticationmethods) '

# Apply
sudo systemctl restart ssh
```

Expected output:

```
usepam yes
kbdinteractiveauthentication yes
passwordauthentication no
pubkeyauthentication yes
authenticationmethods keyboard-interactive
```

If `kbdinteractiveauthentication` shows `no`, your drop-in was overridden —
edit `/etc/ssh/sshd_config` directly to remove the conflicting line.

---

## 8. Test in a SECOND session (critical)

**Do not log out of your current session yet.**

1. Open a **new** terminal and connect:

   ```bash
   ssh youruser@yourhost
   ```

2. You should see, in order:

   ```
   youruser@yourhost's password:          # step 1 (pass+otp mode)
   Verification code:                      # step 2 — type the 6-digit app code
   ```

3. Confirm you're logged in.

Only after the new session works, log out of the original session.

---

## 9. If you lock yourself out (recovery)

From the console / physical access / out-of-band (IPMI/KVM):

```bash
# Remove the drop-in and restart sshd — restores password-only login
sudo mv /etc/ssh/sshd_config.d/99-otp.conf /tmp/
sudo systemctl restart ssh
```

Then fix the problem and re-add the file. Re-run `google-authenticator` if you
lost the secret.

---

## 10. Verify it's actually enforced

Attempt a login **without** the code and confirm it fails:

```bash
# Should reject after "Verification code:" prompt with a wrong code
ssh -o PreferredAuthentications=keyboard-interactive -o NumberOfPasswordPrompts=1 youruser@yourhost
```

Check the auth log:

```bash
sudo journalctl -u ssh -n 20
# or, if rsyslog is installed:
sudo tail -n 20 /var/log/auth.log
```

---

## 11. Optional: SSH hardening + fail2ban

Layer these on top for defense in depth:

```bash
sudo apt-get install -y fail2ban

sudo tee /etc/ssh/sshd_config.d/00-hardening.conf >/dev/null <<EOF
PermitRootLogin no
PermitEmptyPasswords no
MaxAuthTries 4
LoginGraceTime 60
MaxSessions 4
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers $(whoami)
EOF

sudo tee /etc/fail2ban/jail.d/sshd.local >/dev/null <<'EOF'
[sshd]
enabled = true
backend = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd
bantime = 10m
findtime = 10m
maxretry = 5
EOF

sudo sshd -t && sudo systemctl restart ssh
sudo systemctl enable --now fail2ban && sudo systemctl restart fail2ban
sudo fail2ban-client status sshd
```

The `journalmatch` line matters on Ubuntu: sshd runs under `ssh.service`, so
the stock filter's `sshd.service` journal match would catch nothing.

---

## 12. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| "Permission denied" right away, no code prompt | `PasswordAuthentication`/`KbdInteractiveAuthentication` mis-set | Check `sudo sshd -T`; ensure drop-in is being read |
| Code always rejected | Phone clock drifted | Enable time sync on the phone; re-scan QR |
| Code rejected after working | Rate-limit (3 tries/30s) tripped | Wait 30s and retry |
| `sshd -T` shows `kbdinteractiveauthentication no` | Main `sshd_config` overrides drop-in | Remove the conflicting line from `/etc/ssh/sshd_config` |
| fail2ban never bans anyone | Journal filter mismatch | Confirm the `journalmatch = _SYSTEMD_UNIT=ssh.service` line |
| Locked out remotely | Config error | Recover via console (step 9) |

---

## 13. One-command setup (copy-paste or scripts)

Two ways to run the whole setup without following the manual steps. Pick one.

### 13a. Copy-paste (no files needed)

Paste each block into your terminal as-is (edit `MODE=` if you want a different
mode). Only interaction required: your sudo password, and scanning the QR code.

**Step 1 — install + TOTP:**

```bash
sudo bash -s <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
MODE="pass+otp"        # <- pass+otp | key+otp | otp
USER_TO_SETUP="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
USER_HOME="$(getent passwd "$USER_TO_SETUP" | cut -d: -f6)"

case "$MODE" in pass+otp|key+otp|otp) ;; *) echo "bad MODE"; exit 1;; esac
if [[ "$MODE" == "key+otp" && ! -s "$USER_HOME/.ssh/authorized_keys" ]]; then
  echo "ABORT: $USER_HOME/.ssh/authorized_keys is empty — key+otp would lock you out." >&2
  exit 1
fi

apt-get update
apt-get install -y openssh-server libpam-google-authenticator
cp -a /etc/pam.d/sshd "/etc/pam.d/sshd.bak.$(date +%s)"
cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)" 2>/dev/null || true

if [[ "$USER_TO_SETUP" == "root" ]]; then
  google-authenticator --time-based --disallow-reuse --force --no-confirm \
    --rate-limit=3 --rate-time=30 --window-size=3 --issuer="$(hostname)"
else
  sudo -u "$USER_TO_SETUP" google-authenticator \
    --time-based --disallow-reuse --force --no-confirm \
    --rate-limit=3 --rate-time=30 --window-size=3 --issuer="$(hostname)"
fi

if ! grep -q pam_google_authenticator /etc/pam.d/sshd; then
  case "$MODE" in
    key+otp|otp) sed -i 's/^@include common-auth$/auth required pam_google_authenticator.so/' /etc/pam.d/sshd ;;
    pass+otp)    sed -i '/^@include common-auth$/a auth required pam_google_authenticator.so' /etc/pam.d/sshd ;;
  esac
fi

{
  echo "UsePAM yes"
  echo "KbdInteractiveAuthentication yes"
  echo "PasswordAuthentication no"
  echo "PubkeyAuthentication yes"
  case "$MODE" in
    key+otp)      echo "AuthenticationMethods publickey,keyboard-interactive" ;;
    pass+otp|otp) echo "AuthenticationMethods keyboard-interactive" ;;
  esac
} > /etc/ssh/sshd_config.d/99-otp.conf

sshd -t
systemctl enable --now ssh
systemctl restart ssh
echo "=== Effective sshd settings ==="
sshd -T | grep -Ei '^(usepam|kbdinteractiveauthentication|passwordauthentication|pubkeyauthentication|authenticationmethods) ' || true
echo
echo "DONE. Scan the QR above into your authenticator app."
echo "Open a SECOND terminal and run:  ssh $USER_TO_SETUP@$(hostname)"
echo "Test it BEFORE closing this session."
EOF
```

**Step 2 — hardening + fail2ban:**

```bash
sudo bash -s <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
USER_TO_SETUP="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"

{
  echo "PermitRootLogin no"
  echo "PermitEmptyPasswords no"
  echo "MaxAuthTries 4"
  echo "LoginGraceTime 60"
  echo "MaxSessions 4"
  echo "X11Forwarding no"
  echo "ClientAliveInterval 300"
  echo "ClientAliveCountMax 2"
  echo "AllowUsers $USER_TO_SETUP"
} > /etc/ssh/sshd_config.d/00-hardening.conf

apt-get update
apt-get install -y fail2ban

printf '%s\n' \
  '[sshd]' \
  'enabled = true' \
  'backend = systemd' \
  'journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd' \
  'bantime = 10m' \
  'findtime = 10m' \
  'maxretry = 5' \
  > /etc/fail2ban/jail.d/sshd.local

sshd -t
systemctl restart ssh
systemctl enable --now fail2ban
systemctl restart fail2ban
echo "=== Effective sshd hardening ==="
sshd -T | grep -Ei '^(permitrootlogin|permitemptypasswords|maxauthtries|logingracetime|maxsessions|x11forwarding|clientaliveinterval|clientalivecountmax|allowusers) ' || true
echo
fail2ban-client status sshd || true
EOF
```

### 13b. Or use the script files

The same steps are also available as files in the home directory:

```bash
chmod +x ~/setup-ssh-otp.sh ~/harden-ssh.sh

./setup-ssh-otp.sh pass+otp   # install + TOTP (scan the QR when it appears)
./harden-ssh.sh               # hardening + fail2ban
```

`setup-ssh-otp.sh` accepts `pass+otp`, `key+otp`, or `otp`. It aborts safely
if you pick `key+otp` but `~/.ssh/authorized_keys` is empty.
