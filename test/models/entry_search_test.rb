require "test_helper"

class EntrySearchTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new
    @reviewed = create_transaction(account: @account, amount: 10, name: "Reviewed one")
    @reviewed.transaction.mark_reviewed!
    @unreviewed = create_transaction(account: @account, amount: 20, name: "Unreviewed one")
    @valuation = create_valuation(account: @account, amount: 500)
  end

  test "reviewed filter narrows to reviewed transactions" do
    assert_equal [ @reviewed ], search(reviewed: [ "reviewed" ])
  end

  test "unreviewed filter narrows to unreviewed transactions" do
    assert_equal [ @unreviewed ], search(reviewed: [ "unreviewed" ])
  end

  test "selecting both review states, or none, applies no review filter" do
    everything = [ @reviewed, @unreviewed, @valuation ].sort_by(&:id)

    assert_equal everything, search(reviewed: [ "reviewed", "unreviewed" ]).sort_by(&:id)
    assert_equal everything, search(reviewed: []).sort_by(&:id)
    assert_equal everything, search({}).sort_by(&:id)
  end

  private
    def search(params)
      @account.entries.search(params).to_a
    end
end
