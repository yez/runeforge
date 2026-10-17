---
title: Calendar feed and booking screens
max_attempts: 5
---

# Courtside: calendar feed and booking screens

Courtside is the existing court-booking app in this repository (see README.md and CLAUDE.md).
Build the items below in order. Each item should leave the app running and `npm test` passing.
The routes, formats and `data-testid` attributes below are exact: the app is checked against them
by tests you will not see, including browser tests against `npm start`. Everything that already
works must keep working.

Conventions: local times are club wall time `YYYY-MM-DDTHH:mm` (America/New_York); instants are
UTC ISO strings; errors are `{ "error": "..." }` with 400 / 401 / 403 / 404 / 409 as elsewhere.

- [ ] iCalendar feed.
  `GET /api/members/:id/calendar.ics` returns the member's bookings as an RFC 5545 calendar with
  `Content-Type: text/calendar`, CRLF line endings, `BEGIN:VCALENDAR`, `VERSION:2.0`, a `PRODID`,
  and a `VTIMEZONE` for `TZID:America/New_York`. Calendar apps can't send headers, so it accepts
  the token as `Authorization: Bearer` or as `?token=`. That member or an admin (401 without a
  valid token, 403 for another member, 404 for an unknown member).
  - One `VEVENT` per active booking that isn't part of a series: `UID:booking-<id>@courtside`,
    `DTSTAMP`, `DTSTART;TZID=America/New_York:YYYYMMDDTHHMMSS` and `DTEND` the same way, in local
    time, and `SUMMARY` set to the court's name, or `Lesson with <coach name> on <court name>`.
    Cancelled bookings are left out.
  - One `VEVENT` per series with at least one active booking: `UID:series-<id>@courtside`,
    `DTSTART`/`DTEND` of the first week in local time as above, `RRULE:FREQ=WEEKLY;COUNT=<weeks>`,
    and one `EXDATE;TZID=America/New_York:...` for every week that has no active booking (skipped
    or cancelled), with the same `SUMMARY` rule. A split series is two events (the original with
    its reduced weeks, and the new one).
  - Expanded, the feed's events are exactly the member's active bookings.

- [ ] Member week grid.
  UI: a new screen at `/book`, linked from the navigation for members, to see a court's week and
  book by clicking.
  - A court picker (`data-testid="court-select"`, a `<select>` with the courts' names as option
    labels) and week navigation (`week-prev`, `week-next`) above a grid of the week Monday to
    Sunday, starting with the current week (the club's today). Rows are 30-minute slots from 07:00
    to 21:30.
  - Every cell has `data-testid="slot-<local start>"` (e.g. `slot-2026-03-10T18:00`) and
    `data-state`: `past` (its start is not in the future), `closed` (a closure of that court or all
    courts overlaps it), `mine` (the signed-in member's active booking overlaps it), `booked`
    (someone else's active booking does), or `free`, taking the first that applies in that order.
  - Clicking a free cell books 60 minutes from that cell for the signed-in member and updates the
    grid (both cells of the hour become `mine`). If the booking is refused, the API's error message
    is shown in an element with `data-testid="booking-error"` and the grid is unchanged.
  - At phone width (600px wide and narrower) only one day's cells are visible at a time (initially
    today's, or Monday in another week), with `day-prev` and `day-next` buttons to move between
    the week's days. No horizontal page scroll at 390px.
  - Match the existing screens' look; make the states easy to tell apart.

- [ ] Admin closures screen.
  UI: a new screen at `/admin/closures`, linked from the navigation for admins, to manage closures.
  - A table of closures, each row `data-testid="closure-row-<id>"` showing the court (or "All
    courts"), when, and the reason, with a delete button `closure-delete-<id>` that deletes it at
    once (no confirmation dialog) and removes the row.
  - A form: `closure-court` (a `<select>` whose options are "All courts" and each court's name),
    `closure-start` and `closure-end` (`<input type="datetime-local">`), `closure-reason`, and
    `closure-submit`. After a successful submit, an element `closure-result` says how many bookings
    were cancelled, as a number (e.g. "Closure added. Cancelled 2 bookings."), and the new row
    appears. A refused submit shows the API's error in `closure-error`.
  - Members who open `/admin/closures` see no closure form, only a short "Admins only" message.
  - Works at phone width: no horizontal page scroll at 390px.
