# /// script
# requires-python = ">=3.10"
# dependencies = ["cryptography"]
# ///
"""Offline Bitwarden vault viewer — decrypt a per-account backup with master password."""

import base64
import hmac
import hashlib
import json
import os
import sys
import getpass
from datetime import datetime
from pathlib import Path

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
from cryptography.hazmat.primitives.kdf.hkdf import HKDFExpand
from cryptography.hazmat.primitives import hashes


def derive_master_key(password: str, email: str, kdf_type: int, kdf_config: dict) -> bytes:
    salt = email.lower().encode("utf-8")
    pw = password.encode("utf-8")
    if kdf_type == 0:  # PBKDF2
        kdf = PBKDF2HMAC(
            algorithm=hashes.SHA256(),
            length=32,
            salt=salt,
            iterations=kdf_config.get("iterations", 600000),
        )
        return kdf.derive(pw)
    elif kdf_type == 1:  # Argon2id
        try:
            import argon2
        except ImportError:
            sys.exit("This vault uses Argon2id KDF. Install argon2-cffi: uv pip install argon2-cffi")
        raw = argon2.low_level.hash_secret_raw(
            secret=pw,
            salt=hashlib.sha256(salt).digest(),
            time_cost=kdf_config.get("iterations", 3),
            memory_cost=kdf_config.get("memory", 64) * 1024,
            parallelism=kdf_config.get("parallelism", 4),
            hash_len=32,
            type=argon2.low_level.Type.ID,
        )
        return raw
    else:
        sys.exit(f"Unsupported KDF type: {kdf_type}")


def stretch_master_key(master_key: bytes) -> tuple[bytes, bytes]:
    enc_key = HKDFExpand(algorithm=hashes.SHA256(), length=32, info=b"enc").derive(master_key)
    mac_key = HKDFExpand(algorithm=hashes.SHA256(), length=32, info=b"mac").derive(master_key)
    return enc_key, mac_key


def parse_enc_string(s: str) -> tuple[int, bytes, bytes, bytes | None]:
    enc_type_str, rest = s.split(".", 1)
    enc_type = int(enc_type_str)
    parts = rest.split("|")
    iv = base64.b64decode(parts[0])
    ct = base64.b64decode(parts[1])
    mac = base64.b64decode(parts[2]) if len(parts) > 2 else None
    return enc_type, iv, ct, mac


def decrypt_enc_string(s: str, enc_key: bytes, mac_key: bytes) -> bytes:
    enc_type, iv, ct, mac = parse_enc_string(s)
    if enc_type == 2 and mac is not None:
        expected = hmac.new(mac_key, iv + ct, hashlib.sha256).digest()
        if not hmac.compare_digest(expected, mac):
            raise ValueError("HMAC verification failed")
    cipher = Cipher(algorithms.AES(enc_key), modes.CBC(iv))
    decryptor = cipher.decryptor()
    padded = decryptor.update(ct) + decryptor.finalize()
    unpadder = padding.PKCS7(128).unpadder()
    return unpadder.update(padded) + unpadder.finalize()


def decrypt_field(s: str | None, enc_key: bytes, mac_key: bytes) -> str:
    if not s:
        return ""
    try:
        return decrypt_enc_string(s, enc_key, mac_key).decode("utf-8")
    except Exception:
        return "<decryption failed>"


BACKUP_DIR = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "bitwarden-backup"


def find_latest_backup(email: str) -> Path | None:
    account_dir = BACKUP_DIR / email
    if not account_dir.is_dir():
        return None
    backups = sorted(account_dir.glob("bw-gui_*.json"), reverse=True)
    return backups[0] if backups else None


def select_vault() -> Path:
    """Prompt user to pick an account, return path to latest backup."""
    accounts = [d.name for d in BACKUP_DIR.iterdir() if d.is_dir() and "@" in d.name]
    if not accounts:
        sys.exit("No account backups found.")
    print("Available accounts:")
    for i, acct in enumerate(accounts, 1):
        latest = find_latest_backup(acct)
        age = ""
        if latest:
            mtime = datetime.fromtimestamp(latest.stat().st_mtime)
            age = f" (latest: {mtime:%Y-%m-%d %H:%M})"
        print(f"  {i}. {acct}{age}")
    choice = input("\nAccount number: ").strip()
    try:
        email = accounts[int(choice) - 1]
    except (ValueError, IndexError):
        sys.exit("Invalid choice.")
    vault_path = find_latest_backup(email)
    if not vault_path:
        sys.exit(f"No backups found for {email}")
    print(f"Using: {vault_path.name}")
    return vault_path


def main():
    vault_path = Path(sys.argv[1]) if len(sys.argv) > 1 else select_vault()

    data = json.loads(vault_path.read_text())

    # Find the account UUID and email
    email = data.get("_email")
    uuid = data.get("_uuid")
    if not email or not uuid:
        sys.exit("Backup file missing account metadata (_email, _uuid).")

    prefix = f"user_{uuid}_"

    # Get KDF config
    kdf_config = data.get(f"{prefix}kdfConfig_kdfConfig", {})
    kdf_type = kdf_config.get("kdfType", 0)

    # Get encrypted user key
    enc_user_key = data.get(f"{prefix}masterPassword_masterKeyEncryptedUserKey")
    if not enc_user_key:
        sys.exit("No encrypted user key found in backup.")

    password = getpass.getpass(f"Master password for {email}: ")

    # Derive keys
    master_key = derive_master_key(password, email, kdf_type, kdf_config)
    m_enc, m_mac = stretch_master_key(master_key)

    # Decrypt user symmetric key
    try:
        user_key_raw = decrypt_enc_string(enc_user_key, m_enc, m_mac)
    except ValueError:
        sys.exit("Wrong master password (HMAC verification failed).")

    u_enc = user_key_raw[:32]
    u_mac = user_key_raw[32:64]

    # Decrypt folders
    folders = data.get(f"{prefix}folder_folders", {})
    folder_map = {}
    for fid, folder in folders.items():
        name = decrypt_field(folder.get("name"), u_enc, u_mac)
        folder_map[fid] = name

    # Decrypt ciphers
    ciphers = data.get(f"{prefix}ciphers_ciphers", {})
    entries = []
    for cid, cipher in ciphers.items():
        # Resolve per-cipher key if present
        c_enc, c_mac = u_enc, u_mac
        if cipher.get("key"):
            try:
                ck_raw = decrypt_enc_string(cipher["key"], u_enc, u_mac)
                c_enc, c_mac = ck_raw[:32], ck_raw[32:64]
            except Exception:
                print(f"  Warning: failed to decrypt per-cipher key for {cid}, using account key", file=sys.stderr)

        entry = {
            "name": decrypt_field(cipher.get("name"), c_enc, c_mac),
            "type": cipher.get("type", 0),
            "folder": folder_map.get(cipher.get("folderId"), ""),
            "favorite": cipher.get("favorite", False),
        }

        login = cipher.get("login")
        if login:
            entry["username"] = decrypt_field(login.get("username"), c_enc, c_mac)
            entry["password"] = decrypt_field(login.get("password"), c_enc, c_mac)
            entry["totp"] = decrypt_field(login.get("totp"), c_enc, c_mac)
            uris = login.get("uris") or []
            entry["uris"] = [decrypt_field(u.get("uri"), c_enc, c_mac) for u in uris]

        notes = cipher.get("notes")
        if notes:
            entry["notes"] = decrypt_field(notes, c_enc, c_mac)

        # Card type
        card = cipher.get("card")
        if card:
            entry["card"] = {
                "holder": decrypt_field(card.get("cardholderName"), c_enc, c_mac),
                "number": decrypt_field(card.get("number"), c_enc, c_mac),
                "expMonth": decrypt_field(card.get("expMonth"), c_enc, c_mac),
                "expYear": decrypt_field(card.get("expYear"), c_enc, c_mac),
                "code": decrypt_field(card.get("code"), c_enc, c_mac),
                "brand": decrypt_field(card.get("brand"), c_enc, c_mac),
            }

        # Identity type
        identity = cipher.get("identity")
        if identity:
            id_fields = {}
            for f in ["firstName", "lastName", "email", "phone", "address1",
                       "address2", "city", "state", "postalCode", "country", "company"]:
                val = decrypt_field(identity.get(f), c_enc, c_mac)
                if val:
                    id_fields[f] = val
            if id_fields:
                entry["identity"] = id_fields

        entries.append(entry)

    display_entries(email, entries)


def display_entries(email: str, entries: list[dict]) -> None:
    entries.sort(key=lambda e: (e.get("folder", ""), e["name"].lower()))
    type_names = {1: "Login", 2: "Note", 3: "Card", 4: "Identity"}
    current_folder = None

    print(f"\n{'='*60}")
    print(f" {email} — {len(entries)} items")
    print(f"{'='*60}")

    for e in entries:
        folder = e.get("folder") or "(No Folder)"
        if folder != current_folder:
            current_folder = folder
            print(f"\n── {folder} ──")

        tname = type_names.get(e["type"], "?")
        star = " ★" if e.get("favorite") else ""
        print(f"\n  [{tname}] {e['name']}{star}")

        if e.get("username"):
            print(f"    User: {e['username']}")
        if e.get("password"):
            print(f"    Pass: {e['password']}")
        if e.get("totp"):
            print(f"    TOTP: {e['totp']}")
        for uri in e.get("uris", []):
            if uri:
                print(f"    URI:  {uri}")
        if e.get("notes"):
            preview = e["notes"][:80].replace("\n", " ")
            if len(e["notes"]) > 80:
                preview += "..."
            print(f"    Note: {preview}")
        if "card" in e:
            c = e["card"]
            if c.get("number"):
                print(f"    Card: {c['number']}")
            if c.get("holder"):
                print(f"    Name: {c['holder']}")
            if c.get("expMonth") or c.get("expYear"):
                print(f"    Exp:  {c.get('expMonth','??')}/{c.get('expYear','??')}")
            if c.get("code"):
                print(f"    CVV:  {c['code']}")
        if "identity" in e:
            for k, v in e["identity"].items():
                print(f"    {k}: {v}")


if __name__ == "__main__":
    main()
