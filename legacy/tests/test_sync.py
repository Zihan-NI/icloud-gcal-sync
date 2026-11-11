import datetime as dt

import pytest

import sync

TZ = sync.LOCAL_TZ
WIN_START = dt.datetime(2026, 10, 1, tzinfo=TZ)
WIN_END = dt.datetime(2027, 1, 1, tzinfo=TZ)


def ics(*events: str) -> str:
    return "BEGIN:VCALENDAR\nVERSION:2.0\n" + "\n".join(events) + "\nEND:VCALENDAR\n"


WEEKLY = """BEGIN:VEVENT
UID:class
DTSTART;TZID=America/New_York:20261102T100000
DTEND;TZID=America/New_York:20261102T111500
RRULE:FREQ=WEEKLY;COUNT=4
EXDATE;TZID=America/New_York:20261109T100000
SUMMARY:Econ
LOCATION:Gasson 100
END:VEVENT
BEGIN:VEVENT
UID:class
RECURRENCE-ID;TZID=America/New_York:20261116T100000
DTSTART;TZID=America/New_York:20261116T130000
DTEND;TZID=America/New_York:20261116T140000
SUMMARY:Econ (moved)
END:VEVENT"""


def test_recurring_expansion_exdate_and_override():
    out = sync.expand_ics(ics(WEEKLY), "c1", WIN_START, WIN_END)
    summaries = sorted((b["start"]["dateTime"], b["summary"]) for b in out.values())
    assert summaries == [
        ("2026-11-02T10:00:00-05:00", "Econ"),
        ("2026-11-16T13:00:00-05:00", "Econ (moved)"),
        ("2026-11-23T10:00:00-05:00", "Econ"),
    ]
    # Overridden occurrence keyed by its ORIGINAL start, so moving it is an update, not delete+create.
    assert "c1|class|2026-11-16T15:00:00+00:00" in out


def test_one_off_event_key_stable_when_moved():
    a = sync.expand_ics(ics("BEGIN:VEVENT\nUID:x\nDTSTART:20261120T150000Z\nDTEND:20261120T160000Z\nSUMMARY:A\nEND:VEVENT"),
                        "c1", WIN_START, WIN_END)
    b = sync.expand_ics(ics("BEGIN:VEVENT\nUID:x\nDTSTART:20261121T150000Z\nDTEND:20261121T160000Z\nSUMMARY:A\nEND:VEVENT"),
                        "c1", WIN_START, WIN_END)
    assert list(a) == list(b) == ["c1|x"]
    assert sync.body_hash(a["c1|x"]) != sync.body_hash(b["c1|x"])


def test_all_day_and_missing_dtend():
    out = sync.expand_ics(ics("BEGIN:VEVENT\nUID:d\nDTSTART;VALUE=DATE:20261120\nSUMMARY:Trip\nEND:VEVENT"),
                          "c1", WIN_START, WIN_END)
    body = out["c1|d"]
    assert body["start"] == {"date": "2026-11-20"}
    assert body["end"] == {"date": "2026-11-21"}


def test_floating_time_gets_local_zone_and_duration():
    out = sync.expand_ics(ics("BEGIN:VEVENT\nUID:f\nDTSTART:20261120T090000\nDURATION:PT90M\nSUMMARY:F\nEND:VEVENT"),
                          "c1", WIN_START, WIN_END)
    body = out["c1|f"]
    start = dt.datetime.fromisoformat(body["start"]["dateTime"])
    end = dt.datetime.fromisoformat(body["end"]["dateTime"])
    assert start.utcoffset() is not None
    assert end - start == dt.timedelta(minutes=90)


def test_cancelled_and_out_of_window_skipped():
    out = sync.expand_ics(ics(
        "BEGIN:VEVENT\nUID:c\nDTSTART:20261120T150000Z\nSTATUS:CANCELLED\nSUMMARY:C\nEND:VEVENT",
        "BEGIN:VEVENT\nUID:old\nDTSTART:20250101T150000Z\nSUMMARY:Old\nEND:VEVENT",
    ), "c1", WIN_START, WIN_END)
    assert out == {}


def _g(ev_id, key, body):
    return {"id": ev_id, "start": body["start"],
            "extendedProperties": {"private": {sync.KEY_PROP: key, sync.HASH_PROP: sync.body_hash(body)}}}


ALL = lambda ev: True  # noqa: E731


def test_plan_create_update_delete_and_dedupe():
    b1 = {"summary": "a", "start": {"date": "2026-11-20"}, "end": {"date": "2026-11-21"}}
    b2 = {"summary": "b", "start": {"date": "2026-11-22"}, "end": {"date": "2026-11-23"}}
    b2_new = dict(b2, summary="b2")
    b3 = {"summary": "c", "start": {"date": "2026-11-24"}, "end": {"date": "2026-11-25"}}
    desired = {"k1": b1, "k2": b2_new, "k4": b3}
    existing = {
        "k1": [_g("g1", "k1", b1), _g("g1dup", "k1", b1)],
        "k2": [_g("g2", "k2", b2)],
        "k3": [_g("g3", "k3", b3)],
    }
    creates, updates, dupes, deletes = sync.plan(desired, existing, ALL)
    assert creates == [("k4", b3)]
    assert updates == [("g2", "k2", b2_new)]
    assert dupes == ["g1dup"]
    assert deletes == ["g3"]


def test_plan_noop_when_unchanged():
    b = {"summary": "a", "start": {"date": "2026-11-20"}, "end": {"date": "2026-11-21"}}
    assert sync.plan({"k": b}, {"k": [_g("g", "k", b)]}, ALL) == ([], [], [], [])


def test_plan_only_deletes_inside_window_but_matches_outside():
    b = {"summary": "a", "start": {"date": "2026-11-20"}, "end": {"date": "2026-11-21"}}
    old = {"summary": "a", "start": {"date": "2025-01-01"}, "end": {"date": "2025-01-02"}}
    existing = {"moved": [_g("gm", "moved", old)], "history": [_g("gh", "history", old)]}
    in_window = lambda ev: ev["start"]["date"] >= "2026-01-01"  # noqa: E731
    creates, updates, dupes, deletes = sync.plan({"moved": b}, existing, in_window)
    # Event moved into the window from outside: update its old copy, don't orphan it.
    assert creates == [] and updates == [("gm", "moved", b)]
    # Past history outside the window is left alone.
    assert deletes == []


def test_plan_protected_keys_not_deleted():
    b = {"summary": "a", "start": {"date": "2026-11-20"}, "end": {"date": "2026-11-21"}}
    existing = {"c1|bad": [_g("g1", "c1|bad", b)], "c1|bad|2026-11-20": [_g("g2", "c1|bad|2026-11-20", b)],
                "c1|badx": [_g("g3", "c1|badx", b)], "c2|y": [_g("g4", "c2|y", b)]}
    _, _, _, deletes = sync.plan({}, existing, ALL, ["c1|bad"])
    assert sorted(deletes) == ["g3", "g4"]
    _, _, _, deletes = sync.plan({}, existing, ALL, ["c1|"])  # whole calendar unparseable
    assert deletes == ["g4"]


def test_guard_without_history_uses_net_count():
    many = [object()] * 300
    assert sync.deletion_guard({"k": 1}, many, many, 50, None) is None        # replace, not loss
    assert sync.deletion_guard({"k": 1}, [], many, 50, None) is not None      # real mass delete
    assert sync.deletion_guard({}, [], [object()], 50, 10) is not None        # iCloud came back empty


def test_guard_with_history_survives_half_finished_run():
    desired = {i: 1 for i in range(400)}
    many = [object()] * 356
    # Previous run created the new copies then crashed; now only deletes remain.
    assert sync.deletion_guard(desired, [], many, 50, prev_desired=400) is None
    # A calendar's 300 events vanished from iCloud.
    assert sync.deletion_guard({i: 1 for i in range(100)}, [], many, 50, prev_desired=400) is not None


def test_uid_of_unfolds_long_uids():
    uid = "040000008200E00074C5B7101A82E008" * 4
    text = f"BEGIN:VEVENT\r\nUID:{uid[:70]}\r\n {uid[70:]}\r\nEND:VEVENT"
    assert sync._uid_of(text) == uid
    assert sync._uid_of("UID;X-FOO=1:abc\n") == "abc"


def test_floating_recurring_key_independent_of_local_tz(monkeypatch):
    src = ics("BEGIN:VEVENT\nUID:f\nDTSTART:20261102T090000\nDTEND:20261102T100000\n"
              "RRULE:FREQ=DAILY;COUNT=3\nSUMMARY:F\nEND:VEVENT")
    keys_ny = set(sync.expand_ics(src, "c1", WIN_START, WIN_END))
    monkeypatch.setattr(sync, "LOCAL_TZ", sync.ZoneInfo("Asia/Shanghai"))
    keys_sh = set(sync.expand_ics(src, "c1", WIN_START, WIN_END))
    assert keys_ny == keys_sh == {f"c1|f|2026-11-0{d}T09:00:00" for d in (2, 3, 4)}


def test_malformed_event_raises_so_caller_can_protect_it():
    with pytest.raises(Exception):
        sync.expand_ics(ics("BEGIN:VEVENT\nUID:bad\nSUMMARY:no start\nEND:VEVENT"), "c1", WIN_START, WIN_END)
    assert sync._uid_of("BEGIN:VEVENT\r\nUID:bad\r\nEND:VEVENT") == "bad"


def test_window_filter_consistent_between_sides():
    # An all-day event on the window's first day must be "in window" on both sides.
    body = {"start": {"date": "2026-10-01"}}
    assert sync.google_event_start(body) == sync.start_instant(dt.date(2026, 10, 1)) == WIN_START


def test_is_transient_follows_cause_chain():
    try:
        try:
            raise TimeoutError("timed out")
        except TimeoutError as inner:
            raise RuntimeError("wrapped") from inner
    except RuntimeError as e:
        assert sync.is_transient(e)
    assert not sync.is_transient(FileNotFoundError("credentials.json"))
    assert not sync.is_transient(ValueError("bad data"))
