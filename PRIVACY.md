# Privacy policy

icloud-gcal-sync is a program you build and run on your own Mac. There is no service operated by its authors: no server, no account, no analytics, no telemetry.

## What it accesses

- **Apple Calendar**, through macOS EventKit, after you grant calendar access. It reads the calendars of the account you configure (by default iCloud) and writes to them only to apply changes that were made in the Google calendar described below.
- **One Google calendar** that the tool creates itself (by default "iCloud Sync"), through the Google Calendar API. The OAuth scopes are `calendar.app.created` and `calendar.calendarlist.readonly`: the tool cannot read or change events in any other Google calendar.

## Where your data goes

Event data moves only between your Mac, Apple's calendar service (through macOS, as with any calendar app) and Google's Calendar API, using an OAuth client that you create in your own Google Cloud project. Nothing is sent to the authors of this tool or to any other party.

## What is stored on your Mac

Everything is kept in `~/Library/Application Support/icloud-gcal-sync/`, readable only by your user account:

- `credentials.json` and `token.json`: your Google OAuth client and the token that lets the tool reach the one calendar it created.
- `state.sqlite`: which Apple event corresponds to which Google event, a hash of each, and a copy of the events in the Google calendar (title, time, location, notes).
- `logs/`: what the tool did. Log lines include event titles and start times.
- `signing.keychain-db`: a self-signed certificate used only to sign the locally built program.

## Removing your data

Run `scripts/uninstall.sh --purge` to delete the folder above. Delete the Google calendar in Google Calendar if you no longer want the copies. To withdraw the tool's access, remove it at <https://myaccount.google.com/permissions> and under System Settings → Privacy & Security → Calendars.

## Contact

Questions and reports: open an issue in the project's GitHub repository.
