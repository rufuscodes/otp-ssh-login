#!/usr/bin/env bash
#
# Enable TOTP (Google Authenticator) for SSH login on Ubuntu.
#
# Usage:
#   ./setup-ssh-otp.sh pass+otp   # password + TOTP code   (recommended here: no SSH keys set up)
#   ./setup-ssh-otp.sh key+otp    # SSH key + TOTP code    (strongest; requires authorized_keys already in place)
#   ./setup-ssh-otp.sh otp        # TOTP code only         (weakest: single factor)
#
set -euo pipefail

MODE="${1:-pass+otp}"
case "$MODE" in
  pass+otp|key+otp|otp) ;;
  *) echo "usage: $0 {pass+otp|key+otp|otp}" >&2; exit 1 ;;
esac

USER_TO_SETUP="${SUDO_USER:-$USER}"
USER_HOME="$(getent passwd "$USER_TO_SETUP" | cut -d: -f6)"
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-otp.conf"

if [[ "$MODE" == "key+otp" && ! -s "$USER_HOME/.ssh/authorized_keys" ]]; then
  echo "WARNING: $USER_HOME/.ssh/authorized_keys is empty — key+otp will lock you out." >&2
  echo "Add your public key first, then re-run. Aborting." >&2
  exit 1
fi

echo "==> Setting up SSH OTP in mode: $MODE (user: $USER_TO_SETUP)"

# ---------- 1. Install packages ----------
sudo apt-get update
sudo apt-get install -y openssh-server libpam-google-authenticator

# ---------- 2. Back up configs ----------
sudo cp -a /etc/pam.d/sshd "/etc/pam.d/sshd.bak.$(date +%s)"
sudo cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)" 2>/dev/null || true

# ---------- 3. Generate the TOTP secret (scan the QR with your app) ----------
echo "==> Generating your TOTP secret — scan the QR code below with your authenticator app =="
if [[ "$USER_TO_SETUP" != "root" ]]; then
  sudo -u "$USER_TO_SETUP" google-authenticator \
    --time-based --disallow-reuse --force \
    --rate-limit=3 --rate-time=30 --window-size=3 \
    --issuer="$(hostname)"
else
  google-authenticator \
    --time-based --disallow-reuse --force \
    --rate-limit=3 --rate-time=30 --window-size=3 \
    --issuer="$(hostname)"
fi
echo "^^^ Save the secret key + emergency scratch codes shown above. ^^^"

# ---------- 4. Configure PAM ----------
if ! grep -q pam_google_authenticator /etc/pam.d/sshd; then
  case "$MODE" in
    key+otp|otp)
      sudo sed -i 's/^@include common-auth$/auth required pam_google_authenticator.so/' /etc/pam.d/sshd
      ;;
    pass+otp)
      sudo sed -i '/^@include common-auth$/a auth required pam_google_authenticator.so' /etc/pam.d/sshd
      ;;
  esac
fi
echo "==> PAM sshd now contains:"
grep -n 'pam_google_authenticator\|common-auth' /etc/pam.d/sshd

# ---------- 5. Configure sshd (drop-in) ----------
{
  echo "UsePAM yes"
  echo "KbdInteractiveAuthentication yes"
  echo "PasswordAuthentication no"
  echo "PubkeyAuthentication yes"
  case "$MODE" in
    key+otp)         echo "AuthenticationMethods publickey,keyboard-interactive" ;;
    pass+otp|otp)    echo "AuthenticationMethods keyboard-interactive" ;;
  esac
} | sudo tee "$SSHD_DROPIN" >/dev/null

# ---------- 6. Validate & apply ----------
sudo sshd -t
echo "==> Effective sshd settings:"
sudo sshd -T 2>/dev/null | grep -Ei '^(usepam|kbdinteractiveauthentication|passwordauthentication|pubkeyauthentication|authenticationmethods) ' || true
sudo systemctl enable --now ssh
sudo systemctl restart ssh

cat <<'EOF'

DONE. IMPORTANT — test before closing this session:
  1. Open a SECOND terminal and run:  ssh YOUR_USER@THIS_HOST
  2. Confirm it asks for "Password:" (pass+otp) then "Verification code:",
     or just "Verification code:" (otp / key+otp).
  3. Only log out of THIS session once the new login works.

If you get locked out, recover via console / out-of-band access:
  sudo mv /etc/ssh/sshd_config.d/99-otp.conf /tmp/
  sudo systemctl restart ssh
EOF
