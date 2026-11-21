#!/usr/bin/env bash
#
# Enable TOTP (Google Authenticator) for GNOME (GDM) login on Ubuntu / Debian.
#
# Usage:
#   ./setup-gnome-otp.sh           # every user needs a secret (required)
#   ./setup-gnome-otp.sh nullok    # only users WITH a secret are prompted (opt-in)
#
# If ~/.google_authenticator already exists (e.g. from setup-ssh-otp.sh), it is
# REUSED so SSH and GNOME share one authenticator entry. A new secret is only
# generated when the file is missing.
#
set -euo pipefail

MODE="${1:-required}"
case "$MODE" in
  required|nullok) ;;
  *) echo "usage: $0 {required|nullok}" >&2; exit 1 ;;
esac

USER_TO_SETUP="${SUDO_USER:-$USER}"
USER_HOME="$(getent passwd "$USER_TO_SETUP" | cut -d: -f6)"
PAM_FILE="/etc/pam.d/gdm-password"
SECRET_FILE="$USER_HOME/.google_authenticator"
MODULE="pam_google_authenticator.so"

echo "==> Setting up GNOME login OTP (mode: $MODE, user: $USER_TO_SETUP)"

# ---------- 1. Install package ----------
sudo apt-get update
sudo apt-get install -y libpam-google-authenticator

# ---------- 2. Generate the TOTP secret (reuse an existing SSH secret) ----------
if [[ -s "$SECRET_FILE" ]]; then
  echo "==> Secret already exists at $SECRET_FILE — reusing it (shared with SSH)"
else
  echo "==> Generating your TOTP secret — scan the QR code with your authenticator app =="
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
fi

# ---------- 3. Back up the GDM PAM config ----------
sudo cp -a "$PAM_FILE" "$PAM_FILE.bak.$(date +%s)"

# ---------- 4. Insert the OTP module after the password check ----------
if grep -qF "$MODULE" "$PAM_FILE"; then
  echo "==> $PAM_FILE already references $MODULE — leaving as-is"
else
  if [[ "$MODE" == "nullok" ]]; then
    LINE="auth required $MODULE nullok"
  else
    LINE="auth required $MODULE"
  fi
  sudo sed -i "/^@include common-auth$/a $LINE" "$PAM_FILE"
fi

# ---------- 5. Show the result ----------
echo "==> $PAM_FILE auth stack now contains:"
grep -nE 'pam_google_authenticator|common-auth' "$PAM_FILE"

cat <<'EOF'

DONE. IMPORTANT — test before you rely on it:
  1. Keep this shell / an SSH session open (it is your recovery path).
  2. Log out of GNOME (or lock and switch user).
  3. Confirm you are asked for "Password:" then "Verification code:".

If you get locked out, recover via SSH or the console:
  sudo sed -i '/pam_google_authenticator\.so/d' /etc/pam.d/gdm-password
EOF
