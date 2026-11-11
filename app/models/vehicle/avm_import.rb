# Creates a vehicle account from a valuation provider lookup in two steps:
# `lookup` spends provider credits to fetch a market value for the vehicle's
# year, make and model, which the user reviews on a preview screen;
# `create_account` then seeds the account from the confirmed value without a
# second lookup.
class Vehicle::AvmImport
  Error = Class.new(StandardError)

  def initialize(family:, owner:, provider_key:, name:, vehicle_attributes:)
    @family = family
    @owner = owner
    @provider_key = provider_key.to_s
    @name = name
    @vehicle_attributes = vehicle_attributes
  end

  # Step 1: validates the inputs, then spends provider credits. Returns the
  # fetched Provider::VehicleValuationConcept::VehicleValuation.
  def lookup
    validate_inputs!

    provider = Provider::Registry.for_concept(:vehicle_valuations).get_provider(provider_key)
    raise Error.new(I18n.t("providers.vehicle_valuation.not_configured")) if provider.nil?

    response = provider.fetch_vehicle_valuation(
      year: vehicle_attributes[:year].to_i,
      make: vehicle_attributes[:make],
      model: vehicle_attributes[:model]
    )
    raise Error.new(response.error.message) unless response.success?

    response.data
  end

  # Step 2: creates the active vehicle account from the user-confirmed
  # valuation. No provider request is made here.
  def create_account(data)
    validate_inputs!

    account = nil
    Account.transaction do
      account = family.accounts.create!(
        name: name,
        balance: 0,
        currency: data.currency,
        status: "draft",
        owner: owner,
        accountable: Vehicle.new(
          vehicle_attributes.slice(:make, :model, :year, :mileage_value, :mileage_unit).merge(
            avm_provider: provider_key,
            avm_last_synced_on: Date.current
          )
        )
      )

      result = account.set_current_balance(data.valuation)
      raise Error.new(result.error) unless result.success?

      account.activate!
    end

    account.auto_share_with_family! if family.share_all_by_default?
    account
  rescue ActiveRecord::RecordInvalid => e
    raise Error.new(e.record.errors.full_messages.to_sentence.presence || e.message)
  end

  private
    attr_reader :family, :owner, :provider_key, :name, :vehicle_attributes

    # The form marks these required, but a forged or JS-less submission can
    # bypass that — validate locally before spending credits on a lookup that
    # can't produce a value.
    def validate_inputs!
      missing = name.blank? || %i[year make model].any? { |field| vehicle_attributes[field].blank? }

      raise Error.new(I18n.t("providers.vehicle_valuation.missing_fields")) if missing
    end
end
