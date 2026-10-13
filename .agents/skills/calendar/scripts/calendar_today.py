#!/usr/bin/env python3
"""Print the calendar entries for a day (default: today) from an ICS feed.

The ICS source is chosen in this order of precedence:

1. ``--file ICS_FILE``
2. ``--url URL``
3. the ICS content piped on stdin
4. ``calendar.url`` from ``config.yaml`` in the current directory

When fetching a URL, the request uses a browser-like User-Agent, because
OWA redirects unauthenticated/default clients to an auth error page.  If
the fetch still fails, the personal assistant can fetch the URL with
webfetch and pass the result with ``--file``.

Usage:
    calendar_today.py [--file ICS_FILE | --url URL] [--date YYYY-MM-DD]
                      [--days N]

Prints one block per entry on each of the N consecutive days (default:
only the given day, today if none), chronologically, all-day entries
first.  Warnings go to stderr.  Exit status: 0 on success (also when
there are no entries), 1 on error, 2 on usage error.
"""

from __future__ import annotations

import argparse
import calendar
import re
import sys
import urllib.request
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

DOW = {"MO": 1, "TU": 2, "WE": 3, "TH": 4, "FR": 5, "SA": 6, "SU": 7}
BYDAY_RE = re.compile(r"^([+-]?\d{1,2})?(MO|TU|WE|TH|FR|SA|SU)$", re.IGNORECASE)
DT_RE = re.compile(r"^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$")
UTC_OFFSET_RE = re.compile(r"^UTC([+-])(\d{1,2})(?::?(\d{2}))?$", re.IGNORECASE)
DUR_RE = re.compile(
    r"([-+]?)P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?", re.IGNORECASE
)
WEEKDAYS = (
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
    "Sunday",
)
MS_TZ_ALIASES = {
    "W. Europe Standard Time": "Europe/Berlin",
    "W. Central Europe Standard Time": "Europe/Berlin",
    "Eastern Europe Standard Time": "Europe/Budapest",
    "GTB Standard Time": "Europe/Budapest",
    "FLE Standard Time": "Europe/Helsinki",
    "GMT Standard Time": "Europe/London",
    "GT Standard Time": "Europe/London",
    "Eastern Standard Time": "America/New_York",
    "Central Standard Time": "America/Chicago",
    "Mountain Standard Time": "America/Denver",
    "Pacific Standard Time": "America/Los_Angeles",
}
CANCELED_RE = re.compile(r"^\s*(canceled|cancelled|abgesagt)\s*[:\-]", re.IGNORECASE)

_local_tz = None
_warned_tz: set[str] = set()
MAX_OCCURRENCES = 10_000


def warn(msg: str) -> None:
    print(f"warning: {msg}", file=sys.stderr)


class FetchError(Exception):
    """Raised when an ICS feed cannot be fetched or read."""


FETCH_USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)


def fetch_ics(url: str) -> str:
    req = urllib.request.Request(
        url, headers={"User-Agent": FETCH_USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = resp.read()
    except OSError as e:
        raise FetchError(f"failed to fetch {url}: {e}") from e
    text = data.decode("utf-8", errors="replace")
    if "BEGIN:VCALENDAR" not in text:
        raise FetchError(
            f"content fetched from {url} does not look like an ICS file "
            "(no BEGIN:VCALENDAR); the server may have returned an "
            "error page")
    return text


_TOP_KEY_RE = re.compile(r"^([A-Za-z_][\w-]*)\s*:(.*)$")
_URL_RE = re.compile(r"\burl\s*:\s*['\"]?([^\s'\"]+)")


def read_calendar_url(config_path: str = "config.yaml") -> str | None:
    """Return calendar.url from a simple YAML config (flow or block style)."""
    try:
        with open(config_path, encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return None
    section: str | None = None
    for raw in lines:
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        rest = ""
        if raw[0] not in (" ", "\t"):
            m = _TOP_KEY_RE.match(stripped)
            section = m.group(1) if m else None
            if m:
                rest = m.group(2)
        elif section == "calendar":
            rest = stripped
        else:
            continue
        if section == "calendar" and rest:
            m = _URL_RE.search(rest)
            if m:
                return m.group(1)
    return None


def read_ics(args: argparse.Namespace,
             ap: argparse.ArgumentParser) -> str:
    """Return ICS text from --file, --url, stdin, or config.yaml."""
    if args.file:
        try:
            with open(args.file, encoding="utf-8", errors="replace") as f:
                return f.read()
        except OSError as e:
            raise FetchError(f"cannot read {args.file!r}: {e}") from e
    if args.url:
        return fetch_ics(args.url)
    stdin_text: str | None = None
    if not sys.stdin.isatty():
        stdin_text = sys.stdin.read()
    if stdin_text is not None and stdin_text.strip():
        return stdin_text
    url = read_calendar_url()
    if url:
        return fetch_ics(url)
    if stdin_text is not None:
        return stdin_text
    ap.error("no ICS input: pass --file or --url, set calendar.url in "
             "config.yaml, or pipe the ICS on stdin")


def _detect_local_tz_name() -> str | None:
    import os

    name: str | None = None
    tz_env = os.environ.get("TZ")
    if tz_env and ":" not in tz_env and tz_env.upper() not in ("UTC", "GMT"):
        name = tz_env
    if name is None:
        try:
            target = os.path.realpath("/etc/localtime")
            for prefix in (
                "/usr/share/zoneinfo/",
                "/usr/lib/zoneinfo/",
                "/etc/zoneinfo/",
            ):
                if target.startswith(prefix):
                    name = target[len(prefix):]
                    break
        except OSError:
            pass
    return name


def local_tz():
    global _local_tz
    if _local_tz is None:
        tz = None
        name = _detect_local_tz_name()
        if name:
            try:
                tz = ZoneInfo(name)
            except Exception:
                tz = None
        if tz is None:
            # Fall back to the current fixed UTC offset; DST transitions
            # for other dates are not honored in that case.
            tz = datetime.now().astimezone().tzinfo
        _local_tz = tz
    return _local_tz


def resolve_tz(tzid: str | None):
    t = (tzid or "").strip()
    if not t or t.upper() in ("UTC", "Z"):
        return timezone.utc
    m = UTC_OFFSET_RE.match(t)
    if m:
        secs = int(m.group(2)) * 3600 + int(m.group(3) or 0)
        if m.group(1) == "-":
            secs = -secs
        return timezone(timedelta(seconds=secs))
    name = MS_TZ_ALIASES.get(t, t)
    try:
        return ZoneInfo(name)
    except Exception:
        if t not in _warned_tz:
            _warned_tz.add(t)
            warn(f"unknown timezone id {t!r}; assuming local time")
        return local_tz()


def unfold(lines: list[str]) -> list[str]:
    out: list[str] = []
    for ln in lines:
        if ln[:1] in (" ", "\t") and out:
            out[-1] += ln[1:]
        else:
            out.append(ln)
    return out


def split_once(line: str):
    in_q = False
    for i, ch in enumerate(line):
        if ch == '"':
            in_q = not in_q
        elif ch == ":" and not in_q:
            return line[:i], line[i + 1:]
    return None


def parse_params(s: str) -> dict[str, str]:
    params: dict[str, str] = {}
    cur: list[str] = []
    in_q = False
    for ch in s + ";":
        if ch == '"':
            in_q = not in_q
        if ch == ";" and not in_q:
            if cur:
                k, _, v = "".join(cur).partition("=")
                params[k.strip().upper()] = v.strip().strip('"')
            cur = []
        else:
            cur.append(ch)
    return params


def unescape(v: str) -> str:
    return re.sub(
        r"\\([,;\\nN])",
        lambda m: "\n" if m.group(1) in "nN" else m.group(1),
        v,
    )


def split_prop(line: str):
    parts = split_once(line)
    if parts is None:
        return None
    head, value = parts
    name, _, pstr = head.partition(";")
    return name.strip().upper(), parse_params(pstr), value


def parse_dt(value: str, params: dict[str, str]):
    v = value.strip()
    m = DT_RE.match(v)
    if not m:
        return None
    try:
        y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
        if m.group(4) is None or params.get("VALUE", "").upper() == "DATE":
            return date(y, mo, d), True
        h, mi, s = int(m.group(4)), int(m.group(5)), int(m.group(6))
        tz = timezone.utc if m.group(7) else resolve_tz(params.get("TZID"))
        return datetime(y, mo, d, h, mi, s, tzinfo=tz), False
    except ValueError:
        return None


def parse_duration(value: str):
    m = DUR_RE.match(value.strip())
    if not m or not any(m.group(i) for i in range(2, 6)):
        return None
    secs = (
        int(m.group(2) or 0) * 86400
        + int(m.group(3) or 0) * 3600
        + int(m.group(4) or 0) * 60
        + int(m.group(5) or 0)
    )
    return -secs if m.group(1) == "-" else secs


def parse_ics(text: str) -> list[dict]:
    events: list[dict] = []
    cur: dict | None = None
    in_vtimezone = False
    for line in unfold(text.splitlines()):
        if not line:
            continue
        prop = split_prop(line)
        if prop is None:
            continue
        name, params, value = prop
        if name == "BEGIN":
            if value.upper() == "VEVENT":
                cur = {}
            elif value.upper() == "VTIMEZONE":
                in_vtimezone = True
        elif name == "END":
            if value.upper() == "VTIMEZONE":
                in_vtimezone = False
            elif value.upper() == "VEVENT" and cur is not None:
                events.append(cur)
                cur = None
        elif cur is not None and not in_vtimezone:
            cur.setdefault(name.upper(), []).append((params, value))
    return events


class Event:
    def __init__(self, raw: dict):
        self.raw = raw
        self.invalid = False
        self.uid = self.value("UID") or f"unnamed-{id(raw)}"
        self.summary = (unescape(self.value("SUMMARY") or "(no title)")
                        .replace("\n", " ").strip())
        self.location = (unescape(self.value("LOCATION") or "")
                         .replace("\n", " ").strip())
        self.status = (self.value("STATUS") or "CONFIRMED").strip().upper()
        self.organizer = ""
        for params, v in self.raw.get("ORGANIZER", []):
            self.organizer = params.get("CN") or unescape(v).lstrip("mailto:")
            break
        self.is_all_day = False
        self.s_date = self.s_dt = None
        self.e_date = self.e_dt = None
        sfield = self.raw.get("DTSTART")
        if not sfield:
            self.invalid = True
            return
        parsed = parse_dt(sfield[0][1], sfield[0][0])
        if parsed is None:
            self.invalid = True
            return
        val, all_day = parsed
        self.is_all_day = all_day
        if all_day:
            self.s_date = val
        else:
            self.s_dt = val
            self.s_date = val.date()
        for params, v in self.raw.get("DTEND", []):
            p = parse_dt(v, params)
            if p:
                val2, all_day2 = p
                if all_day2:
                    self.is_all_day = self.is_all_day or all_day2
                    self.e_date = val2
                else:
                    self.e_dt = val2
                    self.is_all_day = False
        if self.e_dt is None and not self.is_all_day:
            for params, v in self.raw.get("DURATION", []):
                secs = parse_duration(v)
                if secs is not None:
                    self.e_dt = self.s_dt + timedelta(seconds=secs)
                    break
        if self.e_dt is None and not self.is_all_day:
            self.e_dt = self.s_dt
        if self.e_date is None:
            self.e_date = self.s_date
        self.rrule = None
        for _params, v in self.raw.get("RRULE", []):
            self.rrule = {
                k.strip().upper(): vv.strip()
                for k, vv in (kv.split("=", 1) for kv in v.split(";") if "=" in kv)
            }
        self.exdates = self._multi("EXDATE")
        self.rdates = self._multi("RDATE")
        self.recid_local = None
        for params, v in self.raw.get("RECURRENCE-ID", []):
            p = parse_dt(v.strip(), params)
            if p:
                val, all_day = p
                self.recid_local = (
                    val if all_day else val.astimezone(local_tz())
                )
                break
        self.cancelled = self.status == "CANCELLED" or bool(
            CANCELED_RE.match(self.summary)
        )

    def _multi(self, name: str):
        out = []
        for params, v in self.raw.get(name, []):
            for part in v.split(","):
                p = parse_dt(part.strip(), params)
                if p:
                    out.append(p)
        return out

    def value(self, name: str) -> str | None:
        for _params, v in self.raw.get(name, []):
            return v
        return None

    def local_start(self) -> datetime:
        if self.is_all_day:
            return datetime.combine(self.s_date, time(0, 0), tzinfo=local_tz())
        return self.s_dt.astimezone(local_tz())

    def end_offset(self) -> timedelta:
        if self.is_all_day:
            return timedelta(days=(self.e_date - self.s_date).days)
        if self.e_dt is None:
            return timedelta(0)
        return self.e_dt.astimezone(local_tz()) - self.local_start()


def parse_byday(s: str):
    out = []
    for t in s.split(","):
        t = t.strip()
        m = BYDAY_RE.match(t)
        if m:
            out.append(
                (int(m.group(1)) if m.group(1) else None, DOW[m.group(2).upper()])
            )
    return out


def parse_until(value: str):
    v = value.strip()
    m = DT_RE.match(v)
    if not m:
        return None
    try:
        y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
        if m.group(4) is None:
            return datetime.combine(date(y, mo, d), time(23, 59, 59),
                                    tzinfo=local_tz())
        h, mi, s = int(m.group(4)), int(m.group(5)), int(m.group(6))
        if m.group(7):
            return datetime(y, mo, d, h, mi, s,
                            tzinfo=timezone.utc).astimezone(local_tz())
        return datetime(y, mo, d, h, mi, s, tzinfo=local_tz())
    except ValueError:
        return None


def nth_dow_days(year: int, month: int, dow: int):
    last = calendar.monthrange(year, month)[1]
    return [date(year, month, d) for d in range(1, last + 1)
            if date(year, month, d).isoweekday() == dow]


def year_dow_days(year: int, dow: int):
    return [d for mth in range(1, 13) for d in nth_dow_days(year, mth, dow)]


def month_day_candidates(dim: int, x: int) -> int | None:
    d = x if x > 0 else dim + x + 1
    return d if 1 <= d <= dim else None


def apply_byday(days: set, year: int, month: int, byday, whole_year: bool = False):
    sel = set()
    for o, dow in byday:
        ds = year_dow_days(year, dow) if whole_year else nth_dow_days(year, month, dow)
        if o is None:
            sel |= set(ds)
        elif o > 0 and o <= len(ds):
            sel.add(ds[o - 1])
        elif o < 0 and -o <= len(ds):
            sel.add(ds[o])
    days &= sel


def month_occ_days(y: int, mth: int, bymonthday, bydaym) -> set:
    dim = calendar.monthrange(y, mth)[1]
    days = {date(y, mth, d) for d in range(1, dim + 1)}
    if bymonthday:
        days &= {date(y, mth, d) for x in bymonthday
                 if (d := month_day_candidates(dim, x))}
    if bydaym:
        apply_byday(days, y, mth, bydaym)
    return days


def build_occurrences(ev: Event, today: date):
    if ev.invalid:
        return []
    s_local = ev.local_start()
    base_time = time(0, 0) if ev.is_all_day else s_local.time()
    start_date = s_local.date()

    def mark(d: date):
        if ev.is_all_day:
            return d
        return datetime.combine(d, base_time, tzinfo=local_tz())

    r = ev.rrule or {}
    freq = r.get("FREQ", "").upper()
    interval = 1
    if r.get("INTERVAL"):
        try:
            interval = max(1, int(r["INTERVAL"]))
        except ValueError:
            pass
    until = parse_until(r["UNTIL"]) if r.get("UNTIL") else None
    count = None
    if r.get("COUNT"):
        try:
            count = int(r["COUNT"])
        except ValueError:
            pass

    occ: list[date | datetime] = []
    stop = False

    def add(m) -> bool:
        nonlocal stop, count
        if stop:
            return False
        if until is not None and m > until:
            return True
        if m < s_local:
            return True
        occ.append(m)
        if count is not None:
            count -= 1
            if count <= 0:
                stop = True
        return True

    if not r:
        occ.append(mark(start_date))
    elif freq in ("DAILY",):
        for k in range(MAX_OCCURRENCES):
            d = start_date + timedelta(days=k * interval)
            if d > today:
                stop = True
                break
            if not add(mark(d)):
                break
    elif freq == "WEEKLY":
        dows = sorted({d for _o, d in parse_byday(r.get("BYDAY", ""))}
                      or {start_date.isoweekday()})
        monday0 = start_date - timedelta(days=start_date.isoweekday() - 1)
        for k in range(MAX_OCCURRENCES):
            base = monday0 + timedelta(weeks=k * interval)
            if base + timedelta(days=min(dows) - 1) > today:
                break
            for dow in dows:
                d = base + timedelta(days=dow - 1)
                if d > today:
                    continue
                if not add(mark(d)):
                    break
            if stop:
                break
    elif freq == "MONTHLY":
        bymonthday = [int(x) for x in r["BYMONTHDAY"].split(",")] if r.get("BYMONTHDAY") else []
        bydaym = parse_byday(r.get("BYDAY", ""))
        bymonth = [int(x) for x in r["BYMONTH"].split(",")] if r.get("BYMONTH") else []
        if not bymonthday and not bydaym:
            bymonthday = [start_date.day]
        start_idx = start_date.year * 12 + (start_date.month - 1)
        for k in range(MAX_OCCURRENCES):
            idx = start_idx + k * interval
            y, mth = divmod(idx, 12)
            mth += 1
            if date(y, mth, 1) > today:
                stop = True
                break
            if bymonth and mth not in bymonth:
                continue
            past_month_end = False
            for d in sorted(month_occ_days(y, mth, bymonthday, bydaym)):
                if d > today:
                    past_month_end = True
                    break
                if not add(mark(d)):
                    break
            if past_month_end or stop:
                break
    elif freq == "YEARLY":
        bymonthday = [int(x) for x in r["BYMONTHDAY"].split(",")] if r.get("BYMONTHDAY") else []
        bydayy = parse_byday(r.get("BYDAY", ""))
        bymonth = [int(x) for x in r["BYMONTH"].split(",")] if r.get("BYMONTH") else []
        for k in range(MAX_OCCURRENCES):
            y = start_date.year + k * interval
            if date(y, 1, 1) > today:
                stop = True
                break
            dates: list[date] = []
            if bymonth:
                for mth in bymonth:
                    if bymonthday or bydayy:
                        dates.extend(sorted(
                            month_occ_days(y, mth, bymonthday, bydayy)))
                    elif start_date.day <= calendar.monthrange(y, mth)[1]:
                        dates.append(date(y, mth, start_date.day))
            elif bydayy:
                days = {date(y, mth, d) for mth in range(1, 13)
                        for d in range(1, calendar.monthrange(y, mth)[1] + 1)}
                apply_byday(days, y, 1, bydayy, whole_year=True)
                dates = sorted(days)
            elif bymonthday:
                for mth in range(1, 13):
                    dates.extend(sorted(
                        month_occ_days(y, mth, bymonthday, None)))
            else:
                dates.append(date(y, start_date.month, start_date.day))
            past_year = False
            for d in sorted(dates):
                if d > today:
                    past_year = True
                    break
                if not add(mark(d)):
                    break
            if past_year or stop:
                break
    else:
        warn(f"unsupported RRULE FREQ {freq!r} for {ev.summary!r}")
        return []

    for val, all_day in ev.rdates:
        if all_day or ev.is_all_day:
            m = val.date() if isinstance(val, datetime) else val
        else:
            m = val.astimezone(local_tz())
        if (isinstance(m, datetime) and m.date() > today) or (
            isinstance(m, date) and m > today
        ):
            continue
        if m not in occ:
            occ.append(m)
    return sorted(set(occ), key=lambda m: (m.date() if isinstance(m, datetime) else m))


def in_exdates(ev: Event, m) -> bool:
    for val, all_day in ev.exdates:
        if ev.is_all_day:
            d = val.date() if isinstance(val, datetime) else val
            if d == m:
                return True
        else:
            if isinstance(val, datetime):
                if val.astimezone(local_tz()) == m:
                    return True
            elif val == m.date():
                return True
    return False


def make_block(disp: Event, start):
    if disp.is_all_day:
        end_d = start + timedelta(days=(disp.e_date - disp.s_date).days)
        if end_d == start:
            timepart = "all day"
        else:
            timepart = f"{start:%b %-d} - {end_d:%b %-d}"
    else:
        end = start + disp.end_offset()
        timepart = f"{start:%H:%M} - {end:%H:%M}"
        if end.date() != start.date():
            timepart += f" (+{(end.date() - start.date()).days}d)"
    lines = [disp.summary]
    if disp.location:
        lines.append(f"    location:  {disp.location}")
    if disp.organizer:
        lines.append(f"    organizer: {disp.organizer}")
    if disp.cancelled:
        lines.append("    status:    CANCELLED")
    elif disp.status not in ("", "CONFIRMED", "PUBLISHED", "TENTATIVE"):
        lines.append(f"    status:    {disp.status}")
    return timepart, lines


def render_day(events: list[Event], today: date) -> None:
    """Print the calendar entries for one day."""
    ovs: dict[str, list[Event]] = {}
    for ev in events:
        if ev.recid_local is not None:
            ovs.setdefault(ev.uid, []).append(ev)

    day_start = datetime.combine(today, time(0, 0), tzinfo=local_tz())
    day_end = day_start + timedelta(days=1)
    entries: list[tuple[datetime, str]] = []
    seen: set[tuple] = set()

    def add_entry(disp: Event, marker):
        if disp.is_all_day:
            end_date = marker + timedelta(days=(disp.e_date - disp.s_date).days)
            if not (marker <= today <= end_date):
                return
            key = (disp.uid, marker)
            sortkey = datetime.combine(marker, time(0, 0), tzinfo=local_tz())
        else:
            end_dt = marker + disp.end_offset()
            if not (marker < day_end and end_dt > day_start):
                return
            key = (disp.uid, marker)
            sortkey = marker
        if key in seen:
            return
        seen.add(key)
        entries.append((sortkey, make_block(disp, marker)))


    matched: set[int] = set()
    for ev in events:
        if ev.recid_local is not None:
            continue
        for m in build_occurrences(ev, today):
            if in_exdates(ev, m):
                continue
            match = None
            for o in ovs.get(ev.uid, []):
                rl = o.recid_local
                if rl == m or (isinstance(m, datetime) and rl == m.date()):
                    match = o
                    break
            if match is not None:
                matched.add(id(match))
                start = m
                if not ev.is_all_day and not match.is_all_day \
                        and match.local_start() != m:
                    start = match.local_start()
                add_entry(match, start)
            else:
                add_entry(ev, m)

    for ev in events:
        if ev.recid_local is None or id(ev) in matched:
            continue
        if ev.invalid:
            continue
        if ev.is_all_day:
            start = ev.recid_local
        else:
            start = ev.local_start()
        add_entry(ev, start)

    weekday = WEEKDAYS[today.weekday()]
    entries.sort(key=lambda t: t[0])
    if not entries:
        print(f"No calendar entries for {today.isoformat()} ({weekday}).")
        return
    width = max(len(block[0]) for _k, block in entries)
    print(f"Calendar entries for {today.isoformat()} ({weekday}) "
          f"- {len(entries)}:")
    print()
    for i, (_k, (timepart, lines)) in enumerate(entries):
        print(f"{timepart:<{width}}  {lines[0]}")
        for ln in lines[1:]:
            print(ln)
        if i < len(entries) - 1:
            print()


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Print calendar entries for a day from an ICS file "
                    "or feed.")
    ap.add_argument("--file", "-f",
                    help="ICS file to read (default: --url, stdin, or the "
                         "calendar.url from config.yaml)")
    ap.add_argument("--url",
                    help="ICS feed URL to fetch (default: calendar.url "
                         "from config.yaml in the current directory)")
    ap.add_argument("--date", "-d",
                    help="first day to show as YYYY-MM-DD "
                         "(default: today, local)")
    ap.add_argument("--days", "-n", type=int, default=1,
                    help="number of consecutive days to show starting at "
                         "the given date (default: 1)")
    args = ap.parse_args()
    if args.days < 1:
        ap.error("--days must be >= 1")
    try:
        first = date.fromisoformat(args.date) if args.date else date.today()
    except ValueError:
        ap.error(f"bad date {args.date!r}, expected YYYY-MM-DD")
    try:
        text = read_ics(args, ap)
    except FetchError as e:
        print(f"error: {e}", file=sys.stderr)
        print("fallback: fetch the calendar URL with the webfetch tool, "
              "save the result to a file, and re-run this script with "
              "--file <that-file>", file=sys.stderr)
        return 1
    if "BEGIN:VCALENDAR" not in text:
        print("error: input does not look like an ICS file "
              "(BEGIN:VCALENDAR not found)", file=sys.stderr)
        return 1

    events = [Event(raw) for raw in parse_ics(text)]
    for i in range(args.days):
        if i:
            print()
        render_day(events, first + timedelta(days=i))
    return 0


if __name__ == "__main__":
    sys.exit(main())
