# Interface for providers that can estimate a vehicle's market value from its
# year, make and model.
#
# Unlike the property AVM providers, usage is budgeted in provider credits
# rather than requests, because a single lookup can span several calls with
# different costs.
#
# Includers must define:
# - `MAX_CREDITS_PER_MONTH` (Integer) — the provider's monthly credit budget
# - `LOOKUP_CREDITS` (Integer)        — credits one full valuation lookup costs
# - `RateLimitError` (Class)          — provider-scoped rate-limit error class
module Provider::VehicleValuationConcept
  extend ActiveSupport::Concern

  VehicleValuation = Data.define(:valuation, :currency, :year, :make, :model)

  def fetch_vehicle_valuation(year:, make:, model:)
    raise NotImplementedError, "Subclasses must implement #fetch_vehicle_valuation"
  end

  # Currency of the valuations this provider returns. Checked by
  # SyncVehicleValuationsJob against the account currency before credits are
  # spent.
  def valuation_currency
    "USD"
  end

  # Whether the budget still covers one more full lookup.
  def requests_remaining?
    monthly_credits_used + self.class::LOOKUP_CREDITS <= max_credits_per_month
  end

  def usage
    with_provider_response do
      used = monthly_credits_used

      Provider::UsageData.new(
        used: used,
        limit: max_credits_per_month,
        utilization: (used.to_f / max_credits_per_month * 100).round(1),
        plan: "Free"
      )
    end
  end

  private
    # An explicit ENV cap (e.g. CARDOG_MAX_REQUESTS_PER_MONTH) wins, then the
    # allowance the provider last reported, then the provider's free tier.
    def max_credits_per_month
      ENV["#{provider_key.upcase}_MAX_REQUESTS_PER_MONTH"].presence&.to_i ||
        ProviderRequestCount.reported_limit_for(provider_key) ||
        self.class::MAX_CREDITS_PER_MONTH
    end

    def monthly_credits_used
      ProviderRequestCount.count_for(provider_key)
    end

    # Reserves credits against the durable monthly counter before a request
    # goes out, raising if that would exceed the budget.
    def record_credits!(cost)
      count = ProviderRequestCount.increment!(provider_key, by: cost)

      if count > max_credits_per_month
        ProviderRequestCount.decrement!(provider_key, by: cost)
        raise self.class::RateLimitError.new("#{self.class.name.demodulize} monthly credit limit reached (#{max_credits_per_month} per month)")
      end
    end

    def refund_credits!(cost)
      ProviderRequestCount.decrement!(provider_key, by: cost)
    end

    def provider_key
      self.class.name.demodulize.underscore
    end
end
