require "test_helper"

class Transactions::BulkUpdatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "bulk update" do
    transactions = @user.family.entries.transactions

    assert_difference [ "Entry.count", "Transaction.count" ], 0 do
      post transactions_bulk_update_url, params: {
        bulk_update: {
          entry_ids: transactions.map(&:id),
          date: 1.day.ago.to_date,
          category_id: Category.second.id,
          merchant_id: Merchant.second.id,
          tag_ids: [ Tag.first.id, Tag.second.id ],
          notes: "Updated note"
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "#{transactions.count} transactions updated", flash[:notice]

    transactions.reload.each do |transaction|
      assert_equal 1.day.ago.to_date, transaction.date
      assert_equal Category.second, transaction.transaction.category
      assert_equal Merchant.second, transaction.transaction.merchant
      assert_equal "Updated note", transaction.notes
      assert_equal [ Tag.first.id, Tag.second.id ], transaction.entryable.tag_ids.sort
    end
  end

  test "bulk update preloads transaction records" do
    transaction_ids = @user.family.entries.transactions.limit(4).pluck(:id)

    queries = capture_sql_queries do
      post transactions_bulk_update_url, params: {
        bulk_update: {
          entry_ids: transaction_ids,
          notes: "Updated in bulk"
        }
      }
    end

    assert_redirected_to transactions_url
    assert_empty queries.grep(
      /SELECT "transactions"\.\* FROM "transactions" WHERE "transactions"\."id" =/
    )
  end

  test "bulk update preserves tags when tag_ids not provided" do
    transaction_entry = @user.family.entries.transactions.first
    original_tags = [ Tag.first, Tag.second ]
    transaction_entry.transaction.tags = original_tags
    transaction_entry.transaction.save!

    # Update only the category, without providing tag_ids
    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ transaction_entry.id ],
        category_id: Category.second.id
      }
    }

    assert_redirected_to transactions_url

    transaction_entry.reload
    assert_equal Category.second, transaction_entry.transaction.category
    # Tags should be preserved since tag_ids was not in the request
    assert_equal original_tags.map(&:id).sort, transaction_entry.transaction.tag_ids.sort
  end

  test "bulk update clears tags when tag_ids is blank string array (web multi-select None)" do
    transaction_entry = @user.family.entries.transactions.first
    original_tags = [ Tag.first, Tag.second ]
    transaction_entry.transaction.tags = original_tags
    transaction_entry.transaction.save!

    # For a multiple select, choosing the blank ("None") option submits a blank value.
    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ transaction_entry.id ],
        category_id: Category.second.id,
        tag_ids: [ "" ]
      }
    }

    assert_redirected_to transactions_url

    transaction_entry.reload
    assert_equal Category.second, transaction_entry.transaction.category
    assert_empty transaction_entry.transaction.tags
  end

  test "bulk update clears tags when empty tag_ids explicitly provided (JSON)" do
    transaction_entry = @user.family.entries.transactions.first
    transaction_entry.transaction.tags = [ Tag.first, Tag.second ]
    transaction_entry.transaction.save!

    post transactions_bulk_update_url,
         params: {
           bulk_update: {
             entry_ids: [ transaction_entry.id ],
             category_id: Category.second.id,
             tag_ids: []
           }
         },
         as: :json

    assert_redirected_to transactions_url

    transaction_entry.reload
    assert_equal Category.second, transaction_entry.transaction.category
    assert_empty transaction_entry.transaction.tags
  end

  test "bulk update replaces tags when tag_ids explicitly provided" do
    transaction_entry = @user.family.entries.transactions.first
    transaction_entry.transaction.tags = [ Tag.first ]
    transaction_entry.transaction.save!

    new_tag = Tag.second

    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ transaction_entry.id ],
        tag_ids: [ new_tag.id ]
      }
    }

    assert_redirected_to transactions_url

    transaction_entry.reload
    assert_equal [ new_tag.id ], transaction_entry.transaction.tag_ids
  end

  test "the bulk edit form offers to include or exclude from reports, defaulting to no change" do
    get new_transactions_bulk_update_url

    assert_response :success
    assert_select "select[name='bulk_update[excluded]'] option", count: 4
    assert_select "select[name='bulk_update[excluded]'] option[value=reset]", text: "Reset to default (remove my manual setting)"
    assert_select "select[name='bulk_update[excluded]'] option[value='']", text: "No change"
    assert_select "select[name='bulk_update[excluded]'] option[value=true]", text: "Exclude from budgeting and reports"
    assert_select "select[name='bulk_update[excluded]'] option[value=false]", text: "Include in budgeting and reports"
  end

  test "bulk edit excludes selected transactions from reports" do
    entries = @user.family.entries.transactions.first(2)
    entries.each { |entry| entry.update_columns(excluded: false) }

    post transactions_bulk_update_url, params: { bulk_update: { entry_ids: entries.map(&:id), excluded: "true" } }

    assert_equal "2 transactions updated", flash[:notice]
    entries.each do |entry|
      assert entry.reload.excluded?
      assert entry.locked?(:excluded), "the user's choice is locked against rules and syncs"
      assert entry.user_modified?
    end
  end

  test "bulk edit includes excluded transactions in reports again" do
    entries = @user.family.entries.transactions.first(2)
    entries.each { |entry| entry.update_columns(excluded: true) }

    post transactions_bulk_update_url, params: { bulk_update: { entry_ids: entries.map(&:id), excluded: "false" } }

    assert_equal "2 transactions updated", flash[:notice]
    entries.each { |entry| assert_not entry.reload.excluded? }
  end

  test "bulk edit leaves the excluded flag alone when it is not chosen" do
    entry = @user.family.entries.transactions.first
    entry.update_columns(excluded: true)

    post transactions_bulk_update_url, params: { bulk_update: { entry_ids: [ entry.id ], notes: "Just a note", excluded: "" } }

    assert_equal "Just a note", entry.reload.notes
    assert entry.excluded?
  end

  test "bulk edit can change the excluded flag together with other fields" do
    entry = @user.family.entries.transactions.first
    entry.update_columns(excluded: true)

    post transactions_bulk_update_url, params: { bulk_update: { entry_ids: [ entry.id ], notes: "Back in", excluded: "false" } }

    assert_equal "Back in", entry.reload.notes
    assert_not entry.excluded?
  end

  test "bulk reset hands a manually excluded transaction back to its defaults" do
    entry = @user.family.entries.transactions.first
    post transactions_bulk_update_url, params: { bulk_update: { entry_ids: [ entry.id ], excluded: "true" } }
    assert entry.reload.excluded?
    assert entry.locked?(:excluded)
    assert entry.user_modified?

    post transactions_bulk_update_url, params: { bulk_update: { entry_ids: [ entry.id ], excluded: "reset" } }

    entry.reload
    assert_not entry.excluded?
    assert_not entry.locked?(:excluded)
    assert_not entry.user_modified?
  end

  test "after a reset, rules can act on the transaction again" do
    entry = @user.family.entries.transactions.first
    entry.update_columns(excluded: true)
    post transactions_bulk_update_url, params: { bulk_update: { entry_ids: [ entry.id ], excluded: "false" } }
    assert_not entry.reload.excluded?
    assert entry.locked?(:excluded)

    exclude_rule = Rule::ActionExecutor::ExcludeTransaction.new(rules(:one))
    assert_equal 0, exclude_rule.execute(Transaction.where(id: entry.entryable_id)), "a manual choice is respected"

    post transactions_bulk_update_url, params: { bulk_update: { entry_ids: [ entry.id ], excluded: "reset" } }

    assert_equal 1, exclude_rule.execute(Transaction.where(id: entry.entryable_id))
    assert entry.reload.excluded?
  end

  test "bulk reset leaves transactions alone that the user never set themselves" do
    entry = @user.family.entries.transactions.first
    entry.update_columns(excluded: true, user_modified: false, locked_attributes: {})

    post transactions_bulk_update_url, params: { bulk_update: { entry_ids: [ entry.id ], excluded: "reset" } }

    assert entry.reload.excluded?, "excluded by a rule or the system, not by the user"
  end

  test "bulk reset keeps the protection that other manual changes still need" do
    entry = @user.family.entries.transactions.first
    post transactions_bulk_update_url, params: { bulk_update: { entry_ids: [ entry.id ], excluded: "true", notes: "My note" } }

    post transactions_bulk_update_url, params: { bulk_update: { entry_ids: [ entry.id ], excluded: "reset" } }

    entry.reload
    assert_not entry.excluded?
    assert_not entry.locked?(:excluded)
    assert entry.locked?(:notes), "the note stays protected"
    assert entry.user_modified?
    assert_equal "My note", entry.notes
  end

  test "bulk reset can be combined with other edits" do
    entry = @user.family.entries.transactions.first
    post transactions_bulk_update_url, params: { bulk_update: { entry_ids: [ entry.id ], excluded: "true" } }

    post transactions_bulk_update_url, params: { bulk_update: { entry_ids: [ entry.id ], notes: "Edited while resetting", excluded: "reset" } }

    entry.reload
    assert_equal "Edited while resetting", entry.notes
    assert_not entry.excluded?
    assert_not entry.locked?(:excluded)
    assert entry.locked?(:notes)
    assert entry.user_modified?
  end

  test "an unknown excluded choice changes nothing" do
    entry = @user.family.entries.transactions.first
    entry.update_columns(excluded: false)

    post transactions_bulk_update_url, params: { bulk_update: { entry_ids: [ entry.id ], excluded: "banana" } }

    assert_not entry.reload.excluded?
  end
end
