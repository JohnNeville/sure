require "test_helper"

class Rule::ActionExecutor::MarkTransactionReviewedTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Rule test", balance: 1000, currency: "USD", accountable: Depository.new)
    @executor = Rule::ActionExecutor::MarkTransactionReviewed.new(rules(:one))
  end

  test "marks unreviewed transactions reviewed and counts only those" do
    already_reviewed = create_transaction(account: @account, amount: 10).transaction
    already_reviewed.mark_reviewed!
    original_reviewed_at = already_reviewed.reload.reviewed_at
    unreviewed = create_transaction(account: @account, amount: 20).transaction

    modified = @executor.execute(@account.transactions)

    assert_equal 1, modified
    assert unreviewed.reload.reviewed?
    assert_equal original_reviewed_at, already_reviewed.reload.reviewed_at
  end

  test "only touches the transactions in the scope it is given" do
    in_scope = create_transaction(account: @account, amount: 10).transaction
    out_of_scope = create_transaction(account: @account, amount: 20).transaction

    @executor.execute(@account.transactions.where(id: in_scope.id))

    assert in_scope.reload.reviewed?
    assert_not out_of_scope.reload.reviewed?
  end

  test "does nothing and reports zero when everything is already reviewed" do
    create_transaction(account: @account, amount: 10).transaction.mark_reviewed!

    assert_equal 0, @executor.execute(@account.transactions)
  end

  test "refreshes the entries cache version" do
    create_transaction(account: @account, amount: 10)
    before = @family.entries_cache_version

    travel 1.minute do
      @executor.execute(@account.transactions)
    end

    assert_not_equal before, @family.reload.entries_cache_version
  end

  test "has a localized label and no value" do
    assert_equal "Mark as reviewed", @executor.label
    assert_equal "function", @executor.type
    assert_equal "mark_transaction_reviewed", @executor.key
  end
end
