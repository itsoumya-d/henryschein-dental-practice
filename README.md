# henryschein-dental-practice

A Ruby/Sinatra dental practice operations service: patient records,
conflict-safe appointment scheduling, treatment plans, claims, recalls,
practice metrics and an append-only audit trail, with a server-rendered
operations dashboard.

This is an independent reference implementation of the workflows Henry Schein
One serves for dental practice management.

## Why this exists

A dental practice runs on a shared schedule. A double-booked chair or clinician
is not a minor UI bug; it is a patient turned away and a clinician idle. A
treatment plan is only useful if acceptance, completion and a claim can be
followed in order, and a recall is only useful if it is measured against the
patient's actual last visit. This service makes those rules explicit and
testable.

## Formulas

```text
appointmentEnd = startsAt + durationMinutes
overlap        = startA < endB AND startB < endA
recallDueOn    = lastVisitOn >> recallMonths
noShowRate     = noShowAppointments / totalAppointments * 100
acceptanceRate = acceptedPlans / (proposedPlans + acceptedPlans) * 100
claimTotal     = sum(treatment item fees) for a completed plan
```

An appointment is rejected if either its clinician or its chair overlaps an
active appointment. An appointment must be in 15-minute increments, between
07:00 and 19:00, and finish by 19:00. A claim can only be created once, from a
completed treatment plan.

## API

| Method | Route | Purpose |
|---|---|---|
| GET | `/health` | Liveness probe |
| GET | `/api/patients` | List patients and recall dates |
| POST | `/api/patients` | Register a patient |
| GET | `/api/appointments?date=YYYY-MM-DD` | Day schedule |
| POST | `/api/appointments` | Schedule with conflict checks |
| POST | `/api/appointments/:id/status` | Complete, cancel or mark no-show |
| POST | `/api/patients/:id/treatment-plans` | Create a plan with priced items |
| POST | `/api/treatment-plans/:id/accept` | Record acceptance |
| POST | `/api/treatment-plans/:id/complete` | Complete an accepted plan |
| GET | `/api/claims` | List claims |
| POST | `/api/claims` | Create a claim from a completed plan |
| POST | `/api/claims/:id/status` | Accept or reject a claim |
| GET | `/api/recalls/overdue` | Patients past their recall date |
| GET | `/api/metrics` | Daily operations metrics |
| GET | `/api/audit` | Append-only audit events |
| GET | `/` | Practice Command Centre dashboard |

## Run

```bash
bundle install
bundle exec puma -b tcp://0.0.0.0:8096 config.ru
```

The server listens on `:8096` and seeds three patients, a day schedule, a
completed treatment plan, an accepted claim and overdue recalls.

## Test

```bash
bundle exec rake test
```

The Minitest suite covers patient validation and duplicate emails, recall
dates, appointment scheduling, clinician and chair conflicts, adjacent slots,
cancellation, office hours, treatment plan totals and state transitions,
claim rules, duplicate claims, recall detection, no-show and acceptance
metrics, the audit log, API validation/404/409 paths and dashboard rendering.

## Design tokens

From Henry Schein One's public site:

- Body/heading: Red Hat Text
- Primary blue: `#0071E3`
- Deep blue: `#0C3FB2`
- Teal: `#249195`
- Ink: `#181A1D`
- Surface: `#ECF5FF`
- Line: `#A6CAFF`
- Background: `#FFFFFF`
- Radius: `0px`
- Spacing unit: `8px`

## Docker

```bash
docker build -t henryschein-dental-practice .
docker run --rm -p 8096:8096 henryschein-dental-practice
```
