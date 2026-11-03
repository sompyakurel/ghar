"""Calendar proxy for Som's TV dashboard — v1.

Why this file exists:
- The TV app cannot fetch Google's ICS feed directly. Browsers block
  cross-site reads unless Google sends CORS headers, and Google's ICS
  feed usually does not. A server does not have that browser block, so
  this backend fetches the ICS, parses it, and returns simple JSON.
- The secret ICS URL lives ONLY as a Fly secret (CALENDAR_ICS_URL).
  It never goes in this file, never in the TV app, and never in chat.
- What the TV gets back is deliberately small: date, time, title only,
  plus a holiday tag (US / NP / null) so the tile can mark holidays.
  No descriptions, no locations, no attendees, no past events.
  Anyone who found the /calendar URL could see those next events, so
  we keep the payload to the minimum the tile actually shows.

v1.1 holidays (2026-10-31, Som's choice: marked, both US and Nepal):
- The backend also fetches Google's public holiday ICS feeds (no secret,
  safe to hardcode): US en.usa#holiday@group.v.calendar.google.com and
  Nepal en.np#holiday@group.v.calendar.google.com, merged with personal
  events, sorted together, capped at 5 combined. A holiday-feed failure
  is ignored (personal calendar still returns); a personal-feed failure
  still returns 502. Duplicate date+title holidays (e.g. Christmas Day
  in both feeds) are merged into one line with both flags.

v1 limitation, stated plainly:
- Recurring events (RRULE) are NOT expanded yet. A recurring event
  shows only on its first DTSTART date; after that date passes it drops
  out until recurrence expansion is added. One-off events work fully.
- All dates/times are converted to America/New_York for display.
"""

import os
import re
import urllib.request
from datetime import date, datetime, time as dt_time
from zoneinfo import ZoneInfo

from fastapi import APIRouter
from fastapi.responses import JSONResponse

router = APIRouter()

NY = ZoneInfo("America/New_York")
ICS_URL = os.environ.get("CALENDAR_ICS_URL", "")

# Public holiday feeds — no secret, safe to hardcode. Calendar IDs verified:
# US: en.usa#holiday@group.v.calendar.google.com
# Nepal: en.np#holiday@group.v.calendar.google.com
HOLIDAY_URLS = {
    "US": "https://calendar.google.com/calendar/ical/en.usa%23holiday%40group.v.calendar.google.com/public/basic.ics",
    "NP": "https://calendar.google.com/calendar/ical/en.np%23holiday%40group.v.calendar.google.com/public/basic.ics",
}


def _unescape(text: str) -> str:
    """ICS escapes: \\, is a comma, \\; is a semicolon, \\n is a newline."""
    return (
        text.replace("\\n", " ")
        .replace("\\,", ",")
        .replace("\\;", ";")
        .replace("\\\\", "\\")
        .strip()
    )


def _parse_dtstart(params: str, value: str):
    """Return (date, time-or-None, all_day) in America/New_York.

    Handles:
    - DATE:        20261101
    - UTC:         20261101T090000Z
    - With TZID:   DTSTART;TZID=America/New_York:20261101T090000
    - No zone:     assumed America/New_York (Google usually gives a zone)
    """
    value = value.strip()
    if len(value) == 8 and value.isdigit():
        # All-day DATE value.
        d = datetime.strptime(value, "%Y%m%d").date()
        return d, None, True

    tz = NY
    m = re.search(r"TZID=([^;:]+)", params)
    if m:
        try:
            tz = ZoneInfo(m.group(1))
        except Exception:
            tz = NY

    if value.endswith("Z"):
        dt = datetime.strptime(value, "%Y%m%dT%H%M%SZ").replace(
            tzinfo=ZoneInfo("UTC")
        )
    else:
        dt = datetime.strptime(value, "%Y%m%dT%H%M%S").replace(tzinfo=tz)

    local = dt.astimezone(NY)
    return local.date(), local.time(), False


def _format_time(t):
    """9:00 AM, not 09:00 — matches the TV tile's existing style."""
    if t is None:
        return None
    return t.strftime("%I:%M %p").lstrip("0")


def parse_ics(ics_text: str, today: date, limit=None, holiday=None):
    """Parse ICS text into [{date, time, title, holiday}] for today onward.

    holiday is None for personal events, or "US" / "NP" for holiday feeds.
    The returned holiday field is always a list: [] or ["US"] / ["NP"].
    limit=None means no cap here — the caller caps after merging feeds.
    """
    # Unfold: a line starting with a space/tab continues the previous line.
    unfolded = []
    for line in ics_text.splitlines():
        if line and line[0] in (" ", "\t") and unfolded:
            unfolded[-1] += line[1:]
        else:
            unfolded.append(line)

    events = []
    in_event = False
    current = {}
    for line in unfolded:
        if line == "BEGIN:VEVENT":
            in_event = True
            current = {}
        elif line == "END:VEVENT":
            in_event = False
            if "start" in current and "title" in current:
                d, t, _all_day = current["start"]
                if d >= today:
                    events.append(
                        {
                            "date": d.isoformat(),
                            "time": _format_time(t),
                            "title": current["title"],
                            "holiday": [holiday] if holiday else [],
                            "_sort": (d.isoformat(), t.isoformat() if t else "00:00"),
                        }
                    )
            current = {}
        elif in_event:
            if ":" not in line:
                continue
            params, value = line.split(":", 1)
            key = params.split(";", 1)[0]
            if key == "DTSTART":
                try:
                    current["start"] = _parse_dtstart(params, value)
                except Exception:
                    pass
            elif key == "SUMMARY":
                current["title"] = _unescape(value)

    events.sort(key=lambda e: e["_sort"])
    for e in events:
        del e["_sort"]
    if limit is not None:
        return events[:limit]
    return events


def _fetch_ics(url: str):
    req = urllib.request.Request(url, headers={"User-Agent": "Ghar-TV-Calendar/1.0"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        return resp.read().decode("utf-8", errors="ignore")


def _merge_events(*event_lists):
    """Merge feeds, sort together, dedupe same date+title holidays.

    A duplicate keeps the first entry, but unions holiday flags, so
    Christmas Day (in both US and Nepal feeds) shows once with both.
    """
    merged = {}
    for events in event_lists:
        for e in events:
            key = (e["date"], e["title"].lower())
            if key in merged:
                existing = merged[key]
                for flag in e.get("holiday", []):
                    if flag not in existing["holiday"]:
                        existing["holiday"].append(flag)
            else:
                merged[key] = dict(e)
    result = sorted(
        merged.values(),
        key=lambda e: (e["date"], e["time"] or "00:00"),
    )
    return result


@router.get("/calendar")
def calendar_events():
    """Next 5 events as JSON: personal + US + Nepal holidays, marked."""
    if not ICS_URL:
        return JSONResponse(
            status_code=503,
            content={"events": [], "error": "calendar not configured"},
            headers={"Access-Control-Allow-Origin": "*"},
        )
    try:
        ics_text = _fetch_ics(ICS_URL)
    except Exception:
        return JSONResponse(
            status_code=502,
            content={"events": [], "error": "could not fetch calendar"},
            headers={"Access-Control-Allow-Origin": "*"},
        )

    today = datetime.now(NY).date()
    personal = parse_ics(ics_text, today)

    # Holidays are best-effort: if a holiday feed fails, skip it,
    # don't fail the whole tile.
    holiday_lists = []
    for country, url in HOLIDAY_URLS.items():
        try:
            holiday_lists.append(parse_ics(_fetch_ics(url), today, holiday=country))
        except Exception:
            continue

    events = _merge_events(personal, *holiday_lists)[:5]
    return JSONResponse(
        content={"events": events},
        headers={"Access-Control-Allow-Origin": "*"},
    )
