require "test_helper"

class Rule::ActionExecutor::IncludeTransactionTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Rule test", balance: 1000, currency: "USD", accountable: Depository.new)
    @executor = Rule::ActionExecutor::IncludeTransaction.new(rules(:one))
  end

  def excluded_entry(amount: 10)
    create_transaction(account: @account, amount: amount).tap { |entry| entry.update_columns(excluded: true) }
  end

  test "includes excluded transactions again and counts only those it changed" do
    excluded = excluded_entry
    included = create_transaction(account: @account, amount: 20)

    modified = @executor.execute(@account.transactions)

    assert_equal 1, modified
    assert_not excluded.reload.excluded?
    assert_not included.reload.excluded?
  end

  test "leaves a transaction alone when the user locked its excluded flag" do
    entry = excluded_entry
    entry.update_columns(locked_attributes: { "excluded" => Time.current.iso8601 })

    assert_equal 0, @executor.execute(@account.transactions)
    assert entry.reload.excluded?
  end

  test "overrides a locked flag when the rule is applied ignoring locks" do
    entry = excluded_entry
    entry.update_columns(locked_attributes: { "excluded" => Time.current.iso8601 })

    assert_equal 1, @executor.execute(@account.transactions, ignore_attribute_locks: true)
    assert_not entry.reload.excluded?
  end

  test "only touches the transactions in the scope it is given" do
    in_scope = excluded_entry(amount: 10)
    out_of_scope = excluded_entry(amount: 20)

    @executor.execute(@account.transactions.where(id: in_scope.entryable_id))

    assert_not in_scope.reload.excluded?
    assert out_of_scope.reload.excluded?
  end

  test "records where the change came from" do
    entry = excluded_entry

    @executor.execute(@account.transactions)

    assert_equal "rule", entry.data_enrichments.where(attribute_name: "excluded").order(:created_at).last&.source
  end

  test "has a localized label and no value" do
    assert_equal "Include in budgeting and reports", @executor.label
    assert_equal "function", @executor.type
    assert_equal "include_transaction", @executor.key
  end
end
