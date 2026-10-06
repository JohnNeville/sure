require "test_helper"

class Rule::ConditionFilter::TransactionExcludedTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Rule test", balance: 1000, currency: "USD", accountable: Depository.new)
    @excluded = create_transaction(account: @account, amount: 10, name: "Excluded one").tap { |entry| entry.update_columns(excluded: true) }.transaction
    @included = create_transaction(account: @account, amount: 20, name: "Included one").transaction
    @filter = Rule::ConditionFilter::TransactionExcluded.new(rules(:one))
  end

  test "is a yes/no select with an equal-to operator" do
    assert_equal "select", @filter.type
    assert_equal %w[true false], @filter.options.map(&:last)
    assert_equal %w[Yes No], @filter.options.map(&:first)
    assert_equal [ "=" ], @filter.operators.map(&:last)
    assert_equal "transaction_excluded", @filter.key
  end

  test "yes matches excluded transactions only" do
    scope = @filter.prepare(@account.transactions)

    assert_equal [ @excluded ], @filter.apply(scope, "=", "true").to_a
  end

  test "no matches transactions that count toward reports" do
    scope = @filter.prepare(@account.transactions)

    assert_equal [ @included ], @filter.apply(scope, "=", "false").to_a
  end

  test "a value that is not yes or no matches nothing" do
    scope = @filter.prepare(@account.transactions)

    assert_empty @filter.apply(scope, "=", "maybe")
    assert_empty @filter.apply(scope, "=", nil)
  end
end
