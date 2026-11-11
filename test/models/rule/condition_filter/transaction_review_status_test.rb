require "test_helper"

class Rule::ConditionFilter::TransactionReviewStatusTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Rule test", balance: 1000, currency: "USD", accountable: Depository.new)
    @reviewed = create_transaction(account: @account, amount: 10, name: "Reviewed one").transaction
    @reviewed.mark_reviewed!
    @unreviewed = create_transaction(account: @account, amount: 20, name: "Unreviewed one").transaction

    @filter = Rule::ConditionFilter::TransactionReviewStatus.new(rules(:one))
  end

  test "is a select with the two review states and an equal-to operator" do
    assert_equal "select", @filter.type
    assert_equal %w[reviewed unreviewed], @filter.options.map(&:last)
    assert_equal [ "=" ], @filter.operators.map(&:last)
    assert_equal "transaction_review_status", @filter.key
  end

  test "reviewed matches reviewed transactions only" do
    assert_equal [ @reviewed ], @filter.apply(@account.transactions, "=", "reviewed").to_a
  end

  test "unreviewed matches unreviewed transactions only" do
    assert_equal [ @unreviewed ], @filter.apply(@account.transactions, "=", "unreviewed").to_a
  end

  test "a value that is not a review state matches nothing" do
    assert_empty @filter.apply(@account.transactions, "=", "bogus")
    assert_empty @filter.apply(@account.transactions, "=", nil)
  end
end
