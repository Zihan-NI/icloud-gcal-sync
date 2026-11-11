# icloud-gcal-sync

Two-way sync between **Apple Calendar (iCloud)** and a dedicated **Google calendar**, running quietly in the menu bar of your Mac.

Keep your events in Apple Calendar, and let everything that only speaks Google Calendar work with them too: AI assistants with a Google Calendar connector, scheduling links, shared Google calendars. Events those tools create come back to iCloud and appear on all your Apple devices.

> 中文简介：在 Mac 菜单栏后台运行，把苹果 iCloud 日历和一个专用的 Google 日历（默认叫 “iCloud Sync”）双向同步。苹果日历里的日程几秒内出现在 Google；在这个 Google 日历里新建的日程（例如 AI 助手通过 Google 日历连接器创建的）会写回 iCloud 的 “From Google” 日历。适合主要用苹果日历，又想让只支持 Google 日历的工具能读写日程的人。

## Features

- **Two-way.** Create, edit or delete an event on either side and the other side follows.
- **Fast.** Changes in Apple Calendar reach Google within seconds; Google is checked once a minute.
- **Made for AI assistants.** An assistant with a Google Calendar connector can read your iCloud schedule and add to it, from any device.
- **A menu bar icon** shows what the sync is doing and offers Sync Now, Refresh and the Google sign-in.
- **Private by design.** Your events travel only between your Mac, Apple and Google, through a Google OAuth client that you own. No server, no account, no telemetry. See [PRIVACY.md](PRIVACY.md).
- **Narrow permissions.** On Google the tool can touch only the one calendar it created, never your other calendars. On the Mac it uses the system's calendar access; no Apple password is stored.
- **Careful with your data.** Nothing is written unless both sides were read successfully, and a run that would delete an unusual number of events stops and asks first.
- **Small.** One native program, no third-party dependencies.

## How it works

```
 Apple Calendar (iCloud)                               Google Calendar
┌──────────────────────┐                           ┌───────────────────┐
│ your iCloud calendars│ ── change notification ─▶ │                   │
│                      │                           │   “iCloud Sync”   │
│ “From Google”        │ ◀── checked every 60 s ── │                   │
└──────────────────────┘                           └───────────────────┘
              ▲                                              ▲
              └────────── icloud-gcal-sync (menu bar) ───────┘
                    SQLite: event pairs + a hash per side
```

- **Apple → Google.** Every event in your iCloud calendars, from 30 days back to a year ahead, has a copy in the Google calendar *iCloud Sync*. Repeating events are copied occurrence by occurrence.
- **Google → Apple.** An event created in *iCloud Sync* is created in the iCloud calendar *From Google*.
- **Edits and deletions** of single events travel in both directions: deleting an event's copy in Google deletes the event in iCloud. If both copies were edited between two syncs, the newer edit wins, and an edit beats a deletion. Repeating events, and events in calendars you can only read, are kept in step from iCloud to Google.
- **Synced fields:** title, time, location, notes and free/busy.
- **No echo.** For each pair of events the tool remembers a hash of what each side looked like when they last agreed. A change that matches the hash is its own write coming back, and is ignored.
- **Guard rails.** A run that would delete more than 10 Apple events, more than 50 Google copies after a sudden drop on the Apple side, or more than 3 events while the other side reads as empty, changes nothing and shows a notification. If you delete the Google calendar, it is created again and refilled; your Apple events are not deleted.

## Install

Requires macOS 14 or later. About 15 minutes, most of it in Google Cloud Console.

### 1. Create a Google OAuth client

The tool talks to Google through a client that belongs to you, so your calendar data goes to nobody else.

1. Open the [Google Cloud Console](https://console.cloud.google.com/projectcreate) and create a project.
2. Enable the [Google Calendar API](https://console.cloud.google.com/apis/library/calendar-json.googleapis.com).
3. Under [Google Auth Platform](https://console.cloud.google.com/auth/overview), click **Get started**:
   - **Audience → Internal** if you are on Google Workspace.
   - Otherwise choose **External**, then go to **Audience** and click **Publish app**, so that the sign-in does not expire after 7 days. Publishing asks for an app name, a support email, a home page and a privacy policy link on the **Branding** page. You can use this repository's URL and the link to its [PRIVACY.md](PRIVACY.md). Do not upload a logo.
4. Go to [Clients](https://console.cloud.google.com/auth/clients) → **Create client** → **Desktop app** → **Download JSON**.

### 2. Install the program

**With the installer.** Download `icloud-gcal-sync-<version>.pkg` from the [Releases page](../../releases). The package is not signed by Apple, so macOS will not open it with a double-click right away. Use either way:

- Double-click it, dismiss the warning, then open **System Settings → Privacy & Security**, scroll down to *Security* and click **Open Anyway**; or
- install it from Terminal:
  ```bash
  installer -pkg ~/Downloads/icloud-gcal-sync-*.pkg -target CurrentUserHomeDirectory
  ```

It installs for your user only and needs no administrator password.

**Or from source** (needs Xcode 16 or later, or the matching Command Line Tools):

```bash
git clone https://github.com/Zihan-NI/icloud-gcal-sync.git
cd icloud-gcal-sync
scripts/install.sh
```

Either way, macOS asks once whether *icloud-gcal-sync* may access your calendars. Allow full access.

### 3. Sign in from the menu bar

A calendar icon appears in the menu bar and a short setup guide opens. Choose the JSON file from step 1; your browser opens for the Google sign-in. When you have agreed, the first sync starts.

Two things to do once:

- Tell your AI assistant to create events in the **iCloud Sync** calendar. It is the one calendar the tool can see on Google.
- If your Google account is also added to Apple Calendar, uncheck **iCloud Sync** in Calendar's sidebar, so that events are not shown twice.

## The menu bar icon

| Item | What it does |
|---|---|
| Status lines | What the sync is doing now, when it last succeeded, how many events are paired, and the reason when something needs attention |
| **Sync Now** | Runs a sync immediately |
| **Refresh** | Re-reads `config.json` and compares against the whole Google calendar, not only the changes since the last sync |
| **Choose Google Credentials (JSON)…** | Installs the OAuth client file and starts the Google sign-in |
| **Sign In to Google…** | Shown when the sign-in has expired or was not finished |
| **Switch Google Account…** | Creates the calendar in another Google account and copies everything there; the calendar in the old account is left as it is |
| **Cancel Sign-In** | Shown while the browser sign-in is waiting |
| **How It Works…** | The rules in five lines. Opens by itself after the first successful sync |
| **Setup Guide…** | The setup steps in short. Opens by itself the first time |
| **Open Log** | Opens `sync.log` |

The icon turns into a calendar with an exclamation mark when something needs attention.

## Configuration

Optional. Create `~/Library/Application Support/icloud-gcal-sync/config.json` (see `config.example.json`) and choose **Refresh** in the menu.

| Key | Default | Meaning |
|---|---|---|
| `apple_source` | `iCloud` | Account in Apple Calendar whose calendars are synced |
| `icloud_calendars` | `[]` (all) | Names of the calendars to copy to Google |
| `apple_target_calendar` | `From Google` | iCloud calendar that receives events created in Google |
| `google_calendar_name` | `iCloud Sync` | Name of the Google calendar to create |
| `past_days` / `future_days` | 30 / 365 | Sync window |
| `max_deletes_per_run` | 50 | Deletion guard for Google copies |
| `max_apple_deletes_per_run` | 10 | Deletion guard for Apple events |
| `google_poll_seconds` | 60 | How often Google is checked for changes (at least 15) |
| `debounce_seconds` | 5 | How long to wait after an Apple Calendar change, so that a burst of changes is handled once |
| `conflict_policy` | `newest` | `newest`, or `apple` to let the Apple copy always win |

## Command line

Everything the menu does is also available from a terminal, plus a dry run.

```bash
alias icloud-gcal-sync="$HOME/Library/Application Support/icloud-gcal-sync/bin/icloud-gcal-sync"

icloud-gcal-sync status                    # last successful sync, number of paired events
icloud-gcal-sync calendars                 # which Apple calendars are synced
icloud-gcal-sync sync --dry-run            # show what a sync would change
icloud-gcal-sync sync --allow-mass-delete  # apply a sync that the deletion guard paused
icloud-gcal-sync auth                      # Google sign-in without the menu
icloud-gcal-sync run --headless            # run without a menu bar icon
```

Run from a terminal, `calendars` and `sync` use the terminal's own calendar permission, which macOS asks for separately.

- Files: everything is in `~/Library/Application Support/icloud-gcal-sync/` (configuration, Google sign-in, database, `logs/sync.log`).
- Uninstall: `~/Library/Application\ Support/icloud-gcal-sync/bin/uninstall.sh` after installing the package, or `scripts/uninstall.sh` from a source checkout. Add `--purge` to remove the configuration, sign-in and database too. Then remove *icloud-gcal-sync* under System Settings → Privacy & Security → Calendars.

## Project structure

```
Sources/
  SyncCore/          The sync logic, with no I/O of its own
    Models.swift       events, pairs, content hashing
    Planner.swift      decides what has to change, from a snapshot of both sides
    Guards.swift       refuses plans that look like a bad read
    Engine.swift       one cycle: read both sides, plan, check, apply
  AppleCalendar/     EventKit adapter (the only code that touches Apple Calendar)
  GoogleCalendar/    Calendar REST client, OAuth sign-in, token storage
  SyncStorage/       SQLite: event pairs, Google calendar cache, settings
  icloud-gcal-sync/  The program: command line, background loop, menu bar
Tests/               Sync scenarios against in-memory fakes; Google client; storage
scripts/             build, sign, install, package
Support/Info.plist   Embedded in the binary: identity and calendar usage description
legacy/              The original one-way Python version
```

The core is a pure function: given the events on both sides and the stored pairs, `Planner` returns the list of actions. That is what the test suite exercises, with fakes standing in for Apple and Google.

## Building and releasing

```bash
swift test                 # unit and scenario tests
scripts/test-scripts.sh    # build and signing scripts
scripts/build.sh           # dist/icloud-gcal-sync
scripts/package.sh         # dist/icloud-gcal-sync-<version>.pkg
```

**Signing.** macOS remembers the calendar permission against the program's code signature. `scripts/build.sh` and `scripts/package.sh` therefore sign with a self-signed certificate, created once in its own keychain file under `~/Library/Application Support/icloud-gcal-sync/`. Your login keychain is not touched. Releases must always be signed with the same certificate, or users are asked for the permission again after an update: keep `signing.keychain-db` and `signing.keychain.pass` of the machine that builds releases.

## Upgrading from the Python version

The Python one-way version is kept in `legacy/`.

1. Stop the old agent: `launchctl bootout gui/$(id -u)/com.$(whoami).icloud-gcal-sync && rm ~/Library/LaunchAgents/com.$(whoami).icloud-gcal-sync.plist`
2. Copy `secrets/credentials.json` and `secrets/token.json` to `~/Library/Application Support/icloud-gcal-sync/`. The sign-in is reused.
3. Install as described above.

The existing Google copies are recognized by their event UID and adopted where the match is unambiguous; any other copy is replaced by a fresh one. The iCloud app-specific password is no longer needed; you can revoke it at [account.apple.com](https://account.apple.com).

## License

MIT
