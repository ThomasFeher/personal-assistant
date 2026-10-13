---
name: calendar
description: Show the user's ICS calendar entries for today, a given day, or a range of consecutive days from the configured calendar feed. Use when the user asks about their calendar, upcoming appointments, or the schedule of the coming days.
---

# Calendar

`config.yaml` in the project root stores the feed URL as `calendar.url`.
The parser bundled with this skill,
`.opencode/skills/calendar/scripts/calendar_today.py`, fetches it
automatically (with a browser-like User-Agent, because OWA redirects
unauthenticated clients to an auth error page) and prints the entries for
the requested day(s): all-day entries first, then chronologically, with
location, organizer, and status. A bash/gawk companion,
`calendar_today.sh`, is in the same directory for parsing ICS from a file
or stdin.

## Usage

Run from the project root:

* today (default):
  `python3 .opencode/skills/calendar/scripts/calendar_today.py`
* a specific day:
  `python3 .opencode/skills/calendar/scripts/calendar_today.py --date YYYY-MM-DD`
* several consecutive days (e.g. "check the calendar for the next days"
  during standup):
  `python3 .opencode/skills/calendar/scripts/calendar_today.py --date YYYY-MM-DD --days N`
  One fetch covers all requested days. Use `--date <tomorrow>` to skip
  today.

Show the printed entries to the user as-is.

## Fallback

If the script reports a fetch error, the URL may no longer be fetchable
directly from scripts. In that case:

1. fetch the `calendar.url` value with the `webfetch` tool,
2. save the result to a temp file,
3. re-run the script with `--file <that-file>` (plus `--date`/`--days` as
   needed).
