require "test_helper"

class Provider::CardogTest < ActiveSupport::TestCase
  RESOLVE_URL = "https://api.cardog.app/v2/entities/resolve"
  QUOTE_URL = "https://api.cardog.app/v2/quotes/model-year%3Ahonda%2Fcivic%2F2021"

  setup do
    @provider = Provider::Cardog.new("test_api_key")
    @provider.stubs(:throttle_request)
  end

  def resolve_body(ref: "model-year:honda/civic/2021")
    { "best" => ref && { "ref" => ref, "name" => "Honda Civic 2021", "confidence" => 0.95 }, "candidates" => [] }.to_json
  end

  def quote_body
    { "ref" => "model-year:honda/civic/2021", "grain" => "mmy", "liveCount" => 420, "priceP25" => 19_000, "priceMedian" => 21_450, "priceP75" => 23_900 }.to_json
  end

  def stub_lookup
    resolve = stub_request(:get, RESOLVE_URL)
      .with(query: { "q" => "2021 Honda Civic", "domain" => "model-year" }, headers: { "x-api-key" => "test_api_key" })
      .to_return(status: 200, body: resolve_body)
    quote = stub_request(:get, QUOTE_URL)
      .with(headers: { "x-api-key" => "test_api_key" })
      .to_return(status: 200, body: quote_body)
    [ resolve, quote ]
  end

  test "resolves the model year then returns the median quote" do
    resolve, quote = stub_lookup

    response = @provider.fetch_vehicle_valuation(year: 2021, make: "Honda", model: "Civic")

    assert response.success?
    assert_equal 21_450, response.data.valuation
    assert_equal "USD", response.data.currency
    assert_requested resolve
    assert_requested quote
  end

  test "counts credits against the monthly budget" do
    stub_lookup

    assert @provider.requests_remaining?
    @provider.fetch_vehicle_valuation(year: 2021, make: "Honda", model: "Civic")

    assert_equal Provider::Cardog::LOOKUP_CREDITS, ProviderRequestCount.count_for("cardog")
    usage = @provider.usage.data
    assert_equal 6, usage.used
    assert_equal 50, usage.limit
  end

  test "syncs usage and allowance from Cardog's credit headers" do
    ProviderRequestCount.increment!("cardog", by: 2)
    stub_request(:get, RESOLVE_URL).with(query: hash_including("domain" => "model-year"))
      .to_return(status: 200, body: resolve_body, headers: { "X-Credits-Allowance" => "1000", "X-Credits-Remaining" => "795" })
    stub_request(:get, QUOTE_URL)
      .to_return(status: 200, body: quote_body, headers: { "X-Credits-Allowance" => "1000", "X-Credits-Remaining" => "790" })

    @provider.fetch_vehicle_valuation(year: 2021, make: "Honda", model: "Civic")

    assert_equal 210, ProviderRequestCount.count_for("cardog")
    usage = @provider.usage.data
    assert_equal 210, usage.used
    assert_equal 1000, usage.limit
    assert @provider.requests_remaining?
  end

  test "an ENV cap takes priority over the reported allowance" do
    ProviderRequestCount.set!("cardog", 10, limit: 1000)

    ENV["CARDOG_MAX_REQUESTS_PER_MONTH"] = "75"
    assert_equal 75, @provider.usage.data.limit
  ensure
    ENV.delete("CARDOG_MAX_REQUESTS_PER_MONTH")
  end

  test "keeps the reported usage when the quote fails after a successful resolve" do
    stub_request(:get, RESOLVE_URL).with(query: hash_including("domain" => "model-year"))
      .to_return(status: 200, body: resolve_body, headers: { "X-Credits-Allowance" => "50", "X-Credits-Remaining" => "41" })
    stub_request(:get, QUOTE_URL).to_return(status: 404, body: {}.to_json)

    response = @provider.fetch_vehicle_valuation(year: 2021, make: "Honda", model: "Civic")

    assert_not response.success?
    assert_equal 9, ProviderRequestCount.count_for("cardog")
  end

  test "ignores malformed credit headers" do
    stub_request(:get, RESOLVE_URL).with(query: hash_including("domain" => "model-year"))
      .to_return(status: 200, body: resolve_body, headers: { "X-Credits-Allowance" => "lots", "X-Credits-Remaining" => "" })
    stub_request(:get, QUOTE_URL).to_return(status: 200, body: quote_body)

    @provider.fetch_vehicle_valuation(year: 2021, make: "Honda", model: "Civic")

    assert_equal Provider::Cardog::LOOKUP_CREDITS, ProviderRequestCount.count_for("cardog")
    assert_equal 50, @provider.usage.data.limit
  end

  test "returns a friendly error when no model year matches" do
    stub_request(:get, RESOLVE_URL).with(query: hash_including("domain" => "model-year")).to_return(status: 200, body: resolve_body(ref: nil))

    response = @provider.fetch_vehicle_valuation(year: 1801, make: "Nope", model: "Nothing")

    assert_not response.success?
    assert_match(/could not find a vehicle/i, response.error.message)
    assert_equal Provider::Cardog::RESOLVE_CREDITS, ProviderRequestCount.count_for("cardog")
  end

  test "refunds credits for failed requests" do
    stub_request(:get, RESOLVE_URL).with(query: hash_including("domain" => "model-year")).to_return(status: 401, body: { "code" => "unauthorized" }.to_json)

    response = @provider.fetch_vehicle_valuation(year: 2021, make: "Honda", model: "Civic")

    assert_not response.success?
    assert_match(/rejected the API key/i, response.error.message)
    assert_equal 0, ProviderRequestCount.count_for("cardog")
  end

  test "reports exhausted credits" do
    stub_request(:get, RESOLVE_URL).with(query: hash_including("domain" => "model-year")).to_return(status: 402, body: {}.to_json)

    response = @provider.fetch_vehicle_valuation(year: 2021, make: "Honda", model: "Civic")

    assert_match(/no credits left/i, response.error.message)
  end

  test "monthly limit can be raised via ENV override" do
    ProviderRequestCount.create!(provider_key: "cardog", period: ProviderRequestCount.current_period, count: Provider::Cardog::MAX_CREDITS_PER_MONTH)

    ENV["CARDOG_MAX_REQUESTS_PER_MONTH"] = "100"
    assert @provider.requests_remaining?
  ensure
    ENV.delete("CARDOG_MAX_REQUESTS_PER_MONTH")
  end

  test "stops issuing requests once there are too few credits for a lookup" do
    ProviderRequestCount.create!(provider_key: "cardog", period: ProviderRequestCount.current_period, count: Provider::Cardog::MAX_CREDITS_PER_MONTH - 1)

    assert_not @provider.requests_remaining?

    response = @provider.fetch_vehicle_valuation(year: 2021, make: "Honda", model: "Civic")

    assert_instance_of Provider::Cardog::RateLimitError, response.error
    assert_equal Provider::Cardog::MAX_CREDITS_PER_MONTH - 1, ProviderRequestCount.count_for("cardog")
    assert_not_requested :get, %r{api\.cardog\.app}
  end
end
