require "test_helper"

class SyncVehicleValuationsJobTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:vehicle)
    @vehicle = @account.vehicle
    @vehicle.update!(make: "Honda", model: "Accord", year: 2021, avm_provider: "cardog")
  end

  def valuation_data(valuation: 21_450)
    Provider::VehicleValuationConcept::VehicleValuation.new(
      valuation: valuation, currency: "USD", year: 2021, make: "Honda", model: "Accord"
    )
  end

  def stub_provider(requests_remaining: true, currency: "USD")
    provider = mock
    provider.stubs(:requests_remaining?).returns(requests_remaining)
    provider.stubs(:valuation_currency).returns(currency)
    Provider::Registry.stubs(:cardog).returns(provider)
    provider
  end

  test "refreshes the valuation of linked vehicles via their provider" do
    provider = stub_provider
    provider.expects(:fetch_vehicle_valuation).with(year: 2021, make: "Honda", model: "Accord")
      .returns(Provider::Response.new(success?: true, data: valuation_data, error: nil))

    SyncVehicleValuationsJob.new.perform

    assert_equal Date.current, @vehicle.reload.avm_last_synced_on
    assert_equal 21_450, @account.reload.balance
  end

  test "skips vehicles already synced today" do
    @vehicle.update!(avm_last_synced_on: Date.current)
    provider = stub_provider
    provider.expects(:fetch_vehicle_valuation).never

    SyncVehicleValuationsJob.new.perform

    assert_equal 18_000, @account.reload.balance
  end

  test "skips when the monthly budget is spent" do
    provider = stub_provider(requests_remaining: false)
    provider.expects(:fetch_vehicle_valuation).never

    SyncVehicleValuationsJob.new.perform

    assert_nil @vehicle.reload.avm_last_synced_on
  end

  test "skips accounts whose currency differs from the provider's" do
    provider = stub_provider(currency: "CAD")
    provider.expects(:fetch_vehicle_valuation).never

    SyncVehicleValuationsJob.new.perform

    assert_nil @vehicle.reload.avm_last_synced_on
  end

  test "skips vehicles missing year, make or model" do
    @vehicle.update!(year: nil)
    provider = stub_provider
    provider.expects(:fetch_vehicle_valuation).never

    SyncVehicleValuationsJob.new.perform

    assert_nil @vehicle.reload.avm_last_synced_on
  end

  test "leaves the vehicle untouched when the lookup fails" do
    provider = stub_provider
    provider.stubs(:fetch_vehicle_valuation).returns(
      Provider::Response.new(success?: false, data: nil, error: Provider::Cardog::Error.new("boom"))
    )

    assert_difference -> { DebugLogEntry.count }, 1 do
      SyncVehicleValuationsJob.new.perform
    end

    assert_nil @vehicle.reload.avm_last_synced_on
    assert_equal 18_000, @account.reload.balance
  end
end
