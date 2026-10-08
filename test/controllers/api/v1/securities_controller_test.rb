# frozen_string_literal: true

require "test_helper"

class Api::V1::SecuritiesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "test_read_#{SecureRandom.hex(8)}"
    )

    @account = accounts(:investment)
    @holding_security = securities(:aapl)
    @holding_ticker = @holding_security.ticker
    @trade_ticker = "AAPL#{SecureRandom.hex(4).upcase}"

    @trade_security = Security.create!(
      ticker: @trade_ticker,
      name: "Apple Inc.",
      country_code: "US",
      exchange_operating_mic: "XNAS"
    )
    @account.entries.create!(
      name: "Buy AAPL",
      date: Date.parse("2024-01-16"),
      amount: 1800,
      currency: "USD",
      entryable: Trade.new(
        security: @trade_security,
        qty: 10,
        price: 180,
        currency: "USD"
      )
    )

    @unreferenced_security = Security.create!(ticker: "MSFT#{SecureRandom.hex(4).upcase}", name: "Microsoft Corp.", country_code: "US")

    other_account = families(:empty).accounts.create!(
      name: "Other Investment Account",
      accountable: Investment.new,
      balance: 1000,
      currency: "USD"
    )
    @other_security = Security.create!(ticker: "GOOG#{SecureRandom.hex(4).upcase}", name: "Alphabet Inc.", country_code: "US")
    other_account.holdings.create!(
      security: @other_security,
      date: Date.parse("2024-01-15"),
      qty: 1,
      price: 100,
      amount: 100,
      currency: "USD"
    )
  end

  test "lists securities referenced by accessible family investment data" do
    get api_v1_securities_url, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    security_ids = response_data["securities"].map { |security| security["id"] }

    assert_includes security_ids, @holding_security.id
    assert_includes security_ids, @trade_security.id
    assert_not_includes security_ids, @unreferenced_security.id
    assert_not_includes security_ids, @other_security.id
    assert response_data.key?("pagination")
  end

  test "shows a scoped security" do
    get api_v1_security_url(@holding_security), headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)

    assert_equal @holding_security.id, response_data["id"]
    assert_equal @holding_ticker, response_data["ticker"]
    assert_equal @holding_security.exchange_operating_mic, response_data["exchange_operating_mic"]
    assert_equal "standard", response_data["kind"]
    assert_not response_data.key?("price_provider")
  end

  test "returns not found for another family's security" do
    get api_v1_security_url(@other_security), headers: api_headers(@api_key)

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "record_not_found", response_data["error"]
  end

  test "returns not found for malformed security id" do
    get api_v1_security_url("not-a-uuid"), headers: api_headers(@api_key)

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "record_not_found", response_data["error"]
  end

  test "filters securities by ticker" do
    get api_v1_securities_url, params: { ticker: @trade_ticker.downcase }, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal [ @trade_security.id ], response_data["securities"].map { |security| security["id"] }
  end

  test "filters securities by exchange operating mic" do
    get api_v1_securities_url, params: { exchange_operating_mic: " xnas " }, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal [ @holding_security.id, @trade_security.id ], response_data["securities"].map { |security| security["id"] }
  end

  test "caps per_page at documented maximum" do
    get api_v1_securities_url, params: { per_page: 250 }, headers: api_headers(@api_key)

    assert_response :success
    assert_equal 100, JSON.parse(response.body).dig("pagination", "per_page")
  end

  test "rejects invalid kind filter" do
    get api_v1_securities_url, params: { kind: "unsupported" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "rejects malformed offline filter" do
    get api_v1_securities_url, params: { offline: "maybe" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
    assert_includes response_data["errors"], "offline must be true or false"
  end

  test "rejects blank offline filter" do
    get api_v1_securities_url, params: { offline: "" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
    assert_includes response_data["errors"], "offline must be true or false"
  end

  test "requires authentication" do
    get api_v1_securities_url

    assert_response :unauthorized
  end

  test "requires read scope" do
    api_key_without_read = ApiKey.new(
      user: @user,
      name: "No Read Key",
      scopes: [],
      source: "web",
      display_key: "no_read_#{SecureRandom.hex(8)}"
    )
    api_key_without_read.save!(validate: false)

    get api_v1_securities_url, headers: api_headers(api_key_without_read)

    assert_response :forbidden
  ensure
    api_key_without_read&.destroy
  end

  # --- manual prices ---

  test "update turns manual prices on: offline, manual reason, no provider" do
    @holding_security.update!(price_provider: "twelve_data", offline: false)

    patch api_v1_security_url(@holding_security),
          params: { security: { manual_prices: true } },
          headers: api_headers(write_key_for(@user)), as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body["manual_prices"]
    assert_equal true, body["offline"]
    assert_equal "manual", body["offline_reason"]
    assert_nil @holding_security.reload.price_provider
    assert_equal 0, @holding_security.failed_fetch_count
  end

  test "update turns manual prices off and leaves the security offline, keeping its prices" do
    @holding_security.enable_manual_prices!
    price = Security::Price.create!(security: @holding_security, date: Date.current - 400.days, price: 10, currency: "USD")

    patch api_v1_security_url(@holding_security),
          params: { security: { manual_prices: false } },
          headers: api_headers(write_key_for(@user)), as: :json

    assert_response :success
    @holding_security.reload
    assert_equal false, JSON.parse(response.body)["manual_prices"]
    assert @holding_security.offline?
    assert_nil @holding_security.offline_reason
    assert Security::Price.exists?(price.id)
  end

  test "turning manual prices off for a security that is not manual changes nothing" do
    @holding_security.update!(offline: true, offline_reason: "health_check_failed")

    patch api_v1_security_url(@holding_security),
          params: { security: { manual_prices: false } },
          headers: api_headers(write_key_for(@user)), as: :json

    assert_response :success
    assert_equal "health_check_failed", @holding_security.reload.offline_reason
  end

  test "update validates the flag, needs write scope and admin, and only reaches the family's own securities" do
    patch api_v1_security_url(@holding_security), params: { security: { manual_prices: "maybe" } },
          headers: api_headers(write_key_for(@user)), as: :json
    assert_response :unprocessable_entity

    patch api_v1_security_url(@holding_security), params: { security: {} },
          headers: api_headers(write_key_for(@user)), as: :json
    assert_response :unprocessable_entity

    patch api_v1_security_url(@holding_security), params: { security: { manual_prices: true } },
          headers: api_headers(@api_key), as: :json
    assert_response :forbidden, "a read key cannot change a security"

    patch api_v1_security_url(@holding_security), params: { security: { manual_prices: true } },
          headers: api_headers(write_key_for(users(:family_member))), as: :json
    assert_response :forbidden, "only an admin can change how a security is priced"

    patch api_v1_security_url(@unreferenced_security), params: { security: { manual_prices: true } },
          headers: api_headers(write_key_for(@user)), as: :json
    assert_response :not_found
    patch api_v1_security_url(@other_security), params: { security: { manual_prices: true } },
          headers: api_headers(write_key_for(@user)), as: :json
    assert_response :not_found
    assert_not @other_security.reload.manual_prices?
  end

  test "index filters manually priced securities" do
    @holding_security.enable_manual_prices!

    get api_v1_securities_url, params: { manual_prices: true }, headers: api_headers(@api_key)
    assert_equal [ @holding_security.id ], JSON.parse(response.body)["securities"].map { |s| s["id"] }

    get api_v1_securities_url, params: { manual_prices: false }, headers: api_headers(@api_key)
    assert_not_includes JSON.parse(response.body)["securities"].map { |s| s["id"] }, @holding_security.id
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end

    def write_key_for(user, name: "Write Key")
      user.api_keys.active.where.not(id: @api_key.id).destroy_all
      ApiKey.create!(user: user, name: name, scopes: [ "read_write" ], source: "mobile", display_key: "test_rw_#{SecureRandom.hex(8)}")
    end
end
