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

  test "reset_exclusion! undoes a manual exclusion when it was the only manual change" do
    entry = create_transaction(account: accounts(:depository), amount: 10, name: "Reset me")
    entry.update!(excluded: true)
    entry.lock_saved_attributes!
    entry.mark_user_modified!

    assert entry.reset_exclusion!

    entry.reload
    assert_not entry.excluded?
    assert_not entry.locked?(:excluded)
    assert_not entry.user_modified?
  end

  test "reset_exclusion! keeps the user-modified mark while other manual changes remain" do
    entry = create_transaction(account: accounts(:depository), amount: 10, name: "Reset me")
    entry.update!(excluded: true, notes: "Kept")
    entry.lock_saved_attributes!
    entry.mark_user_modified!

    entry.reset_exclusion!

    entry.reload
    assert_not entry.excluded?
    assert entry.locked?(:notes)
    assert entry.user_modified?
  end

  test "reset_exclusion! keeps the mark while the transaction itself has manual changes" do
    category = categories(:food_and_drink)
    entry = create_transaction(account: accounts(:depository), amount: 10, name: "Reset me")
    entry.update!(excluded: true)
    entry.lock_saved_attributes!
    entry.mark_user_modified!
    entry.entryable.update!(category: category)
    entry.entryable.lock_attr!(:category_id)

    entry.reset_exclusion!

    assert entry.reload.user_modified?
    assert entry.entryable.locked?(:category_id)
  end

  test "reset_exclusion! does nothing for an exclusion the user did not set" do
    entry = create_transaction(account: accounts(:depository), amount: 10, name: "System excluded")
    entry.update_columns(excluded: true)

    assert_not entry.reset_exclusion!
    assert entry.reload.excluded?
  end
end
