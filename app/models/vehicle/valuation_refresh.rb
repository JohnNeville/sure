# Refreshes one vehicle's value from its valuation provider. Shared by the
# monthly SyncVehicleValuationsJob and the "Refresh now" button, so both spend
# credits under the same guards.
#
#   Vehicle::ValuationRefresh.new(vehicle, provider: provider).call.status # => :refreshed
class Vehicle::ValuationRefresh
  Result = Data.define(:status, :message) do
    def refreshed?
      status == :refreshed
    end
  end

  def initialize(vehicle, provider:)
    @vehicle = vehicle
    @provider = provider
    @account = vehicle.account
  end

  # Every check that can refuse runs before the provider is called, because the
  # call is what costs credits.
  def call
    return result(:already_synced) if @vehicle.avm_last_synced_on == Date.current

    if %i[year make model].any? { |field| @vehicle[field].blank? }
      return result(:missing_fields, "Skipping refresh: vehicle year, make or model is missing")
    end

    return result(:budget_spent) unless @provider.requests_remaining?

    # The account was created in the provider's currency, but the user can
    # change it later. Writing a USD value as another currency would corrupt
    # the balance.
    unless @account.currency == @provider.valuation_currency
      return result(:currency_mismatch, "Skipping refresh: account currency #{@account.currency} does not match provider valuation currency #{@provider.valuation_currency}")
    end

    response = @provider.fetch_vehicle_valuation(year: @vehicle.year, make: @vehicle.make, model: @vehicle.model)
    return result(:failed, "Valuation refresh failed: #{response.error.message}") unless response.success?

    saved = nil
    Vehicle.transaction do
      saved = @account.set_current_balance(response.data.valuation)
      raise ActiveRecord::Rollback unless saved.success?
      @vehicle.update!(avm_last_synced_on: Date.current)
    end

    saved&.success? ? result(:refreshed) : result(:failed, "Failed to update valuation balance: #{saved&.error}")
  end

  private
    def result(status, message = nil)
      Result.new(status: status, message: message)
    end
end
