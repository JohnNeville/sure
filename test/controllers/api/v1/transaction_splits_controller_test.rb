# frozen_string_literal: true

require "test_helper"

class Api::V1::TransactionSplitsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:depository)
    @food = categories(:food_and_drink)
    @income = categories(:income)

    @user.api_keys.active.destroy_all
    @api_key = ApiKey.create!(
      user: @user, name: "Test Read-Write Key", scopes: [ "read_write" ],
      display_key: "test_rw_#{SecureRandom.hex(8)}"
    )
    @read_only_api_key = ApiKey.create!(
      user: @user, name: "Test Read-Only Key", scopes: [ "read" ],
      display_key: "test_ro_#{SecureRandom.hex(8)}", source: "mobile"
    )
    Redis.new.del("api_rate_limit:#{@api_key.id}")
    Redis.new.del("api_rate_limit:#{@read_only_api_key.id}")

    @entry = create_transaction(account: @account, name: "AMZN Mktp US*2K1AB3C0", amount: 31.5, date: 3.days.ago.to_date)
    @transaction = @entry.transaction
  end

  test "splits a charge into children that sum to it" do
    post api_v1_transaction_split_url(@transaction),
         params: { splits: [
           { name: "USB-C cable", amount: "19.98", category_id: @food.id, notes: "2 x 9.99" },
           { amount: 11.52 }
         ] },
         headers: api_headers(@api_key), as: :json

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal @transaction.id, body.dig("parent", "id")
    assert_equal "parent", body.dig("parent", "split_role")
    assert_equal [ "USB-C cable", "AMZN Mktp US*2K1AB3C0" ], body["children"].map { |child| child["name"] }
    assert_equal [ 1998, 1152 ], body["children"].map { |child| child["amount_cents"] }
    assert_equal @food.id, body["children"].first.dig("category", "id")
    assert_equal "2 x 9.99", body["children"].first["notes"]
    assert_equal [ "child", "child" ], body["children"].map { |child| child["split_role"] }
    assert_equal [ @transaction.id ], body["children"].map { |child| child["split_parent_id"] }.uniq

    @entry.reload
    assert @entry.excluded?
    assert_equal [ BigDecimal("19.98"), BigDecimal("11.52") ], @entry.child_entries.order(:created_at, :id).map(&:amount)
    assert_equal %w[USD], @entry.child_entries.pluck(:currency).uniq
    assert_equal @entry.date, @entry.child_entries.first.date
  end

  test "children of an income transaction keep its sign" do
    income = create_transaction(account: @account, name: "Refund", amount: -30)

    post api_v1_transaction_split_url(income.transaction),
         params: { splits: [ { amount: 10 }, { amount: 20 } ] },
         headers: api_headers(@api_key), as: :json

    assert_response :created
    assert_equal [ BigDecimal("-10"), BigDecimal("-20") ], income.reload.child_entries.order(:created_at, :id).map(&:amount)
  end

  test "rejects amounts that do not sum to the transaction" do
    assert_no_difference("Entry.count") do
      post api_v1_transaction_split_url(@transaction),
           params: { splits: [ { amount: 10 }, { amount: 10 } ] },
           headers: api_headers(@api_key), as: :json
    end

    assert_response :unprocessable_entity
    assert_match(/must sum to the transaction amount \(expected 31.5, got 20.0\)/, JSON.parse(response.body)["message"])
    assert_not @entry.reload.excluded?
  end

  test "rejects invalid split lists" do
    [
      nil,
      "nope",
      [],
      [ { amount: 31.5 } ],
      [ { amount: 10 }, { amount: "abc" } ],
      [ { amount: 10 }, { amount: 0 } ],
      [ { amount: 31.51 }, { amount: -0.01 } ],
      [ { amount: 10.005 }, { amount: 21.495 } ],
      [ { amount: 10, category_id: SecureRandom.uuid }, { amount: 21.5 } ],
      [ { amount: 10, category_id: "not-a-uuid" }, { amount: 21.5 } ],
      Array.new(Api::V1::TransactionSplitsController::MAX_SPLITS + 1) { { amount: 1 } }
    ].each do |bad|
      post api_v1_transaction_split_url(@transaction),
           params: { splits: bad },
           headers: api_headers(@api_key), as: :json

      assert_response :unprocessable_entity, "expected #{bad.inspect[0, 60]} to be rejected"
    end
    assert_not @entry.reload.excluded?
  end

  test "rejects a category from another family" do
    other = families(:empty).categories.create!(name: "Other family", color: "#abcdef", lucide_icon: "shapes")

    post api_v1_transaction_split_url(@transaction),
         params: { splits: [ { amount: 10, category_id: other.id }, { amount: 21.5 } ] },
         headers: api_headers(@api_key), as: :json

    assert_response :unprocessable_entity
    assert_match(/Unknown category_id/, JSON.parse(response.body)["message"])
  end

  test "explains why a transaction cannot be split" do
    split_body = { splits: [ { amount: 10 }, { amount: 21.5 } ] }
    excluded = create_transaction(account: @account, amount: 31.5, excluded: true)
    pending = create_transaction(account: @account, amount: 31.5)
    pending.transaction.update!(extra: { "plaid" => { "pending" => true } })

    { excluded => /excluded/, pending => /pending/ }.each do |entry, reason|
      post api_v1_transaction_split_url(entry.transaction), params: split_body, headers: api_headers(@api_key), as: :json
      assert_response :unprocessable_entity
      assert_match reason, JSON.parse(response.body)["message"]
    end

    post api_v1_transaction_split_url(@transaction), params: split_body, headers: api_headers(@api_key), as: :json
    assert_response :created

    post api_v1_transaction_split_url(@transaction), params: split_body, headers: api_headers(@api_key), as: :json
    assert_response :unprocessable_entity
    assert_match(/already split/, JSON.parse(response.body)["message"])

    child = @entry.reload.child_entries.first
    post api_v1_transaction_split_url(child.transaction), params: split_body, headers: api_headers(@api_key), as: :json
    assert_response :unprocessable_entity
    assert_match(/already part of a split/, JSON.parse(response.body)["message"])
  end

  test "rejects a transfer" do
    transfer = create_transaction(account: @account, amount: 50, kind: "funds_movement")

    post api_v1_transaction_split_url(transfer.transaction),
         params: { splits: [ { amount: 20 }, { amount: 30 } ] },
         headers: api_headers(@api_key), as: :json

    assert_response :unprocessable_entity
    assert_match(/transfer/, JSON.parse(response.body)["message"])
  end

  test "show returns the split, resolving a child to its parent" do
    @entry.split!([ { name: "A", amount: 10 }, { name: "B", amount: 21.5 } ])

    get api_v1_transaction_split_url(@transaction), headers: api_headers(@read_only_api_key)
    assert_response :success
    assert_equal %w[A B], JSON.parse(response.body)["children"].map { |child| child["name"] }

    child = @entry.child_entries.first
    get api_v1_transaction_split_url(child.transaction), headers: api_headers(@read_only_api_key)
    assert_response :success
    assert_equal @transaction.id, JSON.parse(response.body).dig("parent", "id")
  end

  test "show on an unsplit transaction is not found" do
    get api_v1_transaction_split_url(@transaction), headers: api_headers(@api_key)

    assert_response :not_found
  end

  test "update replaces the split" do
    @entry.split!([ { name: "A", amount: 10 }, { name: "B", amount: 21.5 } ])

    put api_v1_transaction_split_url(@transaction),
        params: { splits: [ { name: "X", amount: 1.5 }, { name: "Y", amount: 30 } ] },
        headers: api_headers(@api_key), as: :json

    assert_response :success
    assert_equal %w[X Y], JSON.parse(response.body)["children"].map { |child| child["name"] }
    assert_equal %w[X Y], @entry.reload.child_entries.order(:created_at, :id).pluck(:name)
    assert @entry.excluded?
  end

  test "a failed update leaves the existing split alone" do
    @entry.split!([ { name: "A", amount: 10 }, { name: "B", amount: 21.5 } ])

    put api_v1_transaction_split_url(@transaction),
        params: { splits: [ { amount: 1 }, { amount: 1 } ] },
        headers: api_headers(@api_key), as: :json

    assert_response :unprocessable_entity
    assert_equal %w[A B], @entry.reload.child_entries.order(:created_at, :id).pluck(:name)
  end

  test "update on an unsplit transaction is not found" do
    put api_v1_transaction_split_url(@transaction),
        params: { splits: [ { amount: 10 }, { amount: 21.5 } ] },
        headers: api_headers(@api_key), as: :json

    assert_response :not_found
  end

  test "destroy removes the split and restores the parent, from the parent or a child id" do
    @entry.split!([ { name: "A", amount: 10 }, { name: "B", amount: 21.5 } ])
    child_transaction = @entry.child_entries.first.transaction

    assert_difference("Entry.count", -2) do
      delete api_v1_transaction_split_url(child_transaction), headers: api_headers(@api_key)
    end

    assert_response :success
    assert_equal [], JSON.parse(response.body)["children"]
    assert_not @entry.reload.excluded?
    assert_not @entry.split_parent?

    delete api_v1_transaction_split_url(@transaction), headers: api_headers(@api_key)
    assert_response :not_found
  end

  test "the transaction JSON describes split state" do
    @entry.split!([ { name: "A", amount: 10 }, { name: "B", amount: 21.5 } ])
    child_ids = @entry.child_entries.map(&:entryable_id)

    get api_v1_transaction_url(@transaction), headers: api_headers(@api_key)
    body = JSON.parse(response.body)
    assert_equal "parent", body["split_role"]
    assert_equal child_ids.sort, body["split_child_ids"].sort

    get api_v1_transaction_url(child_ids.first), headers: api_headers(@api_key)
    body = JSON.parse(response.body)
    assert_equal "child", body["split_role"]
    assert_equal @transaction.id, body["split_parent_id"]

    other = create_transaction(account: @account, amount: 5)
    get api_v1_transaction_url(other.transaction), headers: api_headers(@api_key)
    body = JSON.parse(response.body)
    assert_nil body["split_role"]
    assert_equal [], body["split_child_ids"]
  end

  test "requires write scope, a writable account and authentication" do
    split_body = { splits: [ { amount: 10 }, { amount: 21.5 } ] }

    post api_v1_transaction_split_url(@transaction), params: split_body, headers: api_headers(@read_only_api_key), as: :json
    assert_response :forbidden

    post api_v1_transaction_split_url(@transaction), params: split_body, as: :json
    assert_response :unauthorized

    post api_v1_transaction_split_url(SecureRandom.uuid), params: split_body, headers: api_headers(@api_key), as: :json
    assert_response :not_found

    post api_v1_transaction_split_url("not-a-uuid"), params: split_body, headers: api_headers(@api_key), as: :json
    assert_response :not_found
  end

  private
    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end
end
