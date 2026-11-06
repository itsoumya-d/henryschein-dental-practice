require "json"
require "sinatra/base"
require "time"
require "date"
require "rack/utils"
require_relative "../dental_practice"

module DentalPractice
  class App < Sinatra::Base
    set :show_exceptions, false
    set :raise_errors, false
    set :logging, false
    set :host_authorization, { permitted_hosts: [] }
    set :practice, nil

    configure do
      set :practice, Practice.seeded
    end

    helpers do
      def practice
        settings.practice
      end

      def payload
        @payload ||= begin
          JSON.parse(request.body.read)
        rescue JSON::ParserError
          raise ValidationError, "request body must be valid JSON"
        end
      end

      def json_response(value, status_code = 200)
        content_type :json
        status status_code
        value.to_json
      end

      def escape(value)
        Rack::Utils.escape_html(value.to_s)
      end

      def money(cents)
        format("$%.2f", cents / 100.0)
      end
    end

    before "/api/*" do
      content_type :json
    end

    get "/health" do
      json_response(status: "ok", service: "henryschein-dental-practice")
    end

    get "/api/patients" do
      json_response(practice.list_patients.map(&:as_json))
    end

    post "/api/patients" do
      patient = practice.add_patient(
        first_name: payload["first_name"],
        last_name: payload["last_name"],
        email: payload["email"],
        phone: payload["phone"],
        recall_months: payload.fetch("recall_months", 6),
        last_visit_on: payload["last_visit_on"]
      )
      json_response(patient.as_json, 201)
    end

    get "/api/appointments" do
      date = params["date"]
      json_response(practice.appointments_on(date).map(&:as_json))
    end

    post "/api/appointments" do
      appointment = practice.schedule_appointment(
        patient_id: payload["patient_id"],
        clinician: payload["clinician"],
        chair: payload["chair"],
        starts_at: payload["starts_at"],
        duration_minutes: payload["duration_minutes"],
        reason: payload["reason"]
      )
      json_response(appointment.as_json, 201)
    end

    post "/api/appointments/:id/status" do
      appointment = practice.update_appointment(params["id"], payload["status"])
      json_response(appointment.as_json)
    end

    post "/api/patients/:id/treatment-plans" do
      plan = practice.create_treatment_plan(patient_id: params["id"], items: payload["items"])
      json_response(plan.as_json, 201)
    end

    post "/api/treatment-plans/:id/accept" do
      plan = practice.accept_plan(params["id"])
      json_response(plan.as_json)
    end

    post "/api/treatment-plans/:id/complete" do
      plan = practice.complete_plan(params["id"])
      json_response(plan.as_json)
    end

    get "/api/claims" do
      json_response(practice.list_claims.map(&:as_json))
    end

    post "/api/claims" do
      claim = practice.create_claim(plan_id: payload["plan_id"])
      json_response(claim.as_json, 201)
    end

    post "/api/claims/:id/status" do
      claim = practice.update_claim(params["id"], payload["status"])
      json_response(claim.as_json)
    end

    get "/api/recalls/overdue" do
      json_response(practice.overdue_recalls.map(&:as_json))
    end

    get "/api/metrics" do
      json_response(practice.metrics)
    end

    get "/api/audit" do
      json_response(practice.audit_log.map(&:as_json))
    end

    get "/" do
      content_type :html
      metrics = practice.metrics
      appointments = practice.appointments_on(Date.today)
      recalls = practice.overdue_recalls
      claims = practice.list_claims

      <<~HTML
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Dental Practice Operations</title>
          <style>
            :root {
              --blue: #0071E3;
              --deep-blue: #0C3FB2;
              --teal: #249195;
              --ink: #181A1D;
              --surface: #ECF5FF;
              --white: #FFFFFF;
              --line: #A6CAFF;
              --muted: #5C6B75;
              --radius: 0px;
              --space: 8px;
            }
            * { box-sizing: border-box; }
            body { margin: 0; background: var(--white); color: var(--ink); font-family: "Red Hat Text", Arial, sans-serif; font-size: 15px; line-height: 1.5; }
            .shell { max-width: 1180px; margin: 0 auto; padding: 40px 28px 24px; }
            header { display: flex; justify-content: space-between; gap: 24px; padding-bottom: 24px; border-bottom: 4px solid var(--blue); }
            h1, h2 { margin: 0; font-family: "Red Hat Text", Arial, sans-serif; }
            h1 { font-size: clamp(30px, 4vw, 48px); line-height: 1.05; letter-spacing: -0.02em; }
            h2 { font-size: 18px; }
            .eyebrow { margin: 0 0 8px; color: var(--teal); font-size: 12px; font-weight: 700; letter-spacing: 0.12em; text-transform: uppercase; }
            .lede { max-width: 650px; margin: 12px 0 0; color: var(--muted); font-size: 16px; }
            .badge { flex: none; align-self: flex-start; padding: 6px 10px; background: var(--surface); color: var(--deep-blue); font-size: 12px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.08em; }
            .metrics { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); gap: 12px; margin: 24px 0; }
            .metric { padding: 16px; background: var(--surface); border-top: 3px solid var(--blue); }
            .metric span { display: block; color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: 0.05em; }
            .metric strong { display: block; margin-top: 8px; font-size: 22px; line-height: 1.15; color: var(--deep-blue); }
            .grid { display: grid; grid-template-columns: 1.35fr 1fr; gap: 16px; }
            .panel { border: 1px solid var(--line); }
            .panel-head { display: flex; justify-content: space-between; gap: 12px; padding: 16px 18px; background: var(--surface); border-bottom: 1px solid var(--line); }
            .panel-head span { color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: 0.06em; }
            table { width: 100%; border-collapse: collapse; text-align: left; }
            th { padding: 10px 14px; color: var(--muted); font-size: 11px; text-transform: uppercase; letter-spacing: 0.06em; border-bottom: 1px solid var(--line); }
            td { padding: 12px 14px; border-bottom: 1px solid #E6DED7; vertical-align: top; }
            tr:last-child td { border-bottom: 0; }
            td small { display: block; color: var(--muted); font-size: 12px; }
            .num { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
            .recalls { grid-row: span 2; }
            .recalls li { padding: 12px 18px; border-bottom: 1px solid #E6DED7; list-style: none; }
            .recalls ul { margin: 0; padding: 0; }
            .recalls strong { display: block; }
            footer { display: flex; justify-content: space-between; gap: 16px; margin-top: 24px; padding-top: 16px; border-top: 1px solid var(--line); color: var(--muted); font-size: 12px; }
            @media (max-width: 860px) { .metrics { grid-template-columns: repeat(2, minmax(0, 1fr)); } .grid { grid-template-columns: 1fr; } .recalls { grid-row: auto; } }
          </style>
        </head>
        <body>
          <div class="shell">
            <header>
              <div>
                <p class="eyebrow">Dental operations</p>
                <h1>Practice Command Centre</h1>
                <p class="lede">Appointments, treatment acceptance, recalls and claims in one operating view for a modern dental practice.</p>
              </div>
              <span class="badge">Live schedule</span>
            </header>

            <section class="metrics">
              <div class="metric"><span>Appointments today</span><strong>#{metrics[:appointments]}</strong></div>
              <div class="metric"><span>Completed</span><strong>#{metrics[:completed]}</strong></div>
              <div class="metric"><span>No-show rate</span><strong>#{metrics[:no_show_rate_percent]}%</strong></div>
              <div class="metric"><span>Treatment acceptance</span><strong>#{metrics[:treatment_acceptance_percent]}%</strong></div>
              <div class="metric"><span>Accepted claim revenue</span><strong>#{money(metrics[:accepted_claim_revenue_cents])}</strong></div>
            </section>

            <main class="grid">
              <section class="panel">
                <div class="panel-head"><h2>Today's schedule</h2><span>#{appointments.length} appointments</span></div>
                <table>
                  <thead><tr><th>Time</th><th>Patient</th><th>Clinician</th><th>Chair</th><th>Status</th></tr></thead>
                  <tbody>
                    #{appointments.map { |appointment|
                      patient = practice.find_patient!(appointment.patient_id)
                      "<tr><td>#{appointment.starts_at.strftime("%H:%M")}</td><td><strong>#{escape(patient.name)}</strong><small>#{escape(appointment.reason)}</small></td><td>#{escape(appointment.clinician)}</td><td>#{escape(appointment.chair)}</td><td>#{escape(appointment.status)}</td></tr>"
                    }.join}
                  </tbody>
                </table>
              </section>

              <section class="panel recalls">
                <div class="panel-head"><h2>Overdue recalls</h2><span>#{recalls.length} patients</span></div>
                <ul>
                  #{recalls.map { |patient| "<li><strong>#{escape(patient.name)}</strong><small>Due #{patient.recall_due_on.iso8601} · #{escape(patient.phone)}</small></li>" }.join}
                </ul>
              </section>

              <section class="panel">
                <div class="panel-head"><h2>Claims</h2><span>#{claims.length} submitted</span></div>
                <table>
                  <thead><tr><th>Claim</th><th>Status</th><th class="num">Amount</th></tr></thead>
                  <tbody>
                    #{claims.map { |claim| "<tr><td>#{escape(claim.id)}</td><td>#{escape(claim.status)}</td><td class=\"num\">#{money(claim.amount_cents)}</td></tr>" }.join}
                  </tbody>
                </table>
              </section>
            </main>

            <footer>
              <span>Ruby · Sinatra · append-only audit · conflict-safe scheduling</span>
              <span>Reference implementation for Henry Schein One</span>
            </footer>
          </div>
        </body>
        </html>
      HTML
    end

    error ValidationError do
      json_response({ error: env["sinatra.error"].message }, 400)
    end

    error ConflictError do
      json_response({ error: env["sinatra.error"].message }, 409)
    end

    error NotFoundError do
      json_response({ error: env["sinatra.error"].message }, 404)
    end

    error do
      json_response({ error: "unexpected error" }, 500)
    end
  end
end
