require "test_helper"

class EntryTest < ActiveSupport::TestCase
  include EntriesTestHelper

  test "chronological ordering uses id as final tie breaker" do
    account = accounts(:depository)
    timestamp = Time.zone.parse("2026-05-05 12:00:00")

    entries = 3.times.map do |index|
      create_transaction(
        account: account,
        name: "Same timestamp transaction #{index}",
        date: Date.new(2026, 5, 5),
        created_at: timestamp,
        updated_at: timestamp
      )
    end

    entry_ids = entries.map(&:id)

    assert_equal entry_ids.sort, Entry.where(id: entry_ids).chronological.pluck(:id)
    assert_equal entry_ids.sort.reverse, Entry.where(id: entry_ids).reverse_chronological.pluck(:id)
  end

  test "bulk_update! touches the assigned category's last_used_at" do
    entry = create_transaction(account: accounts(:depository))
    category = categories(:income)
    assert_nil category.last_used_at

    Entry.where(id: entry.id).bulk_update!({ category_id: category.id })

    assert_not_nil category.reload.last_used_at
  end
  test "a closed account takes nothing dated after its closed date" do
    account = families(:dylan_family).accounts.create!(name: "Closed", balance: 0, currency: "USD", accountable: Depository.new)
    closed_on = 10.days.ago.to_date
    account.close_on!(closed_on)

    after = account.entries.build(date: closed_on + 1.day, name: "Late", amount: 5, currency: "USD", entryable: Transaction.new)
    assert_not after.valid?
    assert_match(/after this account was closed on/, after.errors[:date].to_sentence)

    on_the_day = account.entries.build(date: closed_on, name: "Last", amount: 5, currency: "USD", entryable: Transaction.new)
    assert on_the_day.valid?
  end

  test "an entry already after a closed date stays editable until its date moves" do
    account = families(:dylan_family).accounts.create!(name: "Closed later", balance: 0, currency: "USD", accountable: Depository.new)
    entry = create_transaction(account: account, date: Date.current, amount: 5)
    account.update_columns(status: "closed", closed_on: 10.days.ago.to_date)

    entry.reload.name = "Renamed"
    assert entry.valid?

    entry.date = Date.current - 1.day
    assert_not entry.valid?
  end

  test "an account that is not closed has no date limit" do
    entry = create_transaction(account: accounts(:depository), date: Date.current, amount: 5)

    assert entry.valid?
  end
end
