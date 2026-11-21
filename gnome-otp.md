# GNOME Login with TOTP (Google Authenticator)

Make the GNOME (GDM) login screen require a 6-digit TOTP code **in addition
to** your normal password — the same two-factor flow as SSH.

Tested on **Ubuntu 26.04 LTS, GDM3, GNOME Shell (Wayland)**.

---

## 1. How it works

Login is handled by PAM. Each service reads its own config in `/etc/pam.d/`:

| Service | File | Effect |
|---------|------|--------|
| SSH | `/etc/pam.d/sshd` | password **+** OTP |
| GNOME login | `/etc/pam.d/gdm-password` | password **+** OTP |

Both call `pam_google_authenticator.so` and read the **same** secret file:

```
~/.google_authenticator   (mode 400, owner: you)
```

One authenticator entry therefore secures SSH and GNOME identically; the phone
app shows a single code that unlocks both.

The key line in `/etc/pam.d/gdm-password`:

```
auth	required	pam_google_authenticator.so
```

placed **after** `@include common-auth`:

```
auth    requisite       pam_nologin.so
auth	required	pam_succeed_if.so user != root quiet_success
@include common-auth                        # password check
auth	required	pam_google_authenticator.so   # OTP check  <-- added
auth    optional        pam_gnome_keyring.so
```

`required` means password **and** OTP must both succeed.

---

## 2. Quick start

```bash
chmod +x setup-gnome-otp.sh

./setup-gnome-otp.sh            # every user must have a secret
./setup-gnome-otp.sh nullok     # only users WITH a secret are prompted
```

> If `~/.google_authenticator` already exists (e.g. from `setup-ssh-otp.sh`),
> the script **reuses it** — it does not overwrite your working SSH secret.

Then log out and confirm the login screen asks for password, then
verification code.

---

## 3. Manual setup

### 3.1 Install the PAM module

```bash
sudo apt-get update
sudo apt-get install -y libpam-google-authenticator
```

### 3.2 Generate a secret (only if you don't already have one)

```bash
google-authenticator
```

Recommended answers:

| Prompt | Choice | Why |
|--------|--------|-----|
| Time-based tokens? | **y** | Standard TOTP |
| Update `.google_authenticator`? | **y** | Writes the secret |
| Disallow multiple uses? | **y** | Blocks code reuse |
| Rate-limit logins? | **y** | Throttles brute force |

Scan the QR into your phone app and save the printed scratch codes.

> ⚠️ If SSH OTP is already working, **do not re-run** `google-authenticator` —
> it overwrites `~/.google_authenticator` and invalidates your current codes.
> GNOME shares the existing file.

### 3.3 Enable OTP for GNOME login

```bash
# back up first
sudo cp -a /etc/pam.d/gdm-password /etc/pam.d/gdm-password.bak.$(date +%s)

# insert the OTP line right after the password check
sudo sed -i '/^@include common-auth$/a auth required pam_google_authenticator.so' /etc/pam.d/gdm-password
```

Verify:

```bash
sed -n '1,8p' /etc/pam.d/gdm-password
```

No GDM restart is required — the change is read on the next login.

---

## 4. Test before you rely on it

Keep an SSH session open (recovery path). Test the PAM module in isolation
with `pamtester`:

```bash
sudo apt-get install -y pamtester

# temporary test service that only runs the OTP module
sudo bash -c 'echo "auth required pam_google_authenticator.so" > /etc/pam.d/ga-test'

# compute the current 6-digit code (pure Python, no extra deps)
cat > /tmp/totp.py <<'PY'
import base64, hashlib, hmac, struct, time
with open('/home/you/.google_authenticator') as f:
    secret = f.readline().strip().replace(' ', '')
key = base64.b32decode(secret + '=' * (-len(secret) % 8), casefold=True)
h = hmac.new(key, struct.pack('>Q', int(time.time()) // 30), hashlib.sha1).digest()
o = h[-1] & 0x0f
print(f'{(struct.unpack(">I", h[o:o+4])[0] & 0x7fffffff) % 1000000:06d}')
PY

CODE=$(python3 /tmp/totp.py)
echo "$CODE" | pamtester ga-test you authenticate     # expect: successfully authenticated
echo "000000" | pamtester ga-test you authenticate    # expect: Authentication failure
```

Clean up:

```bash
sudo rm -f /etc/pam.d/ga-test
rm -f /tmp/totp.py
```

Then log out of GNOME and confirm the real prompt appears.

---

## 5. Rollback

```bash
sudo sed -i '/pam_google_authenticator\.so/d' /etc/pam.d/gdm-password
```

or restore the backup taken in 3.3:

```bash
sudo cp -a /etc/pam.d/gdm-password.bak.<timestamp> /etc/pam.d/gdm-password
```

---

## 6. Troubleshooting

### 6.1 Locked out of GNOME
SSH still works (same secret, so the phone code also unlocks SSH). From SSH:

```bash
sudo sed -i '/pam_google_authenticator\.so/d' /etc/pam.d/gdm-password
```

### 6.2 "Verification code" field not shown
- Confirm the line sits **after** `@include common-auth` in
  `/etc/pam.d/gdm-password`.
- Modern GDM shows password first, then a second prompt for the code.
- Check the journal:
  ```bash
  journalctl -u gdm -b | grep -i pam_google
  ```

### 6.3 Only some users should need OTP
Use `nullok`. Users without `~/.google_authenticator` fall back to
password-only; users with the file must supply a code:

```
auth	required	pam_google_authenticator.so nullok
```

Plain `required` (the default) means **every** GNOME user must have enrolled.

### 6.4 Code always "wrong"
- Check clocks — TOTP is time-based:
  ```bash
  timedatectl            # confirm "System clock synchronized: yes"
  ```
- Confirm you're reading the same secret SSH uses.

### 6.5 Lost phone / lost secret
Use the scratch codes printed at enrollment, or use the console / recovery
boot to comment out the `pam_google_authenticator.so` lines, then re-enroll.

---

## 7. Security notes

- Keep `~/.google_authenticator` at mode `400` (owner-read only).
- The shared secret means a compromised secret file compromises both SSH and
  GNOME 2FA — protect it and any backups (they contain the secret too).
- `rate-limit` and `disallow-reuse` in `~/.google_authenticator` make code
  replay and brute-force impractical.
