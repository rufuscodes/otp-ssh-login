#!/usr/bin/env bash
#
# SSH hardening + fail2ban for Ubuntu (run AFTER setup-ssh-otp.sh).
#
# Usage:  ./harden-ssh.sh
#
set -euo pipefail

USER_TO_SETUP="${SUDO_USER:-$USER}"
HARDENING_DROPIN="/etc/ssh/sshd_config.d/00-hardening.conf"
JAIL_FILE="/etc/fail2ban/jail.d/sshd.local"

echo "==> Hardening SSH for user: $USER_TO_SETUP"

# ---------- 1. Back up sshd_config ----------
sudo cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)" 2>/dev/null || true

# ---------- 2. SSH hardening drop-in (does not touch your 99-otp.conf) ----------
# Ubuntu ships "Include .../*.conf" at the TOP of sshd_config, so main-config
# settings override drop-ins. Fix the one that conflicts with hardening.
sudo sed -i 's/^X11Forwarding yes$/X11Forwarding no/' /etc/ssh/sshd_config
sudo tee "$HARDENING_DROPIN" >/dev/null <<EOF
# SSH hardening
PermitRootLogin no
PermitEmptyPasswords no
MaxAuthTries 4
LoginGraceTime 60
MaxSessions 4
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers $USER_TO_SETUP
EOF

# ---------- 3. Install fail2ban ----------
sudo apt-get update
sudo apt-get install -y fail2ban

# ---------- 4. fail2ban sshd jail (systemd journal backend) ----------
sudo tee "$JAIL_FILE" >/dev/null <<EOF
[sshd]
enabled = true
backend = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd
bantime = 10m
findtime = 10m
maxretry = 5
EOF

# ---------- 5. Validate & apply ----------
sudo sshd -t
sudo systemctl restart ssh
sudo systemctl enable --now fail2ban
sudo systemctl restart fail2ban

echo
echo "==> Effective sshd hardening settings:"
sudo sshd -T 2>/dev/null | grep -Ei '^(permitrootlogin|permitemptypasswords|maxauthtries|logingracetime|maxsessions|x11forwarding|clientaliveinterval|clientalivecountmax|allowusers) '

echo
echo "==> fail2ban sshd jail:"
sudo fail2ban-client status sshd 2>&1 || true

cat <<'EOF'

DONE. Verify:
  - fail2ban:  sudo fail2ban-client status sshd   (should show "Currently banned: 0")
  - trigger test (optional): from another host, fail 6 logins, then check banned IPs:
        sudo fail2ban-client status sshd
        sudo fail2ban-client get sshd banned

Note: AllowUsers is set to YOUR user only. To allow another user later, edit
  /etc/ssh/sshd_config.d/00-hardening.conf and add them, then:
  sudo systemctl restart ssh
EOF
