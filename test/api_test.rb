require "minitest/autorun"
require "rack/test"
require "json"
require "time"
require_relative "../lib/dental_practice"
require_relative "../lib/dental_practice/app"

class ApiTest < Minitest::Test
  include Rack::Test::Methods

  def app
    DentalPractice::App
  end

  def setup
    @practice = DentalPractice::Practice.new(clock: -> { Time.parse("2026-11-06 08:00:00") })
    DentalPractice::App.set :practice, @practice
  end

  def json
    JSON.parse(last_response.body)
  end

  def post_json(path, payload)
    post path, JSON.generate(payload), "CONTENT_TYPE" => "application/json"
  end

  def create_patient
    p = @practice.add_patient(
      first_name: "Amelia", last_name: "Brown", email: "amelia@example.com",
      phone: "021 555 0101", recall_months: 6, last_visit_on: Date.new(2026, 3, 1)
    )
    p
  end

  def test_health
    get "/health"
    assert_equal 200, last_response.status
    assert_equal "ok", json["status"]
  end

  def test_lists_and_creates_patients
    get "/api/patients"
    assert_equal 200, last_response.status
    assert_equal [], json

    post_json "/api/patients", {
      first_name: "Amelia", last_name: "Brown", email: "amelia@example.com",
      phone: "021 555 0101", recall_months: 6, last_visit_on: "2026-03-01"
    }
    assert_equal 201, last_response.status
    assert_equal "Amelia Brown", json["name"]
    assert_equal "2026-09-01", json["recall_due_on"]
  end

  def test_patient_validation_error
    post_json "/api/patients", { first_name: "", last_name: "Brown", email: "bad" }
    assert_equal 400, last_response.status
    assert_match(/first_name/, json["error"])
  end

  def test_schedules_appointment_and_rejects_conflict
    patient = create_patient
    payload = {
      patient_id: patient.id, clinician: "Dr Chen", chair: "Chair 1",
      starts_at: "2026-11-06T09:00:00+13:00", duration_minutes: 30, reason: "Exam"
    }
    post_json "/api/appointments", payload
    assert_equal 201, last_response.status
    assert_equal "scheduled", json["status"]

    post_json "/api/appointments", payload.merge(chair: "Chair 2", starts_at: "2026-11-06T09:15:00+13:00")
    assert_equal 409, last_response.status
    assert_match(/clinician/, json["error"])
  end

  def test_lists_appointments_for_a_date
    patient = create_patient
    @practice.schedule_appointment(
      patient_id: patient.id, clinician: "Dr Chen", chair: "Chair 1",
      starts_at: "2026-11-06T09:00:00+13:00", duration_minutes: 30, reason: "Exam"
    )
    get "/api/appointments?date=2026-11-06"
    assert_equal 200, last_response.status
    assert_equal 1, json.length
    assert_equal "Exam", json.first["reason"]
  end

  def test_updates_appointment_status
    patient = create_patient
    appointment = @practice.schedule_appointment(
      patient_id: patient.id, clinician: "Dr Chen", chair: "Chair 1",
      starts_at: "2026-11-06T09:00:00+13:00", duration_minutes: 30
    )
    post_json "/api/appointments/#{appointment.id}/status", { status: "completed" }
    assert_equal 200, last_response.status
    assert_equal "completed", json["status"]
  end

  def test_unknown_appointment_returns_404
    post_json "/api/appointments/missing/status", { status: "completed" }
    assert_equal 404, last_response.status
  end

  def test_treatment_plan_accept_and_complete
    patient = create_patient
    post_json "/api/patients/#{patient.id}/treatment-plans", {
      items: [{ code: "D111", description: "Exam", fee_cents: 18_000 }]
    }
    assert_equal 201, last_response.status
    plan_id = json["id"]
    assert_equal 18_000, json["total_cents"]

    post "/api/treatment-plans/#{plan_id}/accept"
    assert_equal 200, last_response.status
    assert_equal "accepted", json["status"]

    post "/api/treatment-plans/#{plan_id}/complete"
    assert_equal 200, last_response.status
    assert_equal "completed", json["status"]
  end

  def test_claim_creation_and_status
    patient = create_patient
    plan = @practice.create_treatment_plan(
      patient_id: patient.id,
      items: [{ "code" => "D111", "description" => "Exam", "fee_cents" => 18_000 }]
    )
    @practice.accept_plan(plan.id)
    @practice.complete_plan(plan.id)

    post_json "/api/claims", { plan_id: plan.id }
    assert_equal 201, last_response.status
    assert_equal 18_000, json["amount_cents"]
    claim_id = json["id"]

    post_json "/api/claims/#{claim_id}/status", { status: "accepted" }
    assert_equal 200, last_response.status
    assert_equal "accepted", json["status"]

    get "/api/claims"
    assert_equal 1, json.length
  end

  def test_claim_rejects_incomplete_plan
    patient = create_patient
    plan = @practice.create_treatment_plan(
      patient_id: patient.id,
      items: [{ "code" => "D111", "description" => "Exam", "fee_cents" => 18_000 }]
    )
    post_json "/api/claims", { plan_id: plan.id }
    assert_equal 409, last_response.status
  end

  def test_recalls_and_metrics
    create_patient
    get "/api/recalls/overdue"
    assert_equal 200, last_response.status
    assert_equal 1, json.length
    assert_equal "Amelia Brown", json.first["name"]

    get "/api/metrics"
    assert_equal 200, last_response.status
    assert_equal 1, json["active_patients"]
    assert_equal 1, json["overdue_recalls"]
  end

  def test_audit_endpoint
    create_patient
    get "/api/audit"
    assert_equal 200, last_response.status
    assert_equal "patient.created", json.first["action"]
  end

  def test_dashboard_renders
    create_patient
    get "/"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "Practice Command Centre"
    assert_includes last_response.body, "Amelia Brown"
  end
end
