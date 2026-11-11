# icloud-gcal-sync

Two-way sync between **Apple Calendar (iCloud)** and a dedicated **Google calendar**, running in the background on your Mac.

- Events you add in Apple Calendar show up in Google within seconds, where Google-only tools can see them: AI assistants with a Google Calendar connector, scheduling links, shared Google calendars.
- Events created in that Google calendar, for example by an AI assistant, are written back into an iCloud calendar, so they are on all your Apple devices.

> 中文简介：在 Mac 后台运行，把苹果 iCloud 日历和一个专用的 Google 日历（默认叫 “iCloud Sync”）双向同步。苹果日历里的日程几秒内出现在 Google；在这个 Google 日历里新建的日程（例如 AI 助手建的）会写回 iCloud 的 “From Google” 日历。适合主要用苹果日历，又想让只支持 Google 日历的工具能读写日程的人。

## How it works

```
Apple Calendar ──change notification──▶ ┐
                                        │  icloud-gcal-sync (launchd agent)
Google Calendar ──poll every 60 s─────▶ ┘  SQLite: pairings + per-side hashes
```

- **Apple side: EventKit.** No app-specific password. macOS asks once for calendar access. Only calendars of your iCloud account are read or written.
- **Google side: Calendar API**, incremental sync, polled every 60 seconds. The OAuth scope is `calendar.app.created`: the tool can only touch the calendar it created itself, never your other Google calendars.
- **Apple → Google.** Every event in the sync window (30 days back to 365 days ahead) gets a copy in the Google calendar. Recurring events are copied as individual occurrences.
- **Google → Apple.** An event created in the Google calendar is created in the iCloud calendar *From Google*.
- **Edits and deletions** of single events travel in both directions. If both copies were edited between two syncs, the newer edit wins. An edit beats a deletion.
- **Loop prevention.** For each pair the tool remembers a hash of what each side looked like when they last agreed. A change notification caused by its own write matches the hash and is ignored.

### Safety

- Nothing is written unless both sides were read successfully.
- If one run would delete many events (more than 50 Google copies after a sudden drop on the Apple side, or more than 10 Apple events), the run changes nothing and shows a notification. Run `icloud-gcal-sync sync --allow-mass-delete` if the deletion is intended.
- If you delete the Google calendar, the tool creates a new one and copies everything again. It does not delete your Apple events.
- Google copies of Apple events carry no reminders, so you are not alerted twice.
- Events outside the sync window are left alone.

### Limitations

- **Recurring events are one-way.** Occurrences are copied from Apple to Google. Editing or deleting such a copy in Google does not change the Apple event, and a deleted copy comes back. Recurring events created in Google are not copied to Apple.
- Only title, time, location, notes and free/busy are synced. Guests, attachments and alerts are not.
- If you added your Google account to Apple Calendar, hide the *iCloud Sync* calendar there (uncheck it in the sidebar), or you will see every event twice.
- Apple Reminders are not synced.
- Your Mac must be awake.

## Setup (≈15 minutes)

Requires macOS 14 or later and Xcode or the Xcode Command Line Tools (for `swift build`).

```bash
git clone https://github.com/<you>/icloud-gcal-sync.git
cd icloud-gcal-sync
```

### 1. Google OAuth client

1. Open the [Google Cloud Console](https://console.cloud.google.com/projectcreate) and create a project.
2. Enable the [Google Calendar API](https://console.cloud.google.com/apis/library/calendar-json.googleapis.com).
3. Under [Google Auth Platform](https://console.cloud.google.com/auth/overview), click **Get started**:
   - **Audience → Internal** if you are on Google Workspace.
   - Otherwise choose **External**, then go to **Audience** and click **Publish app**. Apps left in *Testing* mode get refresh tokens that expire after 7 days, and syncing then stops.
     Publishing requires an app name, a support email, a home page and a privacy policy link on the **Branding** page. You can use this repository's URL and the link to its [PRIVACY.md](PRIVACY.md). Do not upload a logo: that starts Google's verification process, which a personal installation does not need.
4. Go to [Clients](https://console.cloud.google.com/auth/clients) → **Create client** → **Desktop app** → **Download JSON**. Leave the file in your Downloads folder.

### 2. Install and sign in

```bash
scripts/install.sh                  # builds, signs (see "Signing" below), installs the background agent and starts it
```

macOS asks once whether *icloud-gcal-sync* may access your calendars. Allow full access.

A calendar icon appears in the menu bar. Click it, choose **Choose Google Credentials (JSON)…** and pick the file you downloaded. A browser opens for the Google sign-in; when you have agreed, the first sync starts.

Tell your AI assistant to create events in the **iCloud Sync** calendar, not in your primary Google calendar. The tool cannot see the primary calendar.

### The menu bar icon

| Item | What it does |
|---|---|
| Status lines | What the sync is doing now, when it last succeeded, how many events are paired, and what to do if something needs your attention |
| **Sync Now** | Runs a sync immediately instead of waiting for the next change or poll |
| **Refresh** | Re-reads `config.json` and compares against the whole Google calendar, not only the changes since the last sync. Use it after editing the configuration or if the two sides look out of step |
| **Choose Google Credentials (JSON)…** | Installs the OAuth client file and starts the Google sign-in |
| **Sign In to Google…** | Shown when the sign-in has expired or was not finished |
| **Open Log** | Opens `sync.log` |

The icon changes to a calendar with an exclamation mark when something needs attention. To run without an icon, start the program with `run --headless` and set Google up from the command line: save the client file as `~/Library/Application Support/icloud-gcal-sync/credentials.json` and run `icloud-gcal-sync auth`.

### Signing

macOS remembers the calendar permission against the program's code signature. An unsigned or ad-hoc signed build gets a new identity every time it is compiled and would lose the permission on every update. `scripts/build.sh` therefore creates, once, a self-signed certificate in its own keychain file under `~/Library/Application Support/icloud-gcal-sync/` and signs every build with it. Your login keychain is not touched.

## Configuration

Optional. Create `~/Library/Application Support/icloud-gcal-sync/config.json`; see `config.example.json`. Choose **Refresh** in the menu bar after changing it.

| Key | Default | Meaning |
|---|---|---|
| `apple_source` | `iCloud` | Account in Apple Calendar whose calendars are synced |
| `icloud_calendars` | `[]` (all) | Names of the calendars to copy to Google |
| `apple_target_calendar` | `From Google` | iCloud calendar that receives events created in Google |
| `google_calendar_name` | `iCloud Sync` | Name of the Google calendar to create |
| `past_days` / `future_days` | 30 / 365 | Sync window |
| `max_deletes_per_run` | 50 | Mass-deletion guard for Google copies |
| `max_apple_deletes_per_run` | 10 | Mass-deletion guard for Apple events |
| `google_poll_seconds` | 60 | How often Google is checked for changes |
| `conflict_policy` | `newest` | `newest`, or `apple` to let the Apple copy always win |

## Operating it

```bash
icloud-gcal-sync status             # last successful sync, number of paired events
icloud-gcal-sync calendars          # which Apple calendars are synced
icloud-gcal-sync sync --dry-run     # show what a sync would change
```

The installed binary is `~/Library/Application Support/icloud-gcal-sync/bin/icloud-gcal-sync`. Run from a terminal, `calendars` and `sync` use the terminal's own calendar permission, which macOS asks for separately from the background agent's.

- Logs: `~/Library/Application Support/icloud-gcal-sync/logs/sync.log`
- Uninstall: `scripts/uninstall.sh` (add `--purge` to also remove the configuration, token and database). Then remove *icloud-gcal-sync* under System Settings → Privacy & Security → Calendars.
- Tests: `swift test`, and `scripts/test-scripts.sh` for the build scripts.

## Upgrading from the Python version

The Python one-way version is kept in `legacy/` for reference.

1. Stop the old agent: `launchctl bootout gui/$(id -u)/com.$(whoami).icloud-gcal-sync && rm ~/Library/LaunchAgents/com.$(whoami).icloud-gcal-sync.plist`
2. Copy `secrets/credentials.json` and `secrets/token.json` to `~/Library/Application Support/icloud-gcal-sync/`. The token is reused; you do not need to sign in again.
3. Run `scripts/install.sh`.

The existing Google copies are recognized by their event UID and adopted, not deleted and recreated. The iCloud app-specific password is no longer needed; you can revoke it at [account.apple.com](https://account.apple.com).

## License

MIT
