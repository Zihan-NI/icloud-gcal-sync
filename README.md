# icloud-gcal-sync

One-way sync from **iCloud Calendar → Google Calendar**, running on your Mac every 5 minutes.

You add events in Apple Calendar as usual. They show up in a dedicated Google calendar, where Google-only tools can see them: AI assistants with a Google Calendar connector, scheduling links, shared Google calendars, and so on.

> 中文简介：把苹果 iCloud 日历单向同步到 Google 日历（一个专用的 “iCloud Sync” 日历），在 Mac 上每 5 分钟自动运行。适合主要用苹果日历，但又需要让只支持 Google 日历的工具（例如 AI 助手）看到日程的人。

## How it works

- Reads your iCloud calendars over **CalDAV**, using an app-specific password stored in the macOS Keychain.
- Expands recurring events into single occurrences. EXDATEs and edited occurrences are handled.
- Writes them into a **new Google calendar that the tool creates**. Your existing Google calendars are never touched.
- Each Google copy carries a hidden key and content hash, so the Google calendar itself is the sync state. There is no local database. Each run diffs the two sides and applies creates, updates and deletes.
- The OAuth scope is `calendar.app.created`, so the tool can only manage calendars it created itself.

### Safety

- If iCloud fails or a configured calendar is missing, the run stops before writing anything to Google.
- If iCloud suddenly returns far fewer events than last time, the run pauses and shows a macOS notification. This guards against wiping your copies on a bad fetch. Run with `--allow-mass-delete` if the drop is real.
- A malformed event is skipped, and its existing Google copy is kept.
- Google copies have no reminders, so you don't get every alert twice.
- Events outside the sync window (default: 30 days back to 365 days ahead) are left alone.

### Limitations

- **One-way only.** Edits made in Google are overwritten the next time the iCloud event changes.
- Apple **Reminders** are not synced, because modern Reminders aren't available over CalDAV.
- Your Mac must be awake for syncing to run.

## Setup (≈15 minutes)

Requires macOS and Python 3.10 or later.

```bash
git clone https://github.com/<you>/icloud-gcal-sync.git ~/calendar_sync
cd ~/calendar_sync
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
mkdir -m 700 secrets
```

### 1. iCloud app-specific password

Go to [account.apple.com](https://account.apple.com) → **Sign-In and Security** → **App-Specific Passwords** → generate one.

### 2. Google OAuth client

1. Open the [Google Cloud Console](https://console.cloud.google.com/projectcreate) and create a project.
2. Enable the [Google Calendar API](https://console.cloud.google.com/apis/library/calendar-json.googleapis.com).
3. Under [Google Auth Platform](https://console.cloud.google.com/auth/overview), click **Get started**:
   - **Audience → Internal** if you are on Google Workspace.
   - Otherwise choose **External**, then go to **Audience** and click **Publish app**. Apps left in *Testing* mode get refresh tokens that expire after 7 days, and syncing then stops silently.
4. Go to [Clients](https://console.cloud.google.com/auth/clients) → **Create client** → **Desktop app** → **Download JSON**.
5. Save the file as `secrets/credentials.json`.

### 3. Authorize and run

```bash
.venv/bin/python setup_auth.py     # Apple ID + app password, then a browser opens for Google
.venv/bin/python sync.py --dry-run # preview what would be created
.venv/bin/python sync.py           # first real sync
./install_launchd.sh               # run every 5 minutes (pass seconds to change, e.g. ./install_launchd.sh 600)
```

**Apple ID tip:** use your Apple ID email. If your Apple ID is a phone number, enter it as digits with the country code and no `+` (e.g. `8613800000000`).

## Configuration

`setup_auth.py` creates `config.json`. See `config.example.json` for the format.

| Key | Default | Meaning |
|---|---|---|
| `icloud_calendars` | `[]` (all) | Names of the iCloud calendars to sync |
| `google_calendar_name` | `iCloud Sync` | Name of the Google calendar to create |
| `past_days` / `future_days` | 30 / 365 | Sync window |
| `max_deletes_per_run` | 50 | Threshold for the mass-deletion guard |

## Operating it

- Logs are written to `logs/sync.log`.
- To uninstall: `launchctl bootout gui/$(id -u)/com.$(whoami).icloud-gcal-sync && rm ~/Library/LaunchAgents/com.$(whoami).icloud-gcal-sync.plist`
- To run the tests: `.venv/bin/pip install pytest && .venv/bin/python -m pytest -q tests`

`config.json`, `secrets/` and `logs/` contain personal data and are git-ignored. Keep it that way.

## License

MIT
