# Refreshes the valuation of vehicles linked to a valuation provider.
#
# Runs once a month (see config/schedule.yml) because provider budgets are
# tight monthly credit caps (Cardog's free tier is 50 credits, and one lookup
# costs 6). Each provider additionally enforces its cap via a durable monthly
# counter, so refreshes stop once the month's budget is spent.
class SyncVehicleValuationsJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform
    registry = Provider::Registry.for_concept(:vehicle_valuations)

    # Stalest valuations first (never-synced before oldest-refreshed) so a
    # tight budget is spent where it matters most.
    vehicles = Vehicle.where.not(avm_provider: nil)
                      .includes(:account)
                      .order(Arel.sql("avm_last_synced_on ASC NULLS FIRST"))

    # One provider instance per key for the whole run — the request throttle
    # tracks its last request time on the instance.
    providers = {}

    vehicles.each do |vehicle|
      account = vehicle.account
      next unless account&.active?
      next if vehicle.avm_last_synced_on == Date.current

      unless providers.key?(vehicle.avm_provider)
        providers[vehicle.avm_provider] = begin
          registry.get_provider(vehicle.avm_provider)
        rescue Provider::Registry::Error
          nil
        end
      end

      provider = providers[vehicle.avm_provider]
      next unless provider # API key was removed after the vehicle was linked

      result = Vehicle::ValuationRefresh.new(vehicle, provider: provider).call
      next unless result.message

      capture_failure(vehicle, account, result.message, level: result.status == :failed ? "error" : "warn")
    rescue => e
      capture_failure(vehicle, vehicle.account, "Error refreshing valuation: #{e.class} - #{e.message}")
    end
  end

  private

    def capture_failure(vehicle, account, message, level: "error")
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: level,
        message: message,
        source: self.class.name,
        provider_key: vehicle.avm_provider,
        account: account,
        metadata: { vehicle_id: vehicle.id }
      )
    end
end
