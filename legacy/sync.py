"""One-way mirror: iCloud calendars -> a dedicated Google calendar.

The Google calendar is treated as a disposable copy. Every event this script
creates carries a private extended property (MARKER) plus the iCloud key and a
content hash, so the Google calendar itself is the sync state: each run diffs
"what iCloud has now" against "what we previously wrote" and applies
creates / updates / deletes. Nothing outside the dedicated calendar is touched.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import hashlib
import json
import logging
import logging.handlers
import os
import re
import socket
import sys
import time
from pathlib import Path
from zoneinfo import ZoneInfo

import icalendar
import recurring_ical_events
from tzlocal import get_localzone_name

ROOT = Path(__file__).resolve().parent
CONFIG_PATH = ROOT / "config.json"
SECRETS_DIR = ROOT / "secrets"
STATE_PATH = SECRETS_DIR / "state.json"
GOOGLE_CLIENT_PATH = SECRETS_DIR / "credentials.json"
GOOGLE_TOKEN_PATH = SECRETS_DIR / "token.json"
LOCK_PATH = ROOT / ".sync.lock"
LOG_DIR = ROOT / "logs"

KEYRING_SERVICE = "icloud-gcal-sync"
ICLOUD_CALDAV_URL = "https://caldav.icloud.com"
GOOGLE_SCOPES = [
    # Can only create calendars and manage events in calendars this app created.
    "https://www.googleapis.com/auth/calendar.app.created",
    # Read-only calendar list, used to re-find our calendar if state.json is lost.
    "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
]

MARKER = "icloudSync"
CALENDAR_TAG = "[icloud-gcal-sync]"
KEY_PROP = "icloudKey"
HASH_PROP = "icloudHash"

DEFAULT_CONFIG = {
    "icloud_username": "",
    "icloud_calendars": [],          # empty = every iCloud calendar that holds events
    "google_calendar_name": "iCloud Sync",
    "past_days": 30,
    "future_days": 365,
    "max_deletes_per_run": 50,
}

log = logging.getLogger("icloud_gcal_sync")
LOCAL_TZ = ZoneInfo(get_localzone_name())


# ---------------------------------------------------------------------------
# config / state

def load_config() -> dict:
    cfg = dict(DEFAULT_CONFIG)
    if CONFIG_PATH.exists():
        cfg.update(json.loads(CONFIG_PATH.read_text()))
    if not cfg["icloud_username"]:
        raise SystemExit(f"icloud_username missing in {CONFIG_PATH}; run setup_auth.py first")
    return cfg


def load_state() -> dict:
    if STATE_PATH.exists():
        return json.loads(STATE_PATH.read_text())
    return {}


def save_state(state: dict) -> None:
    SECRETS_DIR.mkdir(mode=0o700, exist_ok=True)
    tmp = STATE_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2))
    os.replace(tmp, STATE_PATH)


# ---------------------------------------------------------------------------
# iCalendar -> Google event body (pure functions, unit-tested)

def _as_local_aware(value):
    """date stays date; naive (floating) datetime gets the local timezone."""
    if isinstance(value, dt.datetime) and value.tzinfo is None:
        return value.replace(tzinfo=LOCAL_TZ)
    return value


def start_instant(value) -> dt.datetime:
    """Comparable instant for window filtering: all-day dates map to local midnight."""
    if isinstance(value, dt.datetime):
        return _as_local_aware(value)
    return dt.datetime.combine(value, dt.time(), tzinfo=LOCAL_TZ)


def _google_time(value) -> dict:
    if isinstance(value, dt.datetime):
        return {"dateTime": _as_local_aware(value).isoformat()}
    return {"date": value.isoformat()}


def recurring_uids(cal: icalendar.Calendar) -> set[str]:
    """UIDs that belong to a recurring series (master with RRULE/RDATE, or an override)."""
    uids = set()
    for comp in cal.walk("VEVENT"):
        if "RRULE" in comp or "RDATE" in comp or "RECURRENCE-ID" in comp:
            uids.add(str(comp.get("UID")))
    return uids


def event_key(cal_id: str, occurrence, recurring: bool) -> str:
    uid = str(occurrence.get("UID"))
    if not recurring:
        # A one-off event keeps its identity even if it is moved to another time.
        return f"{cal_id}|{uid}"
    rid = (occurrence.get("RECURRENCE-ID") or occurrence.get("DTSTART")).dt
    if isinstance(rid, dt.datetime) and rid.tzinfo is not None:
        rid_val = rid.astimezone(dt.timezone.utc).isoformat()
    else:
        # Dates and floating times: key on the wall-clock value so it doesn't
        # change when the Mac's time zone changes (e.g. while traveling).
        rid_val = rid.isoformat()
    return f"{cal_id}|{uid}|{rid_val}"


def occurrence_to_body(occurrence) -> dict | None:
    """Convert one expanded VEVENT occurrence into a Google event body (without sync props)."""
    if str(occurrence.get("STATUS", "")).upper() == "CANCELLED":
        return None
    start = occurrence["DTSTART"].dt
    if "DTEND" in occurrence:
        end = occurrence["DTEND"].dt
    elif "DURATION" in occurrence:
        end = start + occurrence["DURATION"].dt
    else:
        end = start + dt.timedelta(days=1) if not isinstance(start, dt.datetime) else start

    all_day = not isinstance(start, dt.datetime)
    if all_day and isinstance(end, dt.datetime):
        end = end.date()
    if not all_day and not isinstance(end, dt.datetime):
        end = dt.datetime.combine(end, dt.time(), tzinfo=start.tzinfo)
    if all_day and end <= start:
        end = start + dt.timedelta(days=1)
    if not all_day and _as_local_aware(end) < _as_local_aware(start):
        end = start

    body = {
        "summary": str(occurrence.get("SUMMARY", "")) or "(No title)",
        "start": _google_time(start),
        "end": _google_time(end),
        # Apple already notifies; don't double every alert on Google's side.
        "reminders": {"useDefault": False, "overrides": []},
    }
    if occurrence.get("LOCATION"):
        body["location"] = str(occurrence["LOCATION"])
    if occurrence.get("DESCRIPTION"):
        body["description"] = str(occurrence["DESCRIPTION"])
    if str(occurrence.get("TRANSP", "")).upper() == "TRANSPARENT":
        body["transparency"] = "transparent"
    return body


def body_hash(body: dict) -> str:
    return hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()[:32]


def expand_ics(ics_text: str, cal_id: str, win_start: dt.datetime, win_end: dt.datetime) -> dict:
    """Return {key: body} for every occurrence whose start falls in [win_start, win_end)."""
    cal = icalendar.Calendar.from_ical(ics_text)
    rec = recurring_uids(cal)
    out = {}
    for occ in recurring_ical_events.of(cal).between(win_start, win_end):
        if not (win_start <= start_instant(occ["DTSTART"].dt) < win_end):
            continue
        body = occurrence_to_body(occ)
        if body is None:
            continue
        out[event_key(cal_id, occ, str(occ.get("UID")) in rec)] = body
    return out


# ---------------------------------------------------------------------------
# iCloud side

def _uid_of(ics_text: str) -> str | None:
    unfolded = re.sub(r"\r?\n[ \t]", "", ics_text)  # long UIDs wrap onto continuation lines
    m = re.search(r"^UID(?:;[^:\r\n]*)?:(.*)$", unfolded, re.MULTILINE)
    return m.group(1).strip() if m else None


def read_keychain_password(username: str, timeout: int = 30) -> str | None:
    """Keychain can block in C on a GUI 'allow access' prompt under launchd, where a
    signal can't interrupt it, so read it in a child process we can kill."""
    import subprocess

    code = "import keyring,sys; p=keyring.get_password(sys.argv[1], sys.argv[2]); sys.stdout.write(p or '')"
    try:
        out = subprocess.run([sys.executable, "-c", code, KEYRING_SERVICE, username],
                             capture_output=True, text=True, timeout=timeout, check=True)
    except subprocess.TimeoutExpired:
        raise RuntimeError("Keychain read timed out (access prompt?); re-run setup_auth.py in Terminal")
    return out.stdout or None


def fetch_icloud(cfg: dict, win_start: dt.datetime, win_end: dt.datetime) -> tuple[dict, list]:
    """Return ({key: body}, protected_prefixes).

    protected_prefixes are key prefixes whose Google copies must not be deleted
    this run because their iCloud source could not be parsed.
    """
    import caldav

    password = read_keychain_password(cfg["icloud_username"])
    if not password:
        raise SystemExit("iCloud app-specific password not in Keychain; run setup_auth.py")

    wanted = set(cfg["icloud_calendars"])
    desired: dict = {}
    protected: list = []
    with caldav.DAVClient(url=ICLOUD_CALDAV_URL, username=cfg["icloud_username"],
                          password=password) as client:
        calendars = client.principal().calendars()
        seen = set()
        for cal in calendars:
            name = cal.get_display_name()
            if wanted and name not in wanted:
                continue
            try:
                if "VEVENT" not in cal.get_supported_components():
                    continue
            except Exception:  # some servers don't report components; just try it
                pass
            seen.add(name)
            # Stable across renames and iCloud partition-host changes: hash of the URL path only.
            cal_id = hashlib.sha1(str(cal.url.path).rstrip("/").encode()).hexdigest()[:12]
            objs = cal.search(start=win_start, end=win_end, event=True, expand=False)
            count = 0
            for obj in objs:
                try:
                    found = expand_ics(obj.data, cal_id, win_start, win_end)
                except Exception as e:
                    # One malformed event must not stop the whole sync; keep its old copy.
                    uid = _uid_of(obj.data or "")
                    log.warning("skipping unparseable event in %r (UID=%s): %r", name, uid, e)
                    protected.append(f"{cal_id}|{uid}" if uid else f"{cal_id}|")
                    continue
                count += len(found)
                desired.update(found)
            log.info("iCloud calendar %r: %d occurrences in window", name, count)
        missing = wanted - seen
        if missing:
            # Treat as a hard failure: otherwise every event from that calendar would be deleted.
            raise RuntimeError(f"configured iCloud calendars not found: {sorted(missing)}")
    return desired, protected


# ---------------------------------------------------------------------------
# Google side

def google_service(interactive: bool = False):
    from google.auth.transport.requests import Request
    from google.oauth2.credentials import Credentials
    from googleapiclient.discovery import build

    creds = None
    old_json = None
    if GOOGLE_TOKEN_PATH.exists():
        old_json = GOOGLE_TOKEN_PATH.read_text()
        creds = Credentials.from_authorized_user_file(str(GOOGLE_TOKEN_PATH), GOOGLE_SCOPES)
    if creds and creds.expired and creds.refresh_token:
        creds.refresh(Request())  # RefreshError here usually means the 7-day "Testing" expiry
    if not creds or not creds.valid:
        if not interactive:
            raise SystemExit("Google token missing/invalid; run setup_auth.py")
        from google_auth_oauthlib.flow import InstalledAppFlow
        flow = InstalledAppFlow.from_client_secrets_file(str(GOOGLE_CLIENT_PATH), GOOGLE_SCOPES)
        creds = flow.run_local_server(port=0)
    new_json = creds.to_json()
    if new_json != old_json:
        SECRETS_DIR.mkdir(mode=0o700, exist_ok=True)
        tmp = GOOGLE_TOKEN_PATH.with_suffix(".tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(new_json)
        os.replace(tmp, GOOGLE_TOKEN_PATH)
    return build("calendar", "v3", credentials=creds, cache_discovery=False)


def ensure_google_calendar(service, cfg: dict, state: dict, create: bool = True) -> str | None:
    from googleapiclient.errors import HttpError

    cal_id = state.get("google_calendar_id")
    if cal_id:
        try:
            service.calendars().get(calendarId=cal_id).execute(num_retries=3)
            return cal_id
        except HttpError as e:
            if e.resp.status != 404:
                raise
            log.warning("stored Google calendar %s no longer exists", cal_id)

    name = cfg["google_calendar_name"]
    page = None
    while True:
        resp = service.calendarList().list(pageToken=page, minAccessRole="owner").execute(num_retries=3)
        for item in resp.get("items", []):
            # Only adopt a calendar this tool created (it carries the marker), never a
            # user calendar that merely shares the name.
            if item.get("summary") == name and CALENDAR_TAG in item.get("description", ""):
                state["google_calendar_id"] = item["id"]
                save_state(state)
                return item["id"]
        page = resp.get("nextPageToken")
        if not page:
            break

    if not create:
        return None
    created = service.calendars().insert(
        body={"summary": name, "timeZone": get_localzone_name(),
              "description": "One-way mirror of iCloud calendars. Edit events in Apple Calendar; "
                             "changes made here are lost when the iCloud event changes or is deleted. "
                             + CALENDAR_TAG}
    ).execute(num_retries=3)
    log.info("created Google calendar %r (%s)", name, created["id"])
    state["google_calendar_id"] = created["id"]
    save_state(state)
    return created["id"]


def google_event_start(ev: dict) -> dt.datetime:
    s = ev["start"]
    if "dateTime" in s:
        return dt.datetime.fromisoformat(s["dateTime"])
    return start_instant(dt.date.fromisoformat(s["date"]))


def fetch_google(service, cal_id: str) -> dict:
    """Return {key: [google events]} for ALL events this tool wrote, at any date.

    Matching against everything (not just the window) means an event moved into
    the window from outside it updates its old copy instead of orphaning it.
    """
    existing: dict = {}
    page = None
    while True:
        resp = service.events().list(
            calendarId=cal_id, privateExtendedProperty=f"{MARKER}=1",
            singleEvents=True, showDeleted=False, maxResults=2500, pageToken=page,
        ).execute(num_retries=5)
        for ev in resp.get("items", []):
            key = ev.get("extendedProperties", {}).get("private", {}).get(KEY_PROP)
            if key:
                existing.setdefault(key, []).append(ev)
        page = resp.get("nextPageToken")
        if not page:
            break
    return existing


# ---------------------------------------------------------------------------
# diff + apply

def is_protected(key: str, protected: list) -> bool:
    return any(key == p or key.startswith(p if p.endswith("|") else p + "|") for p in protected)


def plan(desired: dict, existing: dict, in_window, protected: list = ()) -> tuple[list, list, list, list]:
    """Return (creates, updates, dupes, deletes).

    creates: [(key, body)]; updates: [(event_id, key, body)]; dupes/deletes: [event_id].
    dupes are extra Google copies of a key that is still kept (always safe to remove).
    deletes only cover events inside the sync window whose source is gone and
    whose source was not skipped as unparseable.
    """
    creates, updates, dupes, deletes = [], [], [], []
    for key, body in desired.items():
        evs = existing.get(key, [])
        if not evs:
            creates.append((key, body))
            continue
        keep, *extra = evs
        dupes.extend(e["id"] for e in extra)
        old_hash = keep.get("extendedProperties", {}).get("private", {}).get(HASH_PROP)
        if old_hash != body_hash(body):
            updates.append((keep["id"], key, body))
    for key, evs in existing.items():
        if key in desired or is_protected(key, protected):
            continue
        deletes.extend(e["id"] for e in evs if in_window(e))
    return creates, updates, dupes, deletes


def deletion_guard(desired: dict, creates: list, deletes: list, max_deletes: int,
                   prev_desired: int | None) -> str | None:
    """Return a reason to abort this run's writes, or None.

    The danger is iCloud suddenly returning far fewer events (a calendar vanished,
    partial data). Re-keyed events (editing "all future events" of a series) show up
    as deletes+creates but don't shrink the iCloud count, so compare the iCloud
    count with the last successful run's. That comparison survives a run that
    crashed halfway; the per-run net count is only a fallback when there is no history.
    """
    if not desired and deletes:
        return f"iCloud returned 0 events but {len(deletes)} Google copies would be deleted"
    if prev_desired is not None:
        drop = prev_desired - len(desired)
        if drop > max_deletes and len(deletes) > max_deletes:
            return (f"iCloud now has {len(desired)} events vs {prev_desired} last run "
                    f"(drop of {drop} > max_deletes_per_run={max_deletes})")
        return None
    net = len(deletes) - len(creates)
    if net > max_deletes:
        return f"net deletion of {net} events exceeds max_deletes_per_run={max_deletes}"
    return None


def with_props(key: str, body: dict) -> dict:
    full = dict(body)
    full["extendedProperties"] = {"private": {MARKER: "1", KEY_PROP: key, HASH_PROP: body_hash(body)}}
    return full


def apply(service, cal_id: str, creates, updates, deletes, dry_run: bool) -> None:
    from googleapiclient.errors import HttpError

    for key, body in creates:
        log.info("CREATE %s  %s", body["start"], body["summary"])
        if not dry_run:
            service.events().insert(calendarId=cal_id, body=with_props(key, body)).execute(num_retries=5)
    for ev_id, key, body in updates:
        log.info("UPDATE %s  %s", body["start"], body["summary"])
        if not dry_run:
            # Full replace: fields removed in iCloud (e.g. location) disappear in Google too.
            service.events().update(calendarId=cal_id, eventId=ev_id,
                                    body=with_props(key, body)).execute(num_retries=5)
    for ev_id in deletes:
        log.info("DELETE %s", ev_id)
        if not dry_run:
            try:
                service.events().delete(calendarId=cal_id, eventId=ev_id).execute(num_retries=5)
            except HttpError as e:
                if e.resp.status not in (404, 410):  # already gone
                    raise


def notify(message: str, every_hours: float = 6) -> None:
    """macOS notification, throttled so a persistent failure doesn't ping every 5 minutes."""
    import subprocess
    import time

    stamp = LOG_DIR / ".last_alert"
    try:
        if stamp.exists() and time.time() - stamp.stat().st_mtime < every_hours * 3600:
            return
        LOG_DIR.mkdir(exist_ok=True)
        stamp.touch()
        text = message.replace("\\", "\\\\").replace('"', '\\"')[:200]
        subprocess.run(["osascript", "-e", f'display notification "{text}" with title "iCloud→Google sync"'],
                       timeout=10, check=False)
    except Exception:
        log.exception("could not show notification")


def run(dry_run: bool, allow_mass_delete: bool) -> None:
    cfg = load_config()
    state = load_state()
    now = dt.datetime.now(LOCAL_TZ)
    today = dt.datetime.combine(now.date(), dt.time(), tzinfo=LOCAL_TZ)
    win_start = today - dt.timedelta(days=cfg["past_days"])
    win_end = today + dt.timedelta(days=cfg["future_days"])

    # Fetch iCloud first: if it fails, we stop before touching Google.
    desired, protected = fetch_icloud(cfg, win_start, win_end)
    service = google_service()
    cal_id = ensure_google_calendar(service, cfg, state, create=not dry_run)
    existing = fetch_google(service, cal_id) if cal_id else {}

    creates, updates, dupes, deletes = plan(
        desired, existing, lambda ev: win_start <= google_event_start(ev) < win_end, protected)
    log.info("plan: %d create, %d update, %d delete, %d duplicate (iCloud=%d, Google=%d, protected=%d)",
             len(creates), len(updates), len(deletes), len(dupes), len(desired), len(existing), len(protected))

    reason = None if allow_mass_delete else deletion_guard(
        desired, creates, deletes, cfg["max_deletes_per_run"], state.get("prev_desired"))
    if reason:
        # Apply nothing but duplicate cleanup: half-applying (creates without deletes)
        # would leave duplicates behind. Needs a human to look.
        log.error("%s; skipping this run's changes. If intended, run: sync.py --allow-mass-delete", reason)
        notify(f"Sync paused: {reason}. Check logs/sync.log")
        creates, updates, deletes = [], [], []

    if cal_id:
        apply(service, cal_id, creates, updates, dupes + deletes, dry_run)
    if not dry_run and not reason:
        state["last_success"] = now.isoformat()
        state["prev_desired"] = len(desired)
        save_state(state)
    log.info("done%s", " (dry run, nothing written)" if dry_run else "")


def setup_logging(verbose: bool) -> None:
    LOG_DIR.mkdir(exist_ok=True)
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s")
    fh = logging.handlers.RotatingFileHandler(LOG_DIR / "sync.log", maxBytes=1_000_000, backupCount=3)
    fh.setFormatter(fmt)
    log.addHandler(fh)
    if sys.stdout.isatty():  # under launchd stdout is an unrotated file; sync.log is enough
        sh = logging.StreamHandler(sys.stdout)
        sh.setFormatter(fmt)
        log.addHandler(sh)
    log.setLevel(logging.DEBUG if verbose else logging.INFO)


NETWORK_RETRIES = 3
NETWORK_RETRY_DELAY = 30


def is_transient(exc: BaseException) -> bool:
    """True if the error chain contains a network failure (timeout, DNS, refused connection)."""
    seen = set()
    while exc is not None and id(exc) not in seen:
        seen.add(id(exc))
        if isinstance(exc, (ConnectionError, TimeoutError, socket.gaierror)) \
                or type(exc).__name__ in ("ServerNotFoundError", "TransportError"):
            return True
        exc = exc.__cause__ or exc.__context__
    return False


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--dry-run", action="store_true", help="show the plan without writing to Google")
    p.add_argument("--allow-mass-delete", action="store_true", help="bypass the deletion safety limits")
    p.add_argument("-v", "--verbose", action="store_true")
    args = p.parse_args()
    setup_logging(args.verbose)

    with open(LOCK_PATH, "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log.warning("another sync is running; exiting")
            return
        for attempt in range(NETWORK_RETRIES + 1):
            try:
                run(args.dry_run, args.allow_mass_delete)
                return
            except Exception as e:
                # Right after the Mac wakes, Wi-Fi is often not up yet; wait instead of failing.
                if is_transient(e) and attempt < NETWORK_RETRIES:
                    log.warning("network error (%s); retrying in %ds", e.__class__.__name__, NETWORK_RETRY_DELAY)
                    time.sleep(NETWORK_RETRY_DELAY)
                    continue
                log.exception("sync failed")
                notify(f"Sync failed: {e}. Check logs/sync.log")
                sys.exit(1)
            except SystemExit as e:
                log.exception("sync failed")
                notify(f"Sync failed: {e}. Check logs/sync.log")
                sys.exit(1)


if __name__ == "__main__":
    main()
