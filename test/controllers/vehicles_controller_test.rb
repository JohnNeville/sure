require "test_helper"

class VehiclesControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:vehicle)
  end

  test "creates with vehicle details" do
    assert_difference -> { Account.count } => 1,
      -> { Vehicle.count } => 1,
      -> { Valuation.count } => 1,
      -> { Entry.count } => 1 do
      post vehicles_path, params: {
        account: {
          name: "Vehicle",
          balance: 30000,
          currency: "USD",
          institution_name: "Auto Lender",
          institution_domain: "autolender.example",
          notes: "Lease notes",
          accountable_type: "Vehicle",
          accountable_attributes: {
            make: "Toyota",
            model: "Camry",
            year: 2020,
            mileage_value: 15000,
            mileage_unit: "mi"
          }
        }
      }
    end

    created_account = Account.order(:created_at).last

    assert_equal "Vehicle", created_account.name
    assert_equal 30000, created_account.balance
    assert_equal "USD", created_account.currency
    assert_equal "Auto Lender", created_account[:institution_name]
    assert_equal "autolender.example", created_account[:institution_domain]
    assert_equal "Lease notes", created_account[:notes]
    assert_equal "Toyota", created_account.accountable.make
    assert_equal "Camry", created_account.accountable.model
    assert_equal 2020, created_account.accountable.year
    assert_equal 15000, created_account.accountable.mileage_value
    assert_equal "mi", created_account.accountable.mileage_unit

    assert_redirected_to created_account
    assert_equal "Vehicle account created", flash[:notice]
    assert_enqueued_with(job: SyncJob)
  end

  test "updates with vehicle details" do
    assert_no_difference [ "Account.count", "Vehicle.count" ] do
      patch vehicle_path(@account), params: {
        account: {
          name: "Updated Vehicle",
          balance: 28000,
          currency: "USD",
          institution_name: "Updated Lender",
          institution_domain: "updatedlender.example",
          notes: "Updated lease notes",
          accountable_type: "Vehicle",
          accountable_attributes: {
            id: @account.accountable_id,
            make: "Honda",
            model: "Accord",
            year: 2021,
            mileage_value: 20000,
            mileage_unit: "mi",
            purchase_price: 32000
          }
        }
      }
    end

    @account.reload
    assert_equal "Updated Vehicle", @account.name
    assert_equal 28000, @account.balance
    assert_equal "Updated Lender", @account[:institution_name]
    assert_equal "updatedlender.example", @account[:institution_domain]
    assert_equal "Updated lease notes", @account[:notes]

    assert_redirected_to account_path(@account)
    assert_equal "Vehicle account updated", flash[:notice]
    assert_enqueued_with(job: SyncJob)
  end

  def stub_cardog(response = successful_avm_response)
    provider = mock
    provider.stubs(:fetch_vehicle_valuation).returns(response)
    Provider::Registry.stubs(:cardog).returns(provider)
    provider
  end

  def successful_avm_response
    Provider::Response.new(
      success?: true,
      data: Provider::VehicleValuationConcept::VehicleValuation.new(
        valuation: 21_450, currency: "USD", year: 2021, make: "Honda", model: "Civic"
      ),
      error: nil
    )
  end

  def avm_vehicle_params
    { make: "Honda", model: "Civic", year: 2021, mileage_value: 30000, mileage_unit: "mi" }
  end

  def signed_preview_token
    Rails.application.message_verifier(:avm_preview).generate(
      {
        "provider_key" => "cardog",
        "name" => "Daily Driver",
        "vehicle" => avm_vehicle_params.stringify_keys.transform_values(&:to_s),
        "data" => { "valuation" => "21450", "currency" => "USD", "year" => "2021", "make" => "Honda", "model" => "Civic" }
      },
      expires_in: 1.hour,
      purpose: "avm_preview/vehicle/family/#{@user.family.id}"
    )
  end

  test "offers Cardog in the method selector when configured" do
    stub_cardog

    get new_vehicle_path(step: "method_select")

    assert_response :success
    assert_select "a[href=?]", new_vehicle_path(method: "cardog")
  end

  test "lookup step previews the value without creating an account" do
    stub_cardog

    assert_no_difference -> { Account.count } do
      post vehicles_path, params: {
        avm_provider: "cardog",
        account: { name: "Daily Driver", accountable_type: "Vehicle", accountable_attributes: avm_vehicle_params }
      }
    end

    assert_response :success
    assert_select "input[name=avm_preview_token]"
  end

  test "lookup rejects an unconfigured provider" do
    Provider::Registry.stubs(:cardog).returns(nil)

    post vehicles_path, params: {
      avm_provider: "cardog",
      account: { name: "Daily Driver", accountable_type: "Vehicle", accountable_attributes: avm_vehicle_params }
    }

    assert_redirected_to new_vehicle_path
  end

  test "lookup surfaces provider errors" do
    stub_cardog(Provider::Response.new(success?: false, data: nil, error: Provider::Cardog::Error.new("No match")))

    post vehicles_path, params: {
      avm_provider: "cardog",
      account: { name: "Daily Driver", accountable_type: "Vehicle", accountable_attributes: avm_vehicle_params }
    }

    assert_response :unprocessable_entity
    assert_match "No match", response.body
  end

  test "confirm step creates a provider-linked vehicle from the signed preview" do
    stub_cardog

    assert_difference [ "Account.count", "Vehicle.count" ], 1 do
      post vehicles_path, params: {
        avm_provider: "cardog",
        avm_step: "confirm",
        avm_preview_token: signed_preview_token,
        account: { accountable_type: "Vehicle" }
      }
    end

    account = Account.order(:created_at).last
    assert_equal "Daily Driver", account.name
    assert_equal 21_450, account.balance
    assert_equal "cardog", account.vehicle.avm_provider
    assert_equal Date.current, account.vehicle.avm_last_synced_on
    assert_equal "Honda", account.vehicle.make
    assert_redirected_to account_path(account)
  end

  test "confirm step rejects a forged token" do
    stub_cardog

    assert_no_difference -> { Account.count } do
      post vehicles_path, params: {
        avm_provider: "cardog",
        avm_step: "confirm",
        avm_preview_token: "forged-token",
        account: { accountable_type: "Vehicle" }
      }
    end

    assert_response :unprocessable_entity
  end
  test "refresh_valuation fetches a new value and records the refresh" do
    vehicle = link_to_cardog
    provider = stub_refresh_provider
    provider.expects(:fetch_vehicle_valuation).with(year: 2021, make: "Honda", model: "Accord")
      .returns(Provider::Response.new(success?: true, data: refresh_valuation_data(21_450), error: nil))

    post refresh_valuation_vehicle_path(@account)

    assert_redirected_to account_path(@account)
    assert_match "Valuation refreshed", flash[:notice]
    assert_equal 21_450, @account.reload.balance
    assert_equal Date.current, vehicle.reload.avm_last_synced_on
  end

  test "refresh_valuation does not spend credits twice in one day" do
    link_to_cardog.update!(avm_last_synced_on: Date.current)
    provider = stub_refresh_provider
    provider.expects(:fetch_vehicle_valuation).never

    post refresh_valuation_vehicle_path(@account)

    assert_equal I18n.t("vehicles.refresh_valuation.already_synced"), flash[:alert]
  end

  test "refresh_valuation refuses when the monthly budget is spent" do
    link_to_cardog
    provider = stub_refresh_provider(requests_remaining: false)
    provider.expects(:fetch_vehicle_valuation).never

    post refresh_valuation_vehicle_path(@account)

    assert_equal I18n.t("vehicles.refresh_valuation.budget_spent"), flash[:alert]
  end

  test "refresh_valuation reports a provider failure and logs it" do
    link_to_cardog
    provider = stub_refresh_provider
    provider.stubs(:fetch_vehicle_valuation)
      .returns(Provider::Response.new(success?: false, data: nil, error: Provider::Error.new("boom")))

    assert_difference -> { DebugLogEntry.count }, 1 do
      post refresh_valuation_vehicle_path(@account)
    end

    assert_equal I18n.t("vehicles.refresh_valuation.failed"), flash[:alert]
    assert_equal 18_000, @account.reload.balance
  end

  test "refresh_valuation needs a linked provider" do
    post refresh_valuation_vehicle_path(@account)

    assert_equal I18n.t("vehicles.refresh_valuation.not_linked"), flash[:alert]
  end

  test "overview offers the refresh button only for provider-linked vehicles" do
    get account_path(@account, tab: "overview")
    assert_no_match(/refresh_valuation/, response.body)

    link_to_cardog
    get account_path(@account, tab: "overview")
    assert_includes response.body, refresh_valuation_vehicle_path(@account)
  end

  private
    def link_to_cardog
      vehicle = @account.vehicle
      vehicle.update!(make: "Honda", model: "Accord", year: 2021, avm_provider: "cardog")
      vehicle
    end

    def stub_refresh_provider(requests_remaining: true)
      provider = mock
      provider.stubs(:requests_remaining?).returns(requests_remaining)
      provider.stubs(:valuation_currency).returns("USD")
      Provider::Registry.stubs(:cardog).returns(provider)
      provider
    end

    def refresh_valuation_data(amount)
      Provider::VehicleValuationConcept::VehicleValuation.new(
        valuation: amount, currency: "USD", year: 2021, make: "Honda", model: "Accord"
      )
    end
end
