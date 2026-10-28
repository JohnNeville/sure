require "test_helper"

class PlaidItemTest < ActiveSupport::TestCase
  include SyncableInterfaceTest

  setup do
    @plaid_item = @syncable = plaid_items(:one)
    @plaid_provider = mock
    Provider::Registry.stubs(:plaid_provider_for_region).returns(@plaid_provider)
  end

  test "supports products granted through additional_consented_products" do
    # Plaid reports products consented to at Link time -- but not yet billed --
    # in consented_products, which is neither available_products nor
    # billed_products. A credit-card item looks exactly like this: `liabilities`
    # is billed, while `transactions` is only consented.
    @plaid_item.update!(
      available_products: [ "balance" ],
      billed_products: [ "liabilities" ],
      raw_payload: { "consented_products" => [ "transactions", "liabilities", "investments" ] }
    )

    assert @plaid_item.supports_product?("transactions")
    assert @plaid_item.supports_product?("liabilities")
    assert @plaid_item.supports_product?("balance")
    assert_not @plaid_item.supports_product?("assets")
  end

  test "supported products tolerate a missing or non-hash raw payload" do
    @plaid_item.update!(
      available_products: [ "balance" ],
      billed_products: [ "transactions" ],
      raw_payload: nil
    )

    assert @plaid_item.supports_product?("transactions")
    assert_not @plaid_item.supports_product?("liabilities")
  end

  test "removes plaid item when destroyed" do
    @plaid_provider.expects(:remove_item).with(@plaid_item.access_token).once

    assert_difference "PlaidItem.count", -1 do
      @plaid_item.destroy
    end
  end

  test "destroys item even when Plaid credentials are invalid" do
    error_response = {
      "error_code" => "INVALID_API_KEYS",
      "error_message" => "invalid client_id or secret provided"
    }.to_json

    plaid_error = Plaid::ApiError.new(code: 400, response_body: error_response)
    @plaid_provider.expects(:remove_item).raises(plaid_error)

    assert_difference "PlaidItem.count", -1 do
      @plaid_item.destroy
    end
  end

  test "destroys item even when Plaid item not found" do
    error_response = {
      "error_code" => "ITEM_NOT_FOUND",
      "error_message" => "item not found"
    }.to_json

    plaid_error = Plaid::ApiError.new(code: 400, response_body: error_response)
    @plaid_provider.expects(:remove_item).raises(plaid_error)

    assert_difference "PlaidItem.count", -1 do
      @plaid_item.destroy
    end
  end

  test "get_update_link_token marks item as requires_update and returns nil on ITEM_NOT_FOUND" do
    error_response = { "error_code" => "ITEM_NOT_FOUND", "error_message" => "not found" }.to_json
    Family.any_instance.expects(:get_link_token).raises(
      Plaid::ApiError.new(code: 400, response_body: error_response)
    )

    result = @plaid_item.get_update_link_token(webhooks_url: "https://x", redirect_url: "https://x")

    assert_nil result
    assert_predicate @plaid_item.reload, :requires_update?
  end

  test "get_update_link_token can enable account selection" do
    Family.any_instance.expects(:get_link_token).with(
      webhooks_url: "https://example.com/webhooks",
      redirect_url: "https://example.com/accounts",
      region: @plaid_item.plaid_region,
      access_token: @plaid_item.access_token,
      account_selection_enabled: true
    ).returns("link-token")

    result = @plaid_item.get_update_link_token(
      webhooks_url: "https://example.com/webhooks",
      redirect_url: "https://example.com/accounts",
      account_selection_enabled: true
    )

    assert_equal "link-token", result
  end

  test "sync_later_with_follow_up queues a follow-up after an active sync" do
    active_sync = @plaid_item.syncs.create!
    active_sync.start!

    assert_enqueued_with job: PlaidFollowUpSyncJob do
      @plaid_item.sync_later_with_follow_up
    end
  end

  test "get_update_link_token re-raises other Plaid errors so the controller can surface them" do
    # Issue #1792: silently swallowing all Plaid errors here is what made the
    # "modal closes with nothing happening" experience so opaque.
    error_response = { "error_code" => "INVALID_PRODUCT", "error_message" => "Your account is not enabled..." }.to_json
    Family.any_instance.expects(:get_link_token).raises(
      Plaid::ApiError.new(code: 400, response_body: error_response)
    )

    assert_raises(Plaid::ApiError) do
      @plaid_item.get_update_link_token(webhooks_url: "https://x", redirect_url: "https://x")
    end
    assert_predicate @plaid_item.reload, :good?
  end

  test "get_update_link_token tolerates a Plaid::ApiError with a nil/blank response_body" do
    # Plaid clients have been observed raising ApiError without a response
    # body (network-layer failures, early aborts). The old JSON.parse would
    # blow up with TypeError before the rescue could fire; we now coerce
    # to String so the parse falls back to {} and the error re-raises
    # cleanly for the controller to handle.
    Family.any_instance.expects(:get_link_token).raises(
      Plaid::ApiError.new(code: 500, response_body: nil)
    )

    assert_raises(Plaid::ApiError) do
      @plaid_item.get_update_link_token(webhooks_url: "https://x", redirect_url: "https://x")
    end
    assert_predicate @plaid_item.reload, :good?
  end

  test "user sync requests a provider refresh when cooldown lease is acquired" do
    @plaid_item.stubs(:shared_transactions_refresh_cache?).returns(true)
    Rails.cache.expects(:write).with(
      "plaid_item:#{@plaid_item.id}:transactions_refresh_requested",
      true,
      expires_in: PlaidItem::TRANSACTIONS_REFRESH_COOLDOWN,
      unless_exist: true
    ).returns(true)

    assert_enqueued_with(job: PlaidTransactionsRefreshJob, args: [ @plaid_item ]) do
      @plaid_item.request_transactions_refresh_later
    end
  end

  test "user sync does not duplicate a recent provider refresh request" do
    @plaid_item.stubs(:shared_transactions_refresh_cache?).returns(true)
    Rails.cache.stubs(:write).returns(false)

    assert_no_enqueued_jobs only: PlaidTransactionsRefreshJob do
      @plaid_item.request_transactions_refresh_later
    end
  end

  test "user sync does not request refresh without the transactions product" do
    @plaid_item.update!(billed_products: [ "investments" ])

    Rails.cache.expects(:write).never
    assert_no_enqueued_jobs only: PlaidTransactionsRefreshJob do
      @plaid_item.request_transactions_refresh_later
    end
  end

  test "user sync rejects provider refresh without a shared cache" do
    @plaid_item.stubs(:shared_transactions_refresh_cache?).returns(false)

    Rails.cache.expects(:write).never
    assert_no_enqueued_jobs only: PlaidTransactionsRefreshJob do
      @plaid_item.request_transactions_refresh_later
    end
  end

  # The test env's null store runs the real check. Naming MemCacheStore there
  # autoloads it, and that raises LoadError without the dalli gem.
  test "user sync skips provider refresh on an unshared cache without loading dalli" do
    assert_no_enqueued_jobs only: PlaidTransactionsRefreshJob do
      @plaid_item.request_transactions_refresh_later
    end
  end

  test "user sync releases cooldown lease when refresh job is not enqueued" do
    @plaid_item.stubs(:shared_transactions_refresh_cache?).returns(true)
    Rails.cache.stubs(:write).returns(true)
    PlaidTransactionsRefreshJob.stubs(:perform_later).returns(false)
    Rails.cache.expects(:delete).with("plaid_item:#{@plaid_item.id}:transactions_refresh_requested")

    @plaid_item.request_transactions_refresh_later
  end

  test "user sync releases cooldown lease when refresh job enqueue raises" do
    @plaid_item.stubs(:shared_transactions_refresh_cache?).returns(true)
    Rails.cache.stubs(:write).returns(true)
    PlaidTransactionsRefreshJob.stubs(:perform_later).raises(RedisClient::Error, "Redis unavailable")
    Rails.cache.expects(:delete).with("plaid_item:#{@plaid_item.id}:transactions_refresh_requested")

    assert_raises RedisClient::Error do
      @plaid_item.request_transactions_refresh_later
    end
  end

  test "refresh interval defaults to always" do
    assert_predicate PlaidItem.new, :refresh_always?
    assert_predicate @plaid_item, :refresh_due?
  end

  test "refresh_due? is always true for always and never true for never" do
    @plaid_item.update!(last_refresh_requested_at: Time.current)

    @plaid_item.update!(refresh_interval: "always")
    assert_predicate @plaid_item, :refresh_due?

    @plaid_item.update!(refresh_interval: "never")
    assert_not @plaid_item.refresh_due?

    @plaid_item.update!(last_refresh_requested_at: nil)
    assert_not @plaid_item.refresh_due?
  end

  test "refresh_due? compares calendar days for timed intervals" do
    travel_to Time.zone.local(2026, 10, 15, 1, 0, 0) do
      { "daily" => 1, "weekly" => 7, "monthly" => 30 }.each do |interval, days|
        @plaid_item.update!(refresh_interval: interval)

        @plaid_item.update!(last_refresh_requested_at: nil)
        assert_predicate @plaid_item, :refresh_due?, "#{interval} is due when never requested"

        # Requested a little less than the interval ago, but on an earlier
        # calendar day than the cutoff: still not due.
        @plaid_item.update!(last_refresh_requested_at: (days - 1).days.ago)
        assert_not @plaid_item.refresh_due?, "#{interval} is not due before #{days} days have passed"

        # A refresh that landed a few seconds later in the day than tonight's
        # sync still counts as due once the days have passed.
        @plaid_item.update!(last_refresh_requested_at: days.days.ago + 10.seconds)
        assert_predicate @plaid_item, :refresh_due?, "#{interval} is due after #{days} days"

        @plaid_item.update!(last_refresh_requested_at: (days + 5).days.ago)
        assert_predicate @plaid_item, :refresh_due?, "#{interval} is due when well overdue"
      end
    end
  end

  test "rejects an unknown refresh interval" do
    @plaid_item.refresh_interval = "hourly"

    assert_not @plaid_item.valid?
    assert @plaid_item.errors.of_kind?(:refresh_interval, :inclusion)
  end

  test "automatic sync skips the refresh when the interval says it is not due" do
    @plaid_item.update!(refresh_interval: "weekly", last_refresh_requested_at: 1.day.ago)
    @plaid_item.stubs(:shared_transactions_refresh_cache?).returns(true)

    Rails.cache.expects(:write).never
    assert_no_enqueued_jobs only: PlaidTransactionsRefreshJob do
      @plaid_item.request_transactions_refresh_later
    end
    assert_in_delta 1.day.ago.to_f, @plaid_item.reload.last_refresh_requested_at.to_f, 5
  end

  test "automatic sync requests the refresh when the interval says it is due" do
    @plaid_item.update!(refresh_interval: "weekly", last_refresh_requested_at: 8.days.ago)
    @plaid_item.stubs(:shared_transactions_refresh_cache?).returns(true)
    Rails.cache.stubs(:write).returns(true)

    assert_enqueued_with(job: PlaidTransactionsRefreshJob, args: [ @plaid_item ]) do
      @plaid_item.request_transactions_refresh_later
    end
  end

  test "never interval skips automatic refreshes" do
    @plaid_item.update!(refresh_interval: "never")
    @plaid_item.stubs(:shared_transactions_refresh_cache?).returns(true)

    assert_no_enqueued_jobs only: PlaidTransactionsRefreshJob do
      @plaid_item.request_transactions_refresh_later
    end
  end

  test "forced refresh ignores the interval" do
    @plaid_item.update!(refresh_interval: "never", last_refresh_requested_at: Time.current)
    @plaid_item.stubs(:shared_transactions_refresh_cache?).returns(true)
    Rails.cache.stubs(:write).returns(true)

    assert_enqueued_with(job: PlaidTransactionsRefreshJob, args: [ @plaid_item ]) do
      @plaid_item.request_transactions_refresh_later(force: true)
    end
  end

  test "user sync preserves follow-up sync while requesting provider refresh" do
    @plaid_item.expects(:request_transactions_refresh_later).with(force: true).once
    @plaid_item.expects(:sync_later_with_follow_up).once

    @plaid_item.sync_later_with_provider_refresh
  end
end
