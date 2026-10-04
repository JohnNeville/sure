class VehiclesController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes(
    :id, :make, :model, :year, :mileage_value, :mileage_unit
  )

  def new
    super
    @avm_providers = configured_avm_providers
  end

  def create
    return create_via_avm_provider if params[:avm_provider].present?

    super
  end

  private
    def create_via_avm_provider
      @avm_providers = configured_avm_providers
      provider_key = params[:avm_provider].to_s

      unless @avm_providers.map(&:to_s).include?(provider_key)
        redirect_to new_vehicle_path, alert: t("providers.vehicle_valuation.not_configured") and return
      end

      if params[:avm_step] == "confirm"
        # The signed token proves the lookup step actually ran (and spent its
        # credits) — a direct confirm POST with fabricated data would
        # otherwise create provider-linked vehicles that the monthly refresh
        # job then spends credits on. Everything is rebuilt from the token
        # payload, so nothing user-editable is trusted.
        payload = verify_avm_preview_token!

        importer = Vehicle::AvmImport.new(
          family: Current.family,
          owner: Current.user,
          provider_key: payload["provider_key"],
          name: payload["name"],
          vehicle_attributes: payload["vehicle"].symbolize_keys
        )

        @account = importer.create_account(avm_data_from_payload(payload))

        return_path = safe_return_to(session.delete(:return_to)) || account_path(@account)

        respond_to do |format|
          format.html { redirect_to return_path }
          format.turbo_stream { stream_redirect_to return_path }
        end
      else
        # Step 1: spend credits on one lookup, then show the fetched value for
        # review before anything is created.
        importer = Vehicle::AvmImport.new(
          family: Current.family,
          owner: Current.user,
          provider_key: provider_key,
          name: params.dig(:account, :name),
          vehicle_attributes: avm_vehicle_params.to_h.symbolize_keys
        )

        @avm_preview = importer.lookup
        @avm_preview_token = avm_preview_verifier.generate(
          {
            "provider_key" => provider_key,
            "name" => params.dig(:account, :name),
            "vehicle" => avm_vehicle_params.to_h,
            "data" => @avm_preview.to_h.transform_values(&:to_s)
          },
          expires_in: 1.hour,
          purpose: avm_preview_token_purpose
        )
        @avm_provider_key = provider_key
        @avm_vehicle = Vehicle.new(avm_vehicle_params.to_h)
        @account = Current.family.accounts.build(name: params.dig(:account, :name), accountable: @avm_vehicle)
        render :new
      end
    rescue Vehicle::AvmImport::Error => error
      @avm_provider_key = provider_key
      @error_message = error.message
      @avm_vehicle = Vehicle.new(params.dig(:account, :accountable_attributes)&.permit(:make, :model, :year, :mileage_value, :mileage_unit)&.to_h || {})
      @account = Current.family.accounts.build(name: params.dig(:account, :name), accountable: @avm_vehicle)
      render :new, status: :unprocessable_entity
    end

    def avm_vehicle_params
      params.require(:account).require(:accountable_attributes).permit(:make, :model, :year, :mileage_value, :mileage_unit)
    end

    def avm_preview_verifier
      Rails.application.message_verifier(:avm_preview)
    end

    # Scoping the token's purpose to the family and account type means a token
    # minted in one family's session (or for a property) can't be replayed to
    # seed a vehicle elsewhere.
    def avm_preview_token_purpose
      "avm_preview/vehicle/family/#{Current.family.id}"
    end

    def verify_avm_preview_token!
      avm_preview_verifier.verify(params[:avm_preview_token].to_s, purpose: avm_preview_token_purpose)
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      raise Vehicle::AvmImport::Error.new(t("providers.vehicle_valuation.preview_expired"))
    end

    # Rebuilds the valuation from the signed preview payload (values were
    # stringified for serialization).
    def avm_data_from_payload(payload)
      raw = payload["data"] || {}

      Provider::VehicleValuationConcept::VehicleValuation.new(
        valuation: raw["valuation"].to_d,
        currency: raw["currency"].presence || "USD",
        year: raw["year"].presence&.to_i,
        make: raw["make"],
        model: raw["model"]
      )
    end

    def configured_avm_providers
      registry = Provider::Registry.for_concept(:vehicle_valuations)
      registry.provider_keys.select { |key| registry.get_provider(key).present? }
    end
end
