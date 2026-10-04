# Durable monthly API request counters for providers with hard request
# budgets (e.g. AVM property valuation providers). Stored in the database
# rather than Rails.cache so budget enforcement survives cache eviction,
# restarts, and Redis flushes.
class ProviderRequestCount < ApplicationRecord
  validates :provider_key, :period, presence: true
  validates :provider_key, uniqueness: { scope: :period }

  class << self
    def current_period
      Date.current.strftime("%Y-%m")
    end

    # Atomically increments the counter by `by` (default 1) and returns the
    # new count. Credit-metered providers pass the cost of the call.
    def increment!(provider_key, by: 1, period: current_period)
      by = Integer(by)
      result = upsert(
        { provider_key: provider_key, period: period, count: by },
        unique_by: %i[provider_key period],
        on_duplicate: Arel.sql(sanitize_sql_array([ "count = provider_request_counts.count + ?, updated_at = CURRENT_TIMESTAMP", by ])),
        returning: %w[count]
      )
      result.rows.first.first.to_i
    end

    def decrement!(provider_key, by: 1, period: current_period)
      where(provider_key: provider_key, period: period).update_all([ "count = GREATEST(count - ?, 0)", Integer(by) ])
    end

    def count_for(provider_key, period: current_period)
      where(provider_key: provider_key, period: period).pick(:count).to_i
    end
  end
end
