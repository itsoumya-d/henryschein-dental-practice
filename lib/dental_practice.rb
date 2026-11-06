require "date"
require "securerandom"
require "time"

module DentalPractice
  class Error < StandardError; end
  class ValidationError < Error; end
  class ConflictError < Error; end
  class NotFoundError < Error; end

  class Patient
    attr_reader :id, :first_name, :last_name, :email, :phone, :recall_months
    attr_accessor :last_visit_on

    def initialize(id:, first_name:, last_name:, email:, phone:, recall_months: 6, last_visit_on: nil)
      @id = id
      @first_name = first_name
      @last_name = last_name
      @email = email
      @phone = phone
      @recall_months = recall_months
      @last_visit_on = last_visit_on
    end

    def name
      "#{first_name} #{last_name}"
    end

    def recall_due_on
      return nil unless last_visit_on

      last_visit_on >> recall_months
    end

    def as_json
      {
        id: id,
        name: name,
        first_name: first_name,
        last_name: last_name,
        email: email,
        phone: phone,
        recall_months: recall_months,
        last_visit_on: last_visit_on&.iso8601,
        recall_due_on: recall_due_on&.iso8601
      }
    end
  end

  class Appointment
    attr_reader :id, :patient_id, :clinician, :chair, :starts_at, :duration_minutes, :reason
    attr_accessor :status

    def initialize(id:, patient_id:, clinician:, chair:, starts_at:, duration_minutes:, reason:, status: "scheduled")
      @id = id
      @patient_id = patient_id
      @clinician = clinician
      @chair = chair
      @starts_at = starts_at
      @duration_minutes = duration_minutes
      @reason = reason
      @status = status
    end

    def ends_at
      starts_at + (duration_minutes * 60)
    end

    def active?
      %w[scheduled completed].include?(status)
    end

    def as_json
      {
        id: id,
        patient_id: patient_id,
        clinician: clinician,
        chair: chair,
        starts_at: starts_at.iso8601,
        ends_at: ends_at.iso8601,
        duration_minutes: duration_minutes,
        reason: reason,
        status: status
      }
    end
  end

  class TreatmentItem
    attr_reader :code, :description, :tooth, :fee_cents
    attr_accessor :status

    def initialize(code:, description:, tooth:, fee_cents:, status: "proposed")
      @code = code
      @description = description
      @tooth = tooth
      @fee_cents = fee_cents
      @status = status
    end

    def as_json
      {
        code: code,
        description: description,
        tooth: tooth,
        fee_cents: fee_cents,
        status: status
      }
    end
  end

  class TreatmentPlan
    attr_reader :id, :patient_id, :items, :created_on
    attr_accessor :status, :accepted_on, :completed_on

    def initialize(id:, patient_id:, items:, created_on:, status: "proposed", accepted_on: nil, completed_on: nil)
      @id = id
      @patient_id = patient_id
      @items = items
      @created_on = created_on
      @status = status
      @accepted_on = accepted_on
      @completed_on = completed_on
    end

    def total_cents
      items.sum(&:fee_cents)
    end

    def as_json
      {
        id: id,
        patient_id: patient_id,
        items: items.map(&:as_json),
        total_cents: total_cents,
        status: status,
        created_on: created_on.iso8601,
        accepted_on: accepted_on&.iso8601,
        completed_on: completed_on&.iso8601
      }
    end
  end

  class Claim
    attr_reader :id, :plan_id, :patient_id, :amount_cents, :submitted_on
    attr_accessor :status

    def initialize(id:, plan_id:, patient_id:, amount_cents:, submitted_on:, status: "submitted")
      @id = id
      @plan_id = plan_id
      @patient_id = patient_id
      @amount_cents = amount_cents
      @submitted_on = submitted_on
      @status = status
    end

    def as_json
      {
        id: id,
        plan_id: plan_id,
        patient_id: patient_id,
        amount_cents: amount_cents,
        status: status,
        submitted_on: submitted_on.iso8601
      }
    end
  end

  class AuditEvent
    attr_reader :id, :at, :action, :entity, :entity_id, :detail

    def initialize(id:, at:, action:, entity:, entity_id:, detail:)
      @id = id
      @at = at
      @action = action
      @entity = entity
      @entity_id = entity_id
      @detail = detail
    end

    def as_json
      {
        id: id,
        at: at.iso8601,
        action: action,
        entity: entity,
        entity_id: entity_id,
        detail: detail
      }
    end
  end

  class Practice
    EMAIL_PATTERN = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/
    APPOINTMENT_STATUSES = %w[scheduled completed cancelled no_show].freeze
    CLAIM_STATUSES = %w[submitted accepted rejected].freeze

    attr_reader :audit_log

    def initialize(clock: -> { Time.now })
      @clock = clock
      @patients = {}
      @appointments = {}
      @plans = {}
      @claims = {}
      @audit_log = []
    end

    def today
      @clock.call.to_date
    end

    def add_patient(first_name:, last_name:, email:, phone: "", recall_months: 6, last_visit_on: nil)
      first_name = first_name.to_s.strip
      last_name = last_name.to_s.strip
      email = email.to_s.strip.downcase
      raise ValidationError, "first_name is required" if first_name.empty?
      raise ValidationError, "last_name is required" if last_name.empty?
      raise ValidationError, "email is invalid" unless EMAIL_PATTERN.match?(email)
      raise ValidationError, "recall_months must be between 1 and 24" unless (1..24).cover?(recall_months.to_i)
      if @patients.values.any? { |patient| patient.email == email }
        raise ConflictError, "a patient with that email already exists"
      end

      visit = parse_date(last_visit_on)
      patient = Patient.new(
        id: next_id("pat"),
        first_name: first_name,
        last_name: last_name,
        email: email,
        phone: phone.to_s.strip,
        recall_months: recall_months.to_i,
        last_visit_on: visit
      )
      @patients[patient.id] = patient
      audit("patient.created", "patient", patient.id, { email: email })
      patient
    end

    def list_patients
      @patients.values.sort_by(&:last_name)
    end

    def find_patient!(id)
      @patients.fetch(id)
    rescue KeyError
      raise NotFoundError, "patient not found"
    end

    def schedule_appointment(patient_id:, clinician:, chair:, starts_at:, duration_minutes:, reason: "")
      find_patient!(patient_id)
      clinician = clinician.to_s.strip
      chair = chair.to_s.strip
      raise ValidationError, "clinician is required" if clinician.empty?
      raise ValidationError, "chair is required" if chair.empty?
      duration = duration_minutes.to_i
      raise ValidationError, "duration_minutes must be between 15 and 240" unless (15..240).cover?(duration) && duration % 15 == 0

      start = parse_time(starts_at)
      raise ValidationError, "appointment must be between 07:00 and 19:00" unless start.hour >= 7 && start.hour < 19

      finish = start + (duration * 60)
      if start.hour == 19 && start.min.positive?
        raise ValidationError, "appointment must finish by 19:00"
      end
      raise ValidationError, "appointment must finish by 19:00" if finish.hour > 19 || (finish.hour == 19 && finish.min.positive?)

      conflict = @appointments.values.find do |appointment|
        appointment.active? &&
          overlaps?(start, finish, appointment.starts_at, appointment.ends_at) &&
          (appointment.clinician == clinician || appointment.chair == chair)
      end
      if conflict
        raise ConflictError, "#{conflict.clinician == clinician ? "clinician" : "chair"} is already booked"
      end

      appointment = Appointment.new(
        id: next_id("apt"),
        patient_id: patient_id,
        clinician: clinician,
        chair: chair,
        starts_at: start,
        duration_minutes: duration,
        reason: reason.to_s.strip
      )
      @appointments[appointment.id] = appointment
      audit("appointment.scheduled", "appointment", appointment.id, { clinician: clinician, chair: chair })
      appointment
    end

    def appointments_on(date)
      day = parse_date(date) || today
      @appointments.values
        .select { |appointment| appointment.starts_at.to_date == day }
        .sort_by(&:starts_at)
    end

    def update_appointment(id, status)
      status = status.to_s
      raise ValidationError, "invalid appointment status" unless APPOINTMENT_STATUSES.include?(status)

      appointment = @appointments.fetch(id)
      appointment.status = status
      if status == "completed"
        patient = find_patient!(appointment.patient_id)
        patient.last_visit_on = appointment.starts_at.to_date if patient.last_visit_on.nil? || appointment.starts_at.to_date > patient.last_visit_on
      end
      audit("appointment.#{status}", "appointment", id, {})
      appointment
    rescue KeyError
      raise NotFoundError, "appointment not found"
    end

    def create_treatment_plan(patient_id:, items:)
      find_patient!(patient_id)
      raise ValidationError, "items must not be empty" if !items.is_a?(Array) || items.empty?

      treatment_items = items.map do |item|
        code = item["code"] || item[:code]
        description = item["description"] || item[:description]
        tooth = item["tooth"] || item[:tooth]
        fee = (item["fee_cents"] || item[:fee_cents]).to_i
        raise ValidationError, "treatment code is required" if code.to_s.strip.empty?
        raise ValidationError, "treatment fee must be positive" unless fee.positive?

        TreatmentItem.new(code: code.to_s, description: description.to_s, tooth: tooth, fee_cents: fee)
      end

      plan = TreatmentPlan.new(
        id: next_id("plan"),
        patient_id: patient_id,
        items: treatment_items,
        created_on: today
      )
      @plans[plan.id] = plan
      audit("treatment_plan.created", "treatment_plan", plan.id, { total_cents: plan.total_cents })
      plan
    end

    def accept_plan(id)
      plan = find_plan!(id)
      raise ConflictError, "only proposed plans can be accepted" unless plan.status == "proposed"

      plan.status = "accepted"
      plan.accepted_on = today
      audit("treatment_plan.accepted", "treatment_plan", id, { total_cents: plan.total_cents })
      plan
    end

    def complete_plan(id)
      plan = find_plan!(id)
      raise ConflictError, "only accepted plans can be completed" unless plan.status == "accepted"

      plan.status = "completed"
      plan.completed_on = today
      plan.items.each { |item| item.status = "completed" }
      audit("treatment_plan.completed", "treatment_plan", id, { total_cents: plan.total_cents })
      plan
    end

    def create_claim(plan_id:)
      plan = find_plan!(plan_id)
      raise ConflictError, "only completed plans can be claimed" unless plan.status == "completed"
      if @claims.values.any? { |claim| claim.plan_id == plan_id }
        raise ConflictError, "a claim already exists for this treatment plan"
      end

      claim = Claim.new(
        id: next_id("claim"),
        plan_id: plan.id,
        patient_id: plan.patient_id,
        amount_cents: plan.total_cents,
        submitted_on: today
      )
      @claims[claim.id] = claim
      audit("claim.submitted", "claim", claim.id, { amount_cents: claim.amount_cents })
      claim
    end

    def update_claim(id, status)
      status = status.to_s
      raise ValidationError, "invalid claim status" unless CLAIM_STATUSES.include?(status)

      claim = @claims.fetch(id)
      claim.status = status
      audit("claim.#{status}", "claim", id, {})
      claim
    rescue KeyError
      raise NotFoundError, "claim not found"
    end

    def list_claims
      @claims.values.sort_by(&:submitted_on)
    end

    def overdue_recalls(on: today)
      date = parse_date(on) || today
      @patients.values
        .select { |patient| patient.recall_due_on && patient.recall_due_on < date }
        .sort_by(&:recall_due_on)
    end

    def metrics(on: today)
      date = parse_date(on) || today
      day_appointments = appointments_on(date)
      total = day_appointments.length
      completed = day_appointments.count { |appointment| appointment.status == "completed" }
      no_show = day_appointments.count { |appointment| appointment.status == "no_show" }
      cancelled = day_appointments.count { |appointment| appointment.status == "cancelled" }
      proposed = @plans.values.count { |plan| plan.status == "proposed" }
      accepted = @plans.values.count { |plan| %w[accepted completed].include?(plan.status) }
      decided = proposed + accepted
      revenue = @claims.values.select { |claim| claim.status == "accepted" }.sum(&:amount_cents)

      {
        date: date.iso8601,
        appointments: total,
        completed: completed,
        no_show: no_show,
        cancelled: cancelled,
        no_show_rate_percent: total.zero? ? 0.0 : ((no_show.to_f / total) * 100).round(1),
        treatment_acceptance_percent: decided.zero? ? 0.0 : ((accepted.to_f / decided) * 100).round(1),
        overdue_recalls: overdue_recalls(on: date).length,
        accepted_claim_revenue_cents: revenue,
        active_patients: @patients.length
      }
    end

    def find_plan!(id)
      @plans.fetch(id)
    rescue KeyError
      raise NotFoundError, "treatment plan not found"
    end

    def self.seeded(clock: -> { Time.now })
      practice = new(clock: clock)
      today = practice.today
      amelia = practice.add_patient(
        first_name: "Amelia", last_name: "Brown", email: "amelia.brown@example.com",
        phone: "021 555 0101", recall_months: 6, last_visit_on: today << 7
      )
      jack = practice.add_patient(
        first_name: "Jack", last_name: "Wilson", email: "jack.wilson@example.com",
        phone: "021 555 0102", recall_months: 6, last_visit_on: today << 2
      )
      priya = practice.add_patient(
        first_name: "Priya", last_name: "Sharma", email: "priya.sharma@example.com",
        phone: "021 555 0103", recall_months: 12, last_visit_on: today << 14
      )

      morning = Time.local(today.year, today.month, today.day, 9, 0)
      practice.schedule_appointment(
        patient_id: amelia.id, clinician: "Dr Chen", chair: "Chair 1",
        starts_at: morning, duration_minutes: 45, reason: "Exam and clean"
      )
      practice.schedule_appointment(
        patient_id: jack.id, clinician: "Dr Patel", chair: "Chair 2",
        starts_at: morning + (60 * 60), duration_minutes: 30, reason: "Composite restoration"
      )
      practice.schedule_appointment(
        patient_id: priya.id, clinician: "Dr Chen", chair: "Chair 1",
        starts_at: morning + (2 * 60 * 60), duration_minutes: 30, reason: "Recall review"
      )

      plan = practice.create_treatment_plan(
        patient_id: amelia.id,
        items: [
          { code: "D111", description: "Comprehensive examination", tooth: nil, fee_cents: 18_000 },
          { code: "D211", description: "Composite restoration", tooth: "26", fee_cents: 32_000 }
        ]
      )
      practice.accept_plan(plan.id)
      practice.complete_plan(plan.id)
      claim = practice.create_claim(plan_id: plan.id)
      practice.update_claim(claim.id, "accepted")

      practice
    end

    private

    def parse_date(value)
      return nil if value.nil? || value.to_s.strip.empty?
      return value if value.is_a?(Date)

      Date.parse(value.to_s)
    rescue ArgumentError
      raise ValidationError, "invalid date"
    end

    def parse_time(value)
      return value if value.is_a?(Time)

      Time.parse(value.to_s)
    rescue ArgumentError, TypeError
      raise ValidationError, "invalid appointment time"
    end

    def overlaps?(start_a, end_a, start_b, end_b)
      start_a < end_b && start_b < end_a
    end

    def next_id(prefix)
      "#{prefix}-#{SecureRandom.hex(4)}"
    end

    def audit(action, entity, entity_id, detail)
      @audit_log << AuditEvent.new(
        id: next_id("audit"),
        at: @clock.call,
        action: action,
        entity: entity,
        entity_id: entity_id,
        detail: detail
      )
    end
  end
end
