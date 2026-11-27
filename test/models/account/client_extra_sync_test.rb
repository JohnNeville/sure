require "test_helper"

# Bank syncs write their own namespaces of Transaction#extra. What API clients
# stored under import and retail has to survive them.
class Account::ClientExtraSyncTest < ActiveSupport::TestCase
  CLIENT_EXTRA = {
    "import" => { "source" => "Quicken" },
    "retail" => { "retailer" => "Amazon", "items" => [ { "title" => "Cable" } ] }
  }.freeze

  setup do
    @adapter = Account::ProviderImportAdapter.new(accounts(:depository))
  end

  test "a re-sync keeps import and retail" do
    entry = sync("txn_1", pending: false)
    add_client_extra(entry)

    resynced = sync("txn_1", pending: false)

    assert_equal entry.id, resynced.id
    assert_equal CLIENT_EXTRA, resynced.transaction.reload.extra.slice("import", "retail")
  end

  test "a pending charge claimed by its posted version keeps import and retail" do
    pending = sync("txn_pending", pending: true)
    add_client_extra(pending)

    posted = sync("txn_posted", pending: false, pending_transaction_id: "txn_pending")

    assert_equal pending.id, posted.id
    assert_not posted.transaction.reload.pending?
    assert_equal CLIENT_EXTRA, posted.transaction.extra.slice("import", "retail")
  end

  private
    def sync(external_id, pending:, pending_transaction_id: nil)
      @adapter.import_transaction(
        external_id: external_id, amount: 25, currency: "USD", date: Date.current, name: "Amazon",
        source: "plaid", pending_transaction_id: pending_transaction_id,
        extra: { "plaid" => { "pending" => pending } }
      )
    end

    def add_client_extra(entry)
      transaction = entry.transaction.reload
      transaction.update!(extra: transaction.extra.merge(CLIENT_EXTRA.deep_dup))
    end
end
