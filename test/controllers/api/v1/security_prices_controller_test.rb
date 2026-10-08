# frozen_string_literal: true

require "test_helper"

class Api::V1::SecurityPricesControllerTest < ActionDispatch::IntegrationTest
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
    @security = securities(:aapl)
    @ticker = @security.ticker
    @security_price = security_prices(:one)
    @eur_price = Security::Price.create!(
      security: @security,
      date: @security_price.date,
      price: BigDecimal("250.5000"),
      currency: "EUR"
    )

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
    @other_price = Security::Price.create!(
      security: @other_security,
      date: Date.parse("2024-01-15"),
      price: 100,
      currency: "USD"
    )
  end

  test "lists prices for securities referenced by accessible family investment data" do
    get api_v1_security_prices_url, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    price_ids = response_data["security_prices"].map { |price| price["id"] }

    assert_includes price_ids, @security_price.id
    assert_not_includes price_ids, @other_price.id
    assert response_data.key?("pagination")
  end

  test "shows a scoped security price" do
    get api_v1_security_price_url(@security_price), headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)

    assert_equal @security_price.id, response_data["id"]
    assert_equal @security_price.date.iso8601, response_data["date"]
    assert_equal "215.0000", response_data["price_amount"]
    assert_equal @security.id, response_data.dig("security", "id")
  end

  test "returns not found for another family's security price" do
    get api_v1_security_price_url(@other_price), headers: api_headers(@api_key)

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "record_not_found", response_data["error"]
  end

  test "returns not found for malformed security price id" do
    get api_v1_security_price_url("not-a-uuid"), headers: api_headers(@api_key)

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "record_not_found", response_data["error"]
  end

  test "filters security prices by security_id" do
    get api_v1_security_prices_url, params: { security_id: @security.id }, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_includes response_data["security_prices"].map { |price| price["id"] }, @security_price.id
    assert response_data["security_prices"].all? { |price| price.dig("security", "id") == @security.id }
  end

  test "filters security prices by date range and provisional status" do
    get api_v1_security_prices_url,
        params: { start_date: @security_price.date.iso8601, end_date: @security_price.date.iso8601, currency: "USD", provisional: false },
        headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal [ @security_price.id ], response_data["security_prices"].map { |price| price["id"] }
  end

  test "rejects blank provisional filter" do
    get api_v1_security_prices_url,
        params: { provisional: "" },
        headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
    assert_includes response_data["errors"], "provisional must be true or false"
  end

  test "filters security prices by currency" do
    get api_v1_security_prices_url,
        params: { currency: " usd " },
        headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_includes response_data["security_prices"].map { |price| price["id"] }, @security_price.id
    assert_not_includes response_data["security_prices"].map { |price| price["id"] }, @eur_price.id
  end

  test "rejects malformed provisional filter" do
    get api_v1_security_prices_url,
        params: { provisional: "maybe" },
        headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
    assert_includes response_data["errors"], "provisional must be true or false"
  end

  test "caps per_page at documented maximum" do
    get api_v1_security_prices_url, params: { per_page: 250 }, headers: api_headers(@api_key)

    assert_response :success
    assert_equal 100, JSON.parse(response.body).dig("pagination", "per_page")
  end

  test "rejects malformed security_id filter" do
    get api_v1_security_prices_url, params: { security_id: "not-a-uuid" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "rejects invalid date filters" do
    get api_v1_security_prices_url, params: { start_date: "01/15/2024" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "requires authentication" do
    get api_v1_security_prices_url

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

    get api_v1_security_prices_url, headers: api_headers(api_key_without_read)

    assert_response :forbidden
  ensure
    api_key_without_read&.destroy
  end

  # --- manual prices: bulk upsert and range delete ---

  test "create upserts daily prices for a manually priced security, and again is a no-op" do
    @security.enable_manual_prices!
    body = { security_id: @security.id, prices: [
      { date: "2018-01-02", price: "21.5000" }, { date: "2018-01-03", price: 21.62 }
    ] }

    post api_v1_security_prices_url, params: body, headers: api_headers(write_key_for(@user)), as: :json

    assert_response :success
    assert_equal({ "created" => 2, "updated" => 0, "unchanged" => 0 }, JSON.parse(response.body))
    stored = @security.prices.where(currency: "USD", date: [ "2018-01-02", "2018-01-03" ]).order(:date)
    assert_equal [ BigDecimal("21.5"), BigDecimal("21.62") ], stored.map(&:price)
    assert stored.none?(&:provisional)

    post api_v1_security_prices_url, params: body, headers: api_headers(write_key_for(@user)), as: :json
    assert_equal({ "created" => 0, "updated" => 0, "unchanged" => 2 }, JSON.parse(response.body))
  end

  test "create updates changed dates, keeps other currencies apart and rounds to four places" do
    @security.enable_manual_prices!
    Security::Price.create!(security: @security, date: "2018-02-01", price: 10, currency: "USD")

    post api_v1_security_prices_url,
         params: { security_id: @security.id, currency: "eur", prices: [ { date: "2018-02-01", price: "12.34567" }, { date: "2018-02-02", price: 5 } ] },
         headers: api_headers(write_key_for(@user)), as: :json
    assert_response :success
    assert_equal({ "created" => 2, "updated" => 0, "unchanged" => 0 }, JSON.parse(response.body), "EUR rows are separate from the USD one")
    assert_equal BigDecimal("12.3457"), @security.prices.find_by!(date: "2018-02-01", currency: "EUR").price
    assert_equal BigDecimal("10"), @security.prices.find_by!(date: "2018-02-01", currency: "USD").price

    post api_v1_security_prices_url,
         params: { security_id: @security.id, prices: [ { date: "2018-02-01", price: 11 } ] },
         headers: api_headers(write_key_for(@user)), as: :json
    assert_equal({ "created" => 0, "updated" => 1, "unchanged" => 0 }, JSON.parse(response.body))
    assert_equal BigDecimal("11"), @security.prices.find_by!(date: "2018-02-01", currency: "USD").price
  end

  test "create refuses a security that is not manually priced, with the way to fix it" do
    assert_no_difference("Security::Price.count") do
      post api_v1_security_prices_url,
           params: { security_id: @security.id, prices: [ { date: "2018-01-02", price: 1 } ] },
           headers: api_headers(write_key_for(@user)), as: :json
    end

    assert_response :unprocessable_entity
    assert_match(/not set to manual prices/, JSON.parse(response.body)["message"])
  end

  test "create validates the request and changes nothing when any row is bad" do
    @security.enable_manual_prices!
    good = { date: "2018-01-02", price: 1 }
    [
      { prices: [] },
      { prices: "nope" },
      { prices: [ good, { date: "not a date", price: 1 } ] },
      { prices: [ good, { date: 2.days.from_now.to_date.iso8601, price: 1 } ] },
      { prices: [ good, { date: "2018-01-03", price: "abc" } ] },
      { prices: [ good, { date: "2018-01-03", price: 0 } ] },
      { prices: [ good, { date: "2018-01-03", price: -4 } ] },
      { prices: [ good, { date: "2018-01-03", price: 0.00001 } ] },
      { prices: [ good, good ] },
      { prices: [ good, "nope" ] },
      { currency: "ZZZ", prices: [ good ] },
      { prices: Array.new(Api::V1::SecurityPricesController::MAX_PRICES_PER_REQUEST + 1) { |i| { date: (Date.new(2000, 1, 1) + i).iso8601, price: 1 } } }
    ].each do |bad|
      assert_no_difference("Security::Price.count") do
        post api_v1_security_prices_url,
             params: { security_id: @security.id }.merge(bad),
             headers: api_headers(write_key_for(@user)), as: :json
      end
      assert_response :unprocessable_entity, "expected #{bad.to_json[0, 90]} to be rejected"
    end
  end

  test "create accepts exactly the row cap" do
    @security.enable_manual_prices!
    rows = Array.new(Api::V1::SecurityPricesController::MAX_PRICES_PER_REQUEST) { |i| { date: (Date.new(2000, 1, 1) + i).iso8601, price: 1 } }

    post api_v1_security_prices_url, params: { security_id: @security.id, prices: rows },
         headers: api_headers(write_key_for(@user)), as: :json

    assert_response :success
    assert_equal Api::V1::SecurityPricesController::MAX_PRICES_PER_REQUEST, JSON.parse(response.body)["created"]
  end

  test "writes need write scope, an admin, and a security the family holds" do
    @security.enable_manual_prices!
    @other_security.enable_manual_prices!
    body = { security_id: @security.id, prices: [ { date: "2018-01-02", price: 1 } ] }

    post api_v1_security_prices_url, params: body, headers: api_headers(@api_key), as: :json
    assert_response :forbidden

    post api_v1_security_prices_url, params: body, headers: api_headers(write_key_for(users(:family_member))), as: :json
    assert_response :forbidden

    post api_v1_security_prices_url, params: { security_id: @other_security.id, prices: [ { date: "2018-01-02", price: 1 } ] },
         headers: api_headers(write_key_for(@user)), as: :json
    assert_response :not_found

    post api_v1_security_prices_url, params: { security_id: "not-a-uuid", prices: [] },
         headers: api_headers(write_key_for(@user)), as: :json
    assert_response :unprocessable_entity

    post api_v1_security_prices_url, params: body, as: :json
    assert_response :unauthorized
  end

  test "destroy_range deletes a date range of a manual security so a bad load can be undone" do
    @security.enable_manual_prices!
    %w[2018-03-01 2018-03-02 2018-03-03 2018-03-10].each { |d| Security::Price.create!(security: @security, date: d, price: 1, currency: "USD") }
    Security::Price.create!(security: @security, date: "2018-03-02", price: 2, currency: "EUR")

    delete api_v1_security_prices_url,
           params: { security_id: @security.id, start_date: "2018-03-02", end_date: "2018-03-03", currency: "USD" },
           headers: api_headers(write_key_for(@user))

    assert_response :success
    assert_equal({ "deleted" => 2 }, JSON.parse(response.body))
    assert_equal %w[2018-03-01 2018-03-10], @security.prices.where(currency: "USD", date: "2018-03-01".."2018-03-31").order(:date).map { |p| p.date.iso8601 }
    assert @security.prices.exists?(date: "2018-03-02", currency: "EUR"), "other currencies are untouched without a match"
  end

  test "destroy_range needs both bounds, valid dates, a manual security and an admin" do
    price = Security::Price.create!(security: @security, date: "2018-03-01", price: 1, currency: "USD")

    delete api_v1_security_prices_url, params: { security_id: @security.id, start_date: "2018-03-01", end_date: "2018-03-01" },
           headers: api_headers(write_key_for(@user))
    assert_response :unprocessable_entity, "not manual"

    @security.enable_manual_prices!
    delete api_v1_security_prices_url, params: { security_id: @security.id, start_date: "2018-03-01" },
           headers: api_headers(write_key_for(@user))
    assert_response :unprocessable_entity, "no end date, so no delete-everything call"

    delete api_v1_security_prices_url, params: { security_id: @security.id, start_date: "bad", end_date: "2018-03-01" },
           headers: api_headers(write_key_for(@user))
    assert_response :unprocessable_entity

    delete api_v1_security_prices_url, params: { security_id: @security.id, start_date: "2018-03-01", end_date: "2018-03-01" },
           headers: api_headers(write_key_for(users(:family_member)))
    assert_response :forbidden

    assert Security::Price.exists?(price.id)
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
