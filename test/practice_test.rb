require "minitest/autorun"
require "date"
require "time"
require_relative "../lib/dental_practice"

class PracticeTest < Minitest::Test
  NOW = Time.parse("2026-11-06 08:00:00")

  def setup
    @practice = DentalPractice::Practice.new(clock: -> { NOW })
    @patient = @practice.add_patient(
      first_name: "Amelia",
      last_name: "Brown",
      email: "amelia@example.com",
      phone: "021 555 0101",
      recall_months: 6,
      last_visit_on: Date.new(2026, 3, 1)
    )
  end

  def schedule(overrides = {})
    base = {
      patient_id: @patient.id,
      clinician: "Dr Chen",
      chair: "Chair 1",
      starts_at: "2026-11-06T09:00:00+13:00",
      duration_minutes: 30,
      reason: "Exam"
    }
    @practice.schedule_appointment(**base.merge(overrides))
  end

  def test_adds_patient_with_normalised_email
    patient = @practice.add_patient(
      first_name: "Jack",
      last_name: "Wilson",
      email: " JACK@EXAMPLE.COM "
    )
    assert_equal "jack@example.com", patient.email
    assert_equal 6, patient.recall_months
  end

  def test_rejects_duplicate_patient_email
    error = assert_raises(DentalPractice::ConflictError) do
      @practice.add_patient(first_name: "Other", last_name: "Patient", email: "AMELIA@example.com")
    end
    assert_match(/already exists/, error.message)
  end

  def test_rejects_invalid_patient_fields
    assert_raises(DentalPractice::ValidationError) do
      @practice.add_patient(first_name: "", last_name: "Brown", email: "a@b.com")
    end
    assert_raises(DentalPractice::ValidationError) do
      @practice.add_patient(first_name: "A", last_name: "B", email: "not-an-email")
    end
    assert_raises(DentalPractice::ValidationError) do
      @practice.add_patient(first_name: "A", last_name: "B", email: "a@b.com", recall_months: 30)
    end
  end

  def test_computes_recall_due_date
    assert_equal Date.new(2026, 9, 1), @patient.recall_due_on
  end

  def test_schedules_appointment
    appointment = schedule
    assert_equal "scheduled", appointment.status
    assert_equal 30, appointment.duration_minutes
    assert_equal appointment.starts_at + (30 * 60), appointment.ends_at
  end

  def test_rejects_clinician_overlap
    schedule
    error = assert_raises(DentalPractice::ConflictError) do
      schedule(chair: "Chair 2", starts_at: "2026-11-06T09:15:00+13:00")
    end
    assert_match(/clinician/, error.message)
  end

  def test_rejects_chair_overlap
    schedule
    error = assert_raises(DentalPractice::ConflictError) do
      schedule(clinician: "Dr Patel", starts_at: "2026-11-06T09:15:00+13:00")
    end
    assert_match(/chair/, error.message)
  end

  def test_allows_adjacent_appointments
    schedule
    appointment = schedule(clinician: "Dr Patel", starts_at: "2026-11-06T09:30:00+13:00")
    assert_equal "scheduled", appointment.status
  end

  def test_cancelled_appointment_frees_the_slot
    appointment = schedule
    @practice.update_appointment(appointment.id, "cancelled")
    replacement = schedule(clinician: "Dr Patel", starts_at: "2026-11-06T09:15:00+13:00")
    assert_equal "scheduled", replacement.status
  end

  def test_rejects_outside_office_hours
    assert_raises(DentalPractice::ValidationError) do
      schedule(starts_at: "2026-11-06T06:45:00+13:00")
    end
    assert_raises(DentalPractice::ValidationError) do
      schedule(starts_at: "2026-11-06T18:45:00+13:00", duration_minutes: 30)
    end
  end

  def test_rejects_invalid_duration
    assert_raises(DentalPractice::ValidationError) do
      schedule(duration_minutes: 20)
    end
  end

  def test_completion_updates_the_patient_last_visit
    appointment = schedule
    @practice.update_appointment(appointment.id, "completed")
    assert_equal Date.new(2026, 11, 6), @patient.last_visit_on
  end

  def test_rejects_invalid_appointment_status
    appointment = schedule
    assert_raises(DentalPractice::ValidationError) do
      @practice.update_appointment(appointment.id, "lost")
    end
  end

  def test_missing_appointment_raises_not_found
    assert_raises(DentalPractice::NotFoundError) do
      @practice.update_appointment("missing", "completed")
    end
  end

  def test_treatment_plan_total_and_acceptance
    plan = @practice.create_treatment_plan(
      patient_id: @patient.id,
      items: [
        { "code" => "D111", "description" => "Exam", "fee_cents" => 18_000 },
        { "code" => "D211", "description" => "Restoration", "tooth" => "26", "fee_cents" => 32_000 }
      ]
    )
    assert_equal 50_000, plan.total_cents
    assert_equal "proposed", plan.status
    accepted = @practice.accept_plan(plan.id)
    assert_equal "accepted", accepted.status
  end

  def test_cannot_complete_an_unaccepted_plan
    plan = @practice.create_treatment_plan(
      patient_id: @patient.id,
      items: [{ "code" => "D111", "description" => "Exam", "fee_cents" => 18_000 }]
    )
    assert_raises(DentalPractice::ConflictError) { @practice.complete_plan(plan.id) }
  end

  def test_completes_an_accepted_plan
    plan = @practice.create_treatment_plan(
      patient_id: @patient.id,
      items: [{ "code" => "D111", "description" => "Exam", "fee_cents" => 18_000 }]
    )
    @practice.accept_plan(plan.id)
    completed = @practice.complete_plan(plan.id)
    assert_equal "completed", completed.status
    assert_equal Date.new(2026, 11, 6), completed.completed_on
    assert_equal "completed", completed.items.first.status
  end

  def test_claim_requires_a_completed_plan
    plan = @practice.create_treatment_plan(
      patient_id: @patient.id,
      items: [{ "code" => "D111", "description" => "Exam", "fee_cents" => 18_000 }]
    )
    assert_raises(DentalPractice::ConflictError) { @practice.create_claim(plan_id: plan.id) }
  end

  def test_creates_and_updates_a_claim
    plan = @practice.create_treatment_plan(
      patient_id: @patient.id,
      items: [{ "code" => "D111", "description" => "Exam", "fee_cents" => 18_000 }]
    )
    @practice.accept_plan(plan.id)
    @practice.complete_plan(plan.id)
    claim = @practice.create_claim(plan_id: plan.id)
    assert_equal 18_000, claim.amount_cents
    assert_equal "submitted", claim.status
    updated = @practice.update_claim(claim.id, "accepted")
    assert_equal "accepted", updated.status
  end

  def test_rejects_duplicate_claim
    plan = @practice.create_treatment_plan(
      patient_id: @patient.id,
      items: [{ "code" => "D111", "description" => "Exam", "fee_cents" => 18_000 }]
    )
    @practice.accept_plan(plan.id)
    @practice.complete_plan(plan.id)
    @practice.create_claim(plan_id: plan.id)
    assert_raises(DentalPractice::ConflictError) { @practice.create_claim(plan_id: plan.id) }
  end

  def test_overdue_recalls_only_includes_past_due_patients
    overdue = @practice.overdue_recalls
    assert_equal [@patient.id], overdue.map(&:id)

    recent = @practice.add_patient(
      first_name: "Recent", last_name: "Visit", email: "recent@example.com",
      last_visit_on: Date.new(2026, 10, 1)
    )
    refute_includes @practice.overdue_recalls.map(&:id), recent.id
  end

  def test_metrics_compute_no_show_and_acceptance
    appointment = schedule
    @practice.update_appointment(appointment.id, "no_show")
    plan = @practice.create_treatment_plan(
      patient_id: @patient.id,
      items: [{ "code" => "D111", "description" => "Exam", "fee_cents" => 18_000 }]
    )
    @practice.accept_plan(plan.id)
    @practice.complete_plan(plan.id)
    claim = @practice.create_claim(plan_id: plan.id)
    @practice.update_claim(claim.id, "accepted")

    metrics = @practice.metrics
    assert_equal 1, metrics[:appointments]
    assert_equal 1, metrics[:no_show]
    assert_equal 100.0, metrics[:no_show_rate_percent]
    assert_equal 100.0, metrics[:treatment_acceptance_percent]
    assert_equal 18_000, metrics[:accepted_claim_revenue_cents]
    assert_equal 1, metrics[:overdue_recalls]
  end

  def test_audit_log_is_append_only_and_ordered
    schedule
    actions = @practice.audit_log.map(&:action)
    assert_equal %w[patient.created appointment.scheduled], actions
  end

  def test_missing_patient_raises_not_found
    assert_raises(DentalPractice::NotFoundError) do
      @practice.schedule_appointment(
        patient_id: "missing", clinician: "Dr Chen", chair: "Chair 1",
        starts_at: "2026-11-06T09:00:00+13:00", duration_minutes: 30
      )
    end
  end
end
