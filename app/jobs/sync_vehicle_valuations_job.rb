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

      if %i[year make model].any? { |field| vehicle[field].blank? }
        capture_failure(vehicle, account, "Skipping refresh: vehicle year, make or model is missing", level: "warn")
        next
      end

      unless providers.key?(vehicle.avm_provider)
        providers[vehicle.avm_provider] = begin
          registry.get_provider(vehicle.avm_provider)
        rescue Provider::Registry::Error
          nil
        end
      end

      provider = providers[vehicle.avm_provider]
      next unless provider # API key was removed after the vehicle was linked
      next unless provider.requests_remaining?

      # The account was created in the provider's currency, but the user can
      # change it later. Writing a USD value as another currency would corrupt
      # the balance, so skip mismatches — before spending credits.
      unless account.currency == provider.valuation_currency
        capture_failure(vehicle, account, "Skipping refresh: account currency #{account.currency} does not match provider valuation currency #{provider.valuation_currency}", level: "warn")
        next
      end

      response = provider.fetch_vehicle_valuation(year: vehicle.year, make: vehicle.make, model: vehicle.model)

      if response.success?
        result = nil
        Vehicle.transaction do
          result = account.set_current_balance(response.data.valuation)
          raise ActiveRecord::Rollback unless result.success?
          vehicle.update!(avm_last_synced_on: Date.current)
        end

        unless result&.success?
          capture_failure(vehicle, account, "Failed to update valuation balance: #{result&.error}")
        end
      else
        capture_failure(vehicle, account, "Valuation refresh failed: #{response.error.message}")
      end
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
