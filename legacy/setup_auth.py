"""Interactive one-time setup: store iCloud credentials in Keychain, authorize Google.

Run in Terminal:  .venv/bin/python setup_auth.py
"""

import getpass
import json

import keyring

import sync


def setup_icloud() -> None:
    cfg = dict(sync.DEFAULT_CONFIG)
    if sync.CONFIG_PATH.exists():
        cfg.update(json.loads(sync.CONFIG_PATH.read_text()))

    default = cfg["icloud_username"]
    user = input(f"Apple ID (email, or phone as digits with country code, no '+') "
                 f"[press Enter for {default}]: ").strip() or default
    if not any(ch.isalpha() for ch in user):
        user = "".join(ch for ch in user if ch.isdigit())  # "+86 159..." -> "86159..."
    pw = getpass.getpass("iCloud app-specific password (xxxx-xxxx-xxxx-xxxx, input hidden): ").strip()

    import caldav
    from caldav.lib.error import AuthorizationError
    print(f"Connecting to iCloud as {user} ...")
    try:
        with caldav.DAVClient(url=sync.ICLOUD_CALDAV_URL, username=user, password=pw) as client:
            names = [c.get_display_name() for c in client.principal().calendars()]
    except AuthorizationError:
        raise SystemExit("iCloud rejected the login. Check that the Apple ID is your email or phone "
                         "digits (not a username), and that the app-specific password is current. "
                         "Nothing was saved.")
    print("iCloud calendars found:")
    for n in names:
        print("  -", n)

    keyring.set_password(sync.KEYRING_SERVICE, user, pw)
    cfg["icloud_username"] = user
    sync.CONFIG_PATH.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")
    print(f"Saved password to Keychain and username to {sync.CONFIG_PATH}")
    print('To sync only some calendars, list their names under "icloud_calendars" in config.json.')


def setup_google() -> None:
    if not sync.GOOGLE_CLIENT_PATH.exists():
        raise SystemExit(f"Put your OAuth client file at {sync.GOOGLE_CLIENT_PATH} first.")
    print("A browser window will open; sign in with the Google account to sync into.")
    service = sync.google_service(interactive=True)
    cfg = sync.load_config()
    state = sync.load_state()
    cal_id = sync.ensure_google_calendar(service, cfg, state)
    print(f"Google calendar ready: {cfg['google_calendar_name']} ({cal_id})")


if __name__ == "__main__":
    sync.SECRETS_DIR.mkdir(mode=0o700, exist_ok=True)
    setup_icloud()
    setup_google()
    print("\nAll set. Try:  .venv/bin/python sync.py --dry-run")
