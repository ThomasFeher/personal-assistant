#!/usr/bin/env bash
# Print the calendar entries for a day (default: today) from an ICS file.
#
# Bash + gawk companion to calendar_today.py for parsing ICS from a file
# or stdin. Fetching the feed URL itself (--url and calendar.url auto-read
# from config.yaml) is implemented in calendar_today.py only: it fetches
# with a browser-like User-Agent, because OWA redirects unauthenticated
# clients to an auth error page.
#
# Usage:
#     calendar_today.sh [--file ICS_FILE] [--date YYYY-MM-DD]
#
# Prints one block per entry on the selected day, chronologically,
# all-day entries first.  Warnings go to stderr.  Exit status: 0 on
# success (also when there are no entries), 1 on error, 2 on usage error.

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: calendar_today.sh [--file ICS_FILE] [--date YYYY-MM-DD]

Print the calendar entries for a day (default: today) from an ICS file.
The ICS content is read from the given file or from stdin.
USAGE
}

file=""
d=""
while [ $# -gt 0 ]; do
    case "$1" in
        --file|-f)
            [ $# -ge 2 ] || { echo "error: $1 requires a value" >&2; exit 2; }
            file=$2; shift 2 ;;
        --date|-d)
            [ $# -ge 2 ] || { echo "error: $1 requires a value" >&2; exit 2; }
            d=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 2 ;;
    esac
done

if [ -z "$d" ]; then
    d=$(date +%F)
elif ! [[ $d =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || ! date -d "$d" >/dev/null 2>&1; then
    echo "error: bad date '$d', expected YYYY-MM-DD" >&2
    exit 2
fi

command -v gawk >/dev/null 2>&1 || {
    echo "error: gawk is required but was not found" >&2
    exit 1
}

if [ -n "$file" ]; then
    [ -r "$file" ] || { echo "error: cannot read '$file'" >&2; exit 1; }
fi

read -r -d '' AWK_PROG <<'AWK_EOF' || true
function trim(s) { gsub(/^[ \t\r]+/, "", s); gsub(/[ \t\r]+$/, "", s); return s }

function warn(msg) { print "warning: " msg > "/dev/stderr" }

function days_in_month(y, m) {
    if (m == 2)
        return (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) ? 29 : 28
    return (m == 4 || m == 6 || m == 9 || m == 11) ? 30 : 31
}

function days_from_civil(y, m, d,    era, yoe, doy, doe) {
    if (m <= 2) y--
    era = int((y >= 0 ? y : y - 399) / 400)
    yoe = y - era * 400
    doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    return era * 146097 + doe - 719468
}

function civil_from_days(z,    era, doe, yoe, y, doy, mp, d, m) {
    z += 719468
    era = int((z >= 0 ? z : z - 146096) / 146097)
    doe = z - era * 146097
    yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
    y = yoe + era * 400
    doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
    mp = int((5 * doy + 2) / 153)
    d = doy - int((153 * mp + 2) / 5) + 1
    m = mp + (mp < 10 ? 3 : -9)
    if (m <= 2) y++
    return sprintf("%04d-%02d-%02d", y, m, d)
}

function znum8(s) {
    return days_from_civil(substr(s, 1, 4) + 0, substr(s, 5, 2) + 0, substr(s, 7, 2) + 0)
}

function dow_of(z) { return ((z + 3) % 7 + 7) % 7 + 1 }

function hms_ec(hm) {
    return substr(hm, 1, 2) * 3600 + substr(hm, 4, 2) * 60 + substr(hm, 7, 2)
}

function utc_epoch_wall(w) {
    return days_from_civil(substr(w, 1, 4) + 0, substr(w, 5, 2) + 0, substr(w, 7, 2) + 0) * 86400 \
        + substr(w, 9, 2) * 3600 + substr(w, 11, 2) * 60 + substr(w, 13, 2)
}

function utc_wall(e,    d, r) {
    d = int(e / 86400); r = e - d * 86400
    if (r < 0) { d--; r += 86400 }
    r = int(r)
    return civil_from_days(d) "-" sprintf("%02d%02d%02d", int(r / 3600), int(r / 60) % 60, r % 60)
}

function zone_ok(z,    ok) {
    if (z in zok) return zok[z]
    ok = 0
    if (system("test -r /usr/share/zoneinfo/" z " 2>/dev/null") == 0) ok = 1
    else if (system("test -r /usr/lib/zoneinfo/" z " 2>/dev/null") == 0) ok = 1
    else if (system("test -r /etc/zoneinfo/" z " 2>/dev/null") == 0) ok = 1
    zok[z] = ok
    return ok
}

function epoch_in_zone(z, w,    key, cmd, e, ok, w16) {
    key = z "\x1f" w
    if (key in zcach2) return zcach2[key]
    w16 = sprintf("%04d-%02d-%02d %02d:%02d:%02d", substr(w,1,4)+0, substr(w,5,2)+0, \
        substr(w,7,2)+0, substr(w,9,2)+0, substr(w,11,2)+0, substr(w,13,2)+0)
    cmd = (z == "" ? "date -d " : "TZ=\x27" z "\x27 date -d ") "\"" w16 "\" +%s 2>/dev/null"
    e = ""; ok = 0
    if ((cmd | getline e) > 0 && e ~ /^-?[0-9]+$/) ok = 1
    close(cmd)
    if (!ok) {
        if (z != "" && !(z in warned_zone)) warned_zone[z] = 1
        e = utc_epoch_wall(w)
    }
    zcach2[key] = e + 0
    return zcach2[key]
}

function zone_epoch(w, tzid,    key, z, e, sgn, off, rest, m) {
    key = tzid "\x1f" w
    if (key in zcach) return zcach[key]
    z = trim(tzid)
    if (z == "" || toupper(z) == "UTC" || z == "Z") {
        e = utc_epoch_wall(w)
    } else if (z in MSALIAS) {
        e = epoch_in_zone(MSALIAS[z], w)
    } else if (match(z, /^UTC([+-])([0-9]{1,2})(:([0-9]{2}))?$/i)) {
        sgn = substr(z, 4, 1)
        rest = substr(z, 5)
        off = 0
        if (match(rest, /^([0-9]{1,2}):([0-9]{2})$/, m))
            off = m[1] * 60 + m[2]
        else if (rest ~ /^[0-9]{1,2}$/)
            off = (rest + 0) * 60
        e = utc_epoch_wall(w) - (sgn == "-" ? -off : off)
    } else if (z ~ /^[A-Za-z0-9_.\/+-]+$/) {
        if (zone_ok(z))
            e = epoch_in_zone(z, w)
        else {
            if (!(z in warned_tz)) {
                warned_tz[z] = 1
                warn("unknown timezone id \x27" z "\x27; assuming local time")
            }
            e = epoch_in_zone("", w)
        }
    } else {
        if (!(z in warned_tz)) {
            warned_tz[z] = 1
            warn("unknown timezone id \x27" z "\x27; assuming local time")
        }
        e = epoch_in_zone("", w)
    }
    zcach[key] = e
    return e
}

function local_of(e,    cmd, w, ok) {
    if (e in lcache) return lcache[e]
    cmd = "date -d @" (e + 0) " +\x27%Y%m%d%H%M%S\x27 2>/dev/null"
    w = ""; ok = 0
    if ((cmd | getline w) > 0 && w ~ /^[0-9]{14}$/) ok = 1
    close(cmd)
    if (!ok) {
        w = utc_wall(e + 0)
        gsub(/-/, "", w)
    }
    lcache[e] = w
    return w
}

function unesc(s,    i, c, d, n, out) {
    out = ""; n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\\" && i < n) {
            d = substr(s, i + 1, 1)
            if (d == "," || d == ";" || d == "\\" || d == "n" || d == "N") {
                out = out (d == "n" || d == "N" ? "\n" : d)
                i++
                continue
            }
        }
        out = out c
    }
    return out
}

function squash(s) { gsub(/\n/, " ", s); return trim(s) }

function orgfix(v,    s) {
    s = unesc(v)
    while (s != "" && index("mailto:", substr(s, 1, 1)) > 0) s = substr(s, 2)
    return s
}

function parse_params(pstr,    n, a, i, k, v, eq) {
    if (pstr == "") return
    n = split(pstr, a, ";")
    for (i = 1; i <= n; i++) {
        if (a[i] == "") continue
        eq = index(a[i], "=")
        if (eq == 0) { k = trim(a[i]); v = "" }
        else { k = trim(substr(a[i], 1, eq - 1)); v = trim(substr(a[i], eq + 1)) }
        sub(/^"/, "", v); sub(/"$/, "", v)
        PP[toupper(k)] = v
    }
}

function reset_event(ev) {
    E_uid[ev] = ""; E_sum[ev] = ""; E_loc[ev] = ""; E_org[ev] = ""
    E_status[ev] = ""; E_alld[ev] = 0; E_inv[ev] = 0
    has_s[ev] = 0; has_dur[ev] = 0; dur_sec[ev] = 0
    S_wall[ev] = ""; S_date[ev] = ""; S_epoch[ev] = 0
    E_enddt[ev] = 0; E_endepoch[ev] = 0; E_enddate[ev] = ""
    E_endoff[ev] = 0; E_span[ev] = 0
    R_freq[ev] = ""; R_ival[ev] = 1; R_until[ev] = ""; R_count[ev] = ""
    R_bymidd[ev] = ""; R_byday[ev] = ""; R_bymonth[ev] = ""
    EX_n[ev] = 0; RD_n[ev] = 0
    REC[ev] = ""; REC_t[ev] = 0
    E_cx[ev] = 0
}

function finalize(ev) {
    if (E_inv[ev] || !has_s[ev]) { E_inv[ev] = 1; return }
    if (E_alld[ev]) {
        if (E_enddate[ev] != "")
            E_span[ev] = znum8(E_enddate[ev]) - znum8(S_date[ev])
        else
            E_span[ev] = 0
    } else {
        if (E_enddt[ev]) E_endoff[ev] = E_endepoch[ev] - S_epoch[ev]
        else if (has_dur[ev]) E_endoff[ev] = dur_sec[ev]
        else E_endoff[ev] = 0
    }
    s = tolower(E_sum[ev])
    E_cx[ev] = (E_status[ev] == "CANCELLED" || s ~ /^[ \t]*(canceled|cancelled|abgesagt)[ \t]*[: -]/)
}

function pdate_parts(v, mt,    y, mo, d) {
    # sets POK (0/1), Pdate "YYYYMMDD", Pwall "YYYYMMDDHHMMSS", PZ
    POK = 0; Pdate = ""; Pwall = ""; PZ = 0
    v = trim(v)
    if (length(v) == 8 && v ~ /^[0-9]{8}$/) {
        y = substr(v, 1, 4) + 0; mo = substr(v, 5, 2) + 0; d = substr(v, 7, 2) + 0
        if (mo < 1 || mo > 12 || d < 1 || d > days_in_month(y, mo)) return
        POK = 1; Pdate = v
        return
    }
    if (match(v, /^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})(Z?)$/, mt)) {
        y = mt[1] + 0; mo = mt[2] + 0; d = mt[3] + 0
        if (mo < 1 || mo > 12 || d < 1 || d > days_in_month(y, mo)) return
        if (mt[4] + 0 > 23 || mt[5] + 0 > 59 || mt[6] + 0 > 59) return
        POK = 1; Pdate = mt[1] mt[2] mt[3]
        Pwall = mt[1] mt[2] mt[3] mt[4] mt[5] mt[6]
        PZ = (mt[7] == "Z")
    }
}

function is_all_date_form() {
    return (PZ == 0 && Pwall == "") || toupper(PP["VALUE"]) == "DATE"
}

function do_dtstart(v,    e, lw) {
    pdate_parts(v)
    if (!POK) { E_inv[cur] = 1; return }
    has_s[cur] = 1
    if (is_all_date_form()) {
        E_alld[cur] = 1
        S_date[cur] = Pdate
    } else {
        if (PZ) e = utc_epoch_wall(Pwall)
        else e = zone_epoch(Pwall, PP["TZID"])
        S_epoch[cur] = e
        S_wall[cur] = local_of(e)
    }
}

function do_dtend(v,    e) {
    pdate_parts(v)
    if (!POK) return
    if (is_all_date_form() && toupper(PP["VALUE"]) != "DATE" && Pwall == "" && PZ == 0) {
        E_alld[cur] = 1
        E_enddate[cur] = Pdate
    } else if (toupper(PP["VALUE"]) == "DATE") {
        E_alld[cur] = 1
        E_enddate[cur] = Pdate
    } else {
        if (PZ) e = utc_epoch_wall(Pwall)
        else e = zone_epoch(Pwall, PP["TZID"])
        E_enddt[cur] = 1
        E_endepoch[cur] = e
        E_alld[cur] = 0
    }
}

function do_duration(v,    secs, m) {
    v = trim(v)
    if (match(v, /^([-+]?)P(?:(-?[0-9]+)D)?(?:T(?:(-?[0-9]+)H)?(?:(-?[0-9]+)M)?(?:(-?[0-9]+)S)?)?$/i, m)) {
        if (m[2] == "" && m[4] == "" && m[5] == "" && m[6] == "") return
        secs = (m[2] == "" ? 0 : m[2] * 86400) + (m[4] == "" ? 0 : m[4] * 3600) \
            + (m[5] == "" ? 0 : m[5] * 60) + (m[6] == "" ? 0 : m[6])
        if (m[1] == "-") secs = -secs
        if (!has_dur[cur]) { has_dur[cur] = 1; dur_sec[cur] = secs }
    }
}

function do_rrule(v,    n, a, i, k, val, eqp) {
    R_freq[cur] = ""; R_ival[cur] = 1; R_until[cur] = ""; R_count[cur] = ""
    R_bymidd[cur] = ""; R_byday[cur] = ""; R_bymonth[cur] = ""
    n = split(v, a, ";")
    for (i = 1; i <= n; i++) {
        if (a[i] == "") continue
        eqp = index(a[i], "=")
        if (eqp == 0) continue
        k = toupper(trim(substr(a[i], 1, eqp - 1)))
        val = trim(substr(a[i], eqp + 1))
        if (k == "FREQ") R_freq[cur] = toupper(val)
        else if (k == "INTERVAL" && val ~ /^[0-9]+$/) R_ival[cur] = (val + 0 < 1 ? 1 : val + 0)
        else if (k == "UNTIL") R_until[cur] = val
        else if (k == "COUNT" && val ~ /^[0-9]+$/) R_count[cur] = val + 0
        else if (k == "BYMONTHDAY") R_bymidd[cur] = val
        else if (k == "BYDAY") R_byday[cur] = val
        else if (k == "BYMONTH") R_bymonth[cur] = val
    }
}

function do_exdate(v) {
    n = split(v, a, ",")
    for (i = 1; i <= n; i++) {
        pdate_parts(a[i])
        if (!POK) continue
        EX_n[cur]++
        if (is_all_date_form() && Pwall == "") {
            EX_t[cur, EX_n[cur]] = 0; EX_s[cur, EX_n[cur]] = Pdate
        } else {
            if (PZ) e2 = utc_epoch_wall(Pwall)
            else e2 = zone_epoch(Pwall, PP["TZID"])
            EX_t[cur, EX_n[cur]] = 1
            EX_s[cur, EX_n[cur]] = local_of(e2)
        }
    }
}

function do_rdate(v) {
    n = split(v, a, ",")
    for (i = 1; i <= n; i++) {
        pdate_parts(a[i])
        if (!POK) continue
        RD_n[cur]++
        if (Pwall == "") {
            RD_t[cur, RD_n[cur]] = 0
            RD_s[cur, RD_n[cur]] = Pdate
        } else {
            if (PZ) e2 = utc_epoch_wall(Pwall)
            else e2 = zone_epoch(Pwall, PP["TZID"])
            lw = local_of(e2)
            if (E_alld[cur]) {
                RD_t[cur, RD_n[cur]] = 0
                RD_s[cur, RD_n[cur]] = substr(lw, 1, 8)
            } else {
                RD_t[cur, RD_n[cur]] = 1
                RD_s[cur, RD_n[cur]] = lw
            }
        }
    }
}

function do_recid(v) {
    if (REC[cur] != "") return
    pdate_parts(v)
    if (!POK) return
    if (is_all_date_form() && Pwall == "") {
        REC[cur] = Pdate; REC_t[cur] = 0
    } else {
        if (PZ) e2 = utc_epoch_wall(Pwall)
        else e2 = zone_epoch(Pwall, PP["TZID"])
        REC[cur] = local_of(e2); REC_t[cur] = 1
    }
}

function handle(line,    pos, i, ch, inq, head, value, pp, name, pstr, vup) {
    inq = 0; pos = 0
    for (i = 1; i <= length(line); i++) {
        ch = substr(line, i, 1)
        if (ch == "\"") inq = !inq
        else if (ch == ":" && !inq) { pos = i; break }
    }
    if (pos == 0) return
    head = substr(line, 1, pos - 1)
    value = substr(line, pos + 1)
    pp = index(head, ";")
    if (pp) { name = toupper(trim(substr(head, 1, pp - 1))); pstr = substr(head, pp + 1) }
    else { name = toupper(trim(head)); pstr = "" }
    delete PP
    parse_params(pstr)

    if (name == "BEGIN") {
        vup = toupper(trim(value))
        if (vup == "VCALENDAR") cal = 1
        else if (vup == "VEVENT") { ne++; cur = ne; reset_event(cur) }
        else if (vup == "VTIMEZONE") intz = 1
        return
    }
    if (name == "END") {
        vup = toupper(trim(value))
        if (vup == "VTIMEZONE") intz = 0
        else if (vup == "VEVENT" && cur == ne) cur = 0
        return
    }
    if (cur == 0 || intz) return
    if (name == "UID") { if (E_uid[cur] == "") E_uid[cur] = value }
    else if (name == "SUMMARY") { if (E_sum[cur] == "") E_sum[cur] = squash(unesc(value)) }
    else if (name == "LOCATION") { if (E_loc[cur] == "") E_loc[cur] = squash(unesc(value)) }
    else if (name == "STATUS") { if (E_status[cur] == "") E_status[cur] = toupper(trim(value)) }
    else if (name == "ORGANIZER") {
        if (E_org[cur] == "")
            E_org[cur] = (PP["CN"] != "" ? PP["CN"] : orgfix(value))
    }
    else if (name == "DTSTART") do_dtstart(value)
    else if (name == "DTEND") do_dtend(value)
    else if (name == "DURATION") do_duration(value)
    else if (name == "RRULE") do_rrule(value)
    else if (name == "EXDATE") do_exdate(value)
    else if (name == "RDATE") do_rdate(value)
    else if (name == "RECURRENCE-ID") do_recid(value)
}

# ---------------- recurrence expansion (fills OC[1..OC_n] as daynums) --------

function parse_byday_list(s,    n, a, i, t, m) {
    NBD = 0
    n = split(s, a, ",")
    for (i = 1; i <= n; i++) {
        t = toupper(trim(a[i]))
        if (match(t, /^([+-]?[0-9]{1,2})?(MO|TU|WE|TH|FR|SA|SU)$/, m)) {
            NBD++
            BDO[NBD] = (m[1] == "" ? "" : m[1] + 0)
            BWD[NBD] = DOWMAP[m[2]]
        }
    }
}

function add_occ(z, hm,    u) {
    if (stopping) return 0
    if (UNTILS != "") {
        u = civil_from_days(z) " " substr(hm, 1, 5) ":00"
        if (u > UNTILS) return 1
    }
    if (z < ZSTART || (z == ZSTART && hm < HMSTART)) return 1
    if (z > TODAY_Z) { stopping = 1; return 0 }
    OC[++OC_n] = z
    OCset[z] = 1
    if (HAVE_CNT) { CNT--; if (CNT <= 0) stopping = 1 }
    return 1
}

function count_dow(y, mth, wd,    d2, nd, c) {
    c = 0; nd = days_in_month(y, mth)
    for (d2 = 1; d2 <= nd; d2++) if (dow_of(days_from_civil(y, mth, d2)) == wd) c++
    return c
}

function dow_pos(y, mth, d2, wd,    c) {
    c = 0
    for (i2 = 1; i2 <= d2; i2++)
        if (dow_of(days_from_civil(y, mth, i2)) == wd) c++
    return c
}

function keep_m(y, mth, d2,    i, x, dd, dw, n, pos, ok) {
    if (NBMD > 0) {
        ok = 0
        for (i = 1; i <= NBMD; i++) {
            x = BMD[i]
            dd = (x > 0 ? x : days_in_month(y, mth) + x + 1)
            if (dd == d2 && dd >= 1 && dd <= days_in_month(y, mth)) { ok = 1; break }
        }
        if (!ok) return 0
    }
    if (NBD > 0) {
        dw = dow_of(days_from_civil(y, mth, d2))
        ok = 0
        for (i = 1; i <= NBD; i++) {
            if (BWD[i] != dw) continue
            n = count_dow(y, mth, dw)
            pos = dow_pos(y, mth, d2, dw)
            if (BDO[i] == "") { ok = 1; break }
            else if (BDO[i] > 0 && BDO[i] == pos) { ok = 1; break }
            else if (BDO[i] < 0 && -BDO[i] == n - pos + 1) { ok = 1; break }
        }
        if (!ok) return 0
    }
    return 1
}

function expand(ev,    y, mth, idx, start_idx, k, nd, d2, z2, i, j, base, mon0, x, m, s) {
    OC_n = 0
    delete OC; delete OCset
    stopping = 0
    HAVE_CNT = (R_count[ev] != "")
    CNT = R_count[ev] + 0
    UNTILS = until_str(ev)
    ZSTART = SZ[ev]; HMSTART = SHM[ev]
    SY = substr(SZS[ev], 1, 4) + 0
    SM = substr(SZS[ev], 5, 2) + 0
    SDAY = substr(SZS[ev], 7, 2) + 0

    NBMD = 0; NBD = 0; NBM = 0
    n = split(R_bymidd[ev], a, ",")
    for (i = 1; i <= n; i++) if (a[i] ~ /^[+-]?[0-9]+$/) { NBMD++; BMD[NBMD] = a[i] + 0 }
    parse_byday_list(R_byday[ev])
    n = split(R_bymonth[ev], a, ",")
    for (i = 1; i <= n; i++) if (a[i] ~ /^[0-9]+$/) { NBM++; BMO[NBM] = a[i] + 0 }

    freq = R_freq[ev]; ival = R_ival[ev]

    if (freq == "") {
        add_occ(ZSTART, HMSTART)
        return
    }
    if (freq == "DAILY") {
        for (k = 0; k < 10000; k++)
            if (!add_occ(ZSTART + k * ival, HMSTART)) break
        return
    }
    if (freq == "WEEKLY") {
        nwd = 0
        delete WSET
        if (R_byday[ev] != "") {
            delete dummy
            n2 = split("", dummy)
            n = split(R_byday[ev], a, ",")
            for (i = 1; i <= n; i++) {
                t = toupper(trim(a[i]))
                if (match(t, /^([+-]?[0-9]{1,2})?(MO|TU|WE|TH|FR|SA|SU)$/, m))
                    WSET[DOWMAP[m[2]]] = 1
            }
        }
        if (length(WSET) == 0) WSET[dow_of(ZSTART)] = 1
        for (wd in WSET) { nwd++; WDS[nwd] = wd }
        for (i = 1; i <= nwd; i++)
            for (j = i + 1; j <= nwd; j++)
                if (WDS[j] < WDS[i]) { x = WDS[i]; WDS[i] = WDS[j]; WDS[j] = x }
        minw = WDS[1]
        mon0 = ZSTART - (dow_of(ZSTART) - 1)
        for (k = 0; k < 10000; k++) {
            base = mon0 + 7 * k * ival
            if (base + (minw - 1) > TODAY_Z) break
            for (j = 1; j <= nwd; j++) {
                z2 = base + (WDS[j] - 1)
                if (z2 > TODAY_Z) continue
                if (!add_occ(z2, HMSTART)) break
                if (stopping) break
            }
            if (stopping) break
        }
        return
    }
    if (freq == "MONTHLY") {
        if (NBMD == 0 && NBD == 0) { NBMD = 1; BMD[1] = SDAY }
        start_idx = SY * 12 + (SM - 1)
        for (k = 0; k < 10000; k++) {
            idx = start_idx + k * ival
            y = int(idx / 12); mth = idx % 12 + 1
            if (days_from_civil(y, mth, 1) > TODAY_Z) { stopping = 1; break }
            inbm = 0
            if (NBM > 0) {
                for (i = 1; i <= NBM; i++) if (BMO[i] == mth) { inbm = 1; break }
                if (!inbm) continue
            }
            nd = days_in_month(y, mth)
            for (d2 = 1; d2 <= nd; d2++) {
                if (!keep_m(y, mth, d2)) continue
                z2 = days_from_civil(y, mth, d2)
                if (z2 > TODAY_Z) { stopping = 1; break }
                if (!add_occ(z2, HMSTART)) break
            }
            if (stopping) break
        }
        return
    }
    if (freq == "YEARLY") {
        for (k = 0; k < 10000; k++) {
            y = SY + k * ival
            if (days_from_civil(y, 1, 1) > TODAY_Z) { stopping = 1; break }
            NC = 0
            delete CAND
            if (NBM > 0) {
                for (i = 1; i <= NBM; i++) {
                    mth = BMO[i]
                    if (mth < 1 || mth > 12) continue
                    if (NBMD > 0 || NBD > 0) {
                        nd = days_in_month(y, mth)
                        for (d2 = 1; d2 <= nd; d2++)
                            if (keep_m(y, mth, d2)) CAND[++NC] = days_from_civil(y, mth, d2)
                    } else if (SDAY <= days_in_month(y, mth))
                        CAND[++NC] = days_from_civil(y, mth, SDAY)
                }
            } else if (NBD > 0) {
                delete CSEL
                for (i = 1; i <= NBD; i++) {
                    n = 0
                    delete dslist
                    for (mth = 1; mth <= 12; mth++)
                        for (d2 = 1; d2 <= days_in_month(y, mth); d2++)
                            if (dow_of(days_from_civil(y, mth, d2)) == BWD[i]) dslist[++n] = days_from_civil(y, mth, d2)
                    if (BDO[i] == "") {
                        for (j = 1; j <= n; j++) CSEL[dslist[j]] = 1
                    } else if (BDO[i] > 0 && BDO[i] <= n) {
                        CSEL[dslist[BDO[i]]] = 1
                    } else if (BDO[i] < 0 && -BDO[i] <= n) {
                        CSEL[dslist[n + BDO[i] + 1]] = 1
                    }
                }
                for (z2 in CSEL) CAND[++NC] = z2
            } else if (NBMD > 0) {
                for (mth = 1; mth <= 12; mth++)
                    for (i = 1; i <= NBMD; i++) {
                        x = BMD[i]
                        nd = days_in_month(y, mth)
                        d2 = (x > 0 ? x : nd + x + 1)
                        if (d2 >= 1 && d2 <= nd) CAND[++NC] = days_from_civil(y, mth, d2)
                    }
            } else {
                CAND[++NC] = days_from_civil(y, SM, SDAY)
            }
            if (NC > 0) {
                delete CSORT
                asort(CAND, CSORT, "@val_num_asc")
            }
            for (i = 1; i <= NC; i++) {
                z2 = CSORT[i]
                if (z2 > TODAY_Z) { stopping = 1; break }
                if (!add_occ(z2, HMSTART)) break
            }
            if (stopping) break
        }
        return
    }
    if (!(freq in warned_freq)) {
        warned_freq[freq] = 1
        warn("unsupported RRULE FREQ \x27" freq "\x27 for \x27" E_sum[ev] "\x27")
    }
}

function until_str(ev,    v, mt, y, mo, d, h, mi, s, e2, lw, m) {
    if (R_until[ev] == "") return ""
    v = trim(R_until[ev])
    if (v ~ /^[0-9]{8}$/) {
        y = substr(v, 1, 4) + 0; mo = substr(v, 5, 2) + 0; d = substr(v, 7, 2) + 0
        if (mo < 1 || mo > 12 || d < 1 || d > days_in_month(y, mo)) return ""
        return sprintf("%04d-%02d-%02d 23:59:59", y, mo, d)
    }
    if (match(v, /^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})(Z?)$/, mt)) {
        y = mt[1] + 0; mo = mt[2] + 0; d = mt[3] + 0
        h = mt[4] + 0; mi = mt[5] + 0; s = mt[6] + 0
        if (mo < 1 || mo > 12 || d < 1 || d > days_in_month(y, mo)) return ""
        if (h > 23 || mi > 59 || s > 59) return ""
        if (mt[7] == "Z") {
            e2 = utc_epoch_wall(mt[1] mt[2] mt[3] mt[4] mt[5] mt[6])
            lw = local_of(e2)
            return substr(lw, 1, 4) "-" substr(lw, 5, 2) "-" substr(lw, 7, 2) " " \
                substr(lw, 9, 2) ":" substr(lw, 11, 2) ":" substr(lw, 13, 2)
        }
        return sprintf("%04d-%02d-%02d %02d:%02d:%02d", y, mo, d, h, mi, s)
    }
    return ""
}

function occ_touches(ev, z,    ss, endz, rem) {
    if (E_alld[ev]) return (z <= TODAY_Z && z + E_span[ev] >= TODAY_Z)
    ss = hms_ec(SHM[ev]) + E_endoff[ev]
    if (ss < 0) ss = 0
    endz = z + int(ss / 86400)
    rem = ((ss % 86400) + 86400) % 86400
    return (z <= TODAY_Z && (endz > TODAY_Z || (endz == TODAY_Z && rem > 0)))
}

function exdate_hit(ev, z,    i, zc, zt) {
    zc = zcomp(z)
    if (E_alld[ev]) {
        for (i = 1; i <= EX_n[ev]; i++)
            if (EX_t[ev, i] == 0 && EX_s[ev, i] == zc) return 1
        return 0
    }
    zt = zc substr(SHM[ev], 1, 2) substr(SHM[ev], 4, 2) substr(SHM[ev], 7, 2)
    for (i = 1; i <= EX_n[ev]; i++) {
        if (EX_t[ev, i] == 1 && EX_s[ev, i] == zt) return 1
        if (EX_t[ev, i] == 0 && EX_s[ev, i] == zc) return 1
    }
    return 0
}

function zcomp(z) {
    s = civil_from_days(z)
    return substr(s, 1, 4) substr(s, 6, 2) substr(s, 9, 2)
}

function recid_match(o, z, base_alld,    zc) {
    zc = zcomp(z)
    if (REC_t[o] == 0) return (REC[o] == zc)
    if (base_alld) return 0
    return (REC[o] == zc substr(SHM[ev], 1, 2) substr(SHM[ev], 4, 2) substr(SHM[ev], 7, 2))
}

function add_entry(ev, m,    z, hm, ss, endz, key, rms, ehm, tp, sd, ed, idx) {
    z = znum8(substr(m, 1, 8))
    if (E_alld[ev]) {
        endz = z + E_span[ev]
        if (z > TODAY_Z || endz < TODAY_Z) return
        key = E_uid[ev] "\x1f" substr(m, 1, 8)
        if (E_span[ev] == 0) {
            tp = "all day"
        } else {
            sd = zcomp(z); ed = zcomp(endz)
            tp = sprintf("%s %d - %s %d", MONAB[substr(sd, 5, 2) + 0], substr(sd, 7, 2) + 0, \
                MONAB[substr(ed, 5, 2) + 0], substr(ed, 7, 2) + 0)
        }
        sk = sprintf("%012d|00:00|%06d", z, ++entseq)
    } else {
        hm = substr(m, 9, 2) ":" substr(m, 11, 2)
        ss = hms_ec(mtime(m)) + E_endoff[ev]
        if (ss < 0) ss = 0
        endz = z + int(ss / 86400)
        rem = ((ss % 86400) + 86400) % 86400
        if (!(z <= TODAY_Z && (endz > TODAY_Z || (endz == TODAY_Z && rem > 0)))) return
        key = E_uid[ev] "\x1f" m
        rms = ((ss % 86400) + 86400) % 86400
        ehm = sprintf("%02d:%02d", int(rms / 3600), int(rms / 60) % 60)
        tp = sprintf("%02d:%02d - %s", substr(m, 9, 2), substr(m, 11, 2), ehm)
        if (endz != z) tp = tp sprintf(" (+%dd)", endz - z)
        sk = sprintf("%012d|%s|%06d", z, hm, ++entseq)
    }
    if (key in ESEEN) return
    ESEEN[key] = 1
    EN++
    ENT_tp[EN] = tp
    ENT_sum[EN] = E_sum[ev]
    ENT_loc[EN] = E_loc[ev]
    ENT_org[EN] = E_org[ev]
    if (E_cx[ev])
        ENT_st[EN] = "    status:    CANCELLED"
    else if (E_status[ev] != "" && E_status[ev] != "CONFIRMED" \
            && E_status[ev] != "PUBLISHED" && E_status[ev] != "TENTATIVE")
        ENT_st[EN] = "    status:    " E_status[ev]
    else
        ENT_st[EN] = ""
    ENT_sk[EN] = sk
    SKIDX[sk] = EN
}

function mtime(m) {
    return substr(m, 9, 2) ":" substr(m, 11, 2) ":" substr(m, 13, 2)
}

# ---------------- main -------------------------------------------------------

BEGIN {
    ne = 0; cur = 0; intz = 0; cal = 0
    buf = ""
    split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", MONAB, " ")
    split("Monday Tuesday Wednesday Thursday Friday Saturday Sunday", WDAY, " ")
    MSALIAS["W. Europe Standard Time"] = "Europe/Berlin"
    MSALIAS["W. Central Europe Standard Time"] = "Europe/Berlin"
    MSALIAS["Eastern Europe Standard Time"] = "Europe/Budapest"
    MSALIAS["GTB Standard Time"] = "Europe/Budapest"
    MSALIAS["FLE Standard Time"] = "Europe/Helsinki"
    MSALIAS["GMT Standard Time"] = "Europe/London"
    MSALIAS["GT Standard Time"] = "Europe/London"
    MSALIAS["Eastern Standard Time"] = "America/New_York"
    MSALIAS["Central Standard Time"] = "America/Chicago"
    MSALIAS["Mountain Standard Time"] = "America/Denver"
    MSALIAS["Pacific Standard Time"] = "America/Los_Angeles"
    DOWMAP["MO"] = 1; DOWMAP["TU"] = 2; DOWMAP["WE"] = 3; DOWMAP["TH"] = 4
    DOWMAP["FR"] = 5; DOWMAP["SA"] = 6; DOWMAP["SU"] = 7
    if (TODAY !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/) {
        printf("error: bad date from caller: %s\n", TODAY) > "/dev/stderr"
        exit 2
    }
    ty = substr(TODAY, 1, 4) + 0; tm = substr(TODAY, 6, 2) + 0; td = substr(TODAY, 9, 2) + 0
    if (tm < 1 || tm > 12 || td < 1 || td > days_in_month(ty, tm)) {
        printf("error: invalid date %s\n", TODAY) > "/dev/stderr"
        exit 2
    }
    TODAY_Z = days_from_civil(ty, tm, td)
    WEEKDAY = WDAY[dow_of(TODAY_Z)]
    entseq = 0; EN = 0
}

{
    line = $0
    sub(/\r$/, "", line)
    if (line ~ /^[ \t]/ && buf != "") { buf = buf substr(line, 2); next }
    if (buf != "") handle(buf)
    buf = (line == "" ? "" : line)
}

END {
    if (buf != "") handle(buf)
    if (!cal) {
        print "error: input does not look like an ICS file (BEGIN:VCALENDAR not found)" > "/dev/stderr"
        exit 1
    }
    for (ev = 1; ev <= ne; ev++) {
        finalize(ev)
        uid = (E_uid[ev] == "" ? "unnamed-" ev : E_uid[ev])
        E_uid[ev] = uid
        if (E_sum[ev] == "") E_sum[ev] = "(no title)"
        if (E_status[ev] == "") E_status[ev] = "CONFIRMED"
        if (!E_inv[ev] && has_s[ev]) {
            if (E_alld[ev]) {
                SZ[ev] = znum8(S_date[ev]); SZS[ev] = S_date[ev]; SHM[ev] = "00:00:00"
            } else {
                SZ[ev] = znum8(substr(S_wall[ev], 1, 8)); SZS[ev] = substr(S_wall[ev], 1, 8)
                SHM[ev] = substr(S_wall[ev], 9, 2) ":" substr(S_wall[ev], 11, 2) ":" substr(S_wall[ev], 13, 2)
            }
        }
        if (REC[ev] != "" && !E_inv[ev]) {
            ov_n[uid]++
            ov_ev[uid, ov_n[uid]] = ev
        }
    }

    for (ev = 1; ev <= ne; ev++) {
        if (REC[ev] != "" || E_inv[ev]) continue
        if (!has_s[ev]) continue
        expand(ev)
        for (k = 1; k <= RD_n[ev]; k++) {
            if (RD_t[ev, k] == 1)
                z2 = znum8(substr(RD_s[ev, k], 1, 8))
            else
                z2 = znum8(RD_s[ev, k])
            if (z2 > TODAY_Z) continue
            if (!(z2 in OCset)) { OC_n++; OC[OC_n] = z2; OCset[z2] = 1 }
        }
        for (i = 1; i <= OC_n; i++) {
            z2 = OC[i]
            if (!occ_touches(ev, z2)) continue
            if (exdate_hit(ev, z2)) continue
            if (E_alld[ev])
                mstr = zcomp(z2)
            else
                mstr = zcomp(z2) substr(SHM[ev], 1, 2) substr(SHM[ev], 4, 2) substr(SHM[ev], 7, 2)
            matched = 0
            for (k = 1; k <= ov_n[E_uid[ev]]; k++) {
                o = ov_ev[E_uid[ev], k]
                if (E_inv[o]) continue
                if (recid_match(o, z2, E_alld[ev])) { matched = o; break }
            }
            if (matched) {
                used[matched] = 1
                if (!E_alld[ev] && REC_t[matched] == 1 \
                        && S_wall[matched] \
                           != zcomp(z2) substr(SHM[ev], 1, 2) substr(SHM[ev], 4, 2) substr(SHM[ev], 7, 2))
                    add_entry(matched, S_wall[matched])
                else
                    add_entry(matched, mstr)
            } else {
                add_entry(ev, mstr)
            }
        }
    }

    for (ev = 1; ev <= ne; ev++) {
        if (E_inv[ev] || REC[ev] == "" || used[ev]) continue
        if (E_alld[ev])
            add_entry(ev, REC[ev])
        else
            add_entry(ev, S_wall[ev])
    }

    if (EN == 0) {
        printf("No calendar entries for %s (%s).\n", TODAY, WEEKDAY)
        exit 0
    }
    width = 0
    for (i = 1; i <= EN; i++)
        if (length(ENT_tp[i]) > width) width = length(ENT_tp[i])
    printf("Calendar entries for %s (%s) - %d:\n\n", TODAY, WEEKDAY, EN)
    delete SORTED
    for (i = 1; i <= EN; i++) SORTED[i] = ENT_sk[i]
    asort(SORTED)
    for (i = 1; i <= EN; i++) {
        idx = SKIDX[SORTED[i]]
        printf("%-*s  %s\n", width, ENT_tp[idx], ENT_sum[idx])
        if (ENT_loc[idx] != "") printf("    location:  %s\n", ENT_loc[idx])
        if (ENT_org[idx] != "") printf("    organizer: %s\n", ENT_org[idx])
        if (ENT_st[idx] != "") printf("%s\n", ENT_st[idx])
        if (i < EN) printf("\n")
    }
    exit 0
}
AWK_EOF

if [ -n "$file" ]; then
    gawk -v TODAY="$d" "$AWK_PROG" < "$file"
else
    gawk -v TODAY="$d" "$AWK_PROG"
fi
