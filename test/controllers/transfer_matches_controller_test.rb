require "test_helper"

class TransferMatchesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
  end

  test "matches existing transaction and creates transfer" do
    inflow_transaction = create_transaction(amount: 100, account: accounts(:depository))
    outflow_transaction = create_transaction(amount: -100, account: accounts(:investment))

    assert_difference "Transfer.count", 1 do
      post transaction_transfer_match_path(inflow_transaction), params: {
        transfer_match: {
          method: "existing",
          matched_entry_id: outflow_transaction.id
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "Transfer created", flash[:notice]
  end

  test "creates transfer for target account" do
    inflow_transaction = create_transaction(amount: 100, account: accounts(:depository))

    assert_difference [ "Transfer.count", "Entry.count", "Transaction.count" ], 1 do
      post transaction_transfer_match_path(inflow_transaction), params: {
        transfer_match: {
          method: "new",
          target_account_id: accounts(:investment).id
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "Transfer created", flash[:notice]
  end

  test "new transfer entry is protected from provider sync" do
    outflow_entry = create_transaction(amount: 100, account: accounts(:depository))

    post transaction_transfer_match_path(outflow_entry), params: {
      transfer_match: {
        method: "new",
        target_account_id: accounts(:investment).id
      }
    }

    transfer = Transfer.order(created_at: :desc).first
    new_entry = transfer.inflow_transaction.entry

    assert new_entry.user_modified?, "New transfer entry should be marked as user_modified to protect from provider sync"
  end

  test "assigns investment_contribution kind and category for investment destination" do
    # Outflow from depository (positive amount), target is investment
    outflow_entry = create_transaction(amount: 100, account: accounts(:depository))

    post transaction_transfer_match_path(outflow_entry), params: {
      transfer_match: {
        method: "new",
        target_account_id: accounts(:investment).id
      }
    }

    outflow_entry.reload
    outflow_txn = outflow_entry.entryable

    assert_equal "investment_contribution", outflow_txn.kind

    category = @user.family.investment_contributions_category
    assert_equal category, outflow_txn.category
  end

  test "the match dialog offers a previously rejected pair, labelled and listed after fresh candidates" do
    account = accounts(:depository)
    savings = accounts(:investment)
    outflow = create_transaction(amount: 60, account: account, name: "Outflow to match")
    rejected_inflow = create_transaction(amount: -60, account: savings, name: "Rejected inflow")
    Transfer.create!(outflow_transaction: outflow.entryable, inflow_transaction: rejected_inflow.entryable, status: "pending").reject!
    fresh_inflow = create_transaction(amount: -60, account: accounts(:other_asset), name: "Fresh inflow", date: Date.current)

    get new_transaction_transfer_match_path(outflow)

    assert_response :success
    assert_select "select[name='transfer_match[matched_entry_id]'] option", count: 2
    options = css_select("select[name='transfer_match[matched_entry_id]'] option").map(&:text)
    assert_match(/Fresh inflow/, options.first)
    assert_no_match(/previously rejected/, options.first)
    assert_match(/Rejected inflow.*\(previously rejected\)/, options.last)
    assert_match "Choosing one matches it again", response.body
    assert_equal fresh_inflow.id, css_select("select[name='transfer_match[matched_entry_id]'] option").first["value"]
  end

  test "matching a previously rejected pair by hand clears the rejection" do
    outflow = create_transaction(amount: 60, account: accounts(:depository), name: "Outflow")
    inflow = create_transaction(amount: -60, account: accounts(:investment), name: "Inflow")
    Transfer.create!(outflow_transaction: outflow.entryable, inflow_transaction: inflow.entryable, status: "pending").reject!
    assert_equal 1, RejectedTransfer.where(inflow_transaction_id: inflow.entryable_id).count

    assert_difference "Transfer.count", 1 do
      post transaction_transfer_match_path(outflow), params: { transfer_match: { method: "existing", matched_entry_id: inflow.id } }
    end

    assert_equal 0, RejectedTransfer.where(inflow_transaction_id: inflow.entryable_id).count
    assert Transfer.find_by!(inflow_transaction_id: inflow.entryable_id).confirmed?
  end

  test "matching a pair that was never rejected leaves other rejections alone" do
    outflow = create_transaction(amount: 60, account: accounts(:depository), name: "Outflow")
    inflow = create_transaction(amount: -60, account: accounts(:investment), name: "Inflow")
    unrelated_outflow = create_transaction(amount: 25, account: accounts(:depository), name: "Unrelated out")
    unrelated_inflow = create_transaction(amount: -25, account: accounts(:investment), name: "Unrelated in")
    Transfer.create!(outflow_transaction: unrelated_outflow.entryable, inflow_transaction: unrelated_inflow.entryable, status: "pending").reject!

    post transaction_transfer_match_path(outflow), params: { transfer_match: { method: "existing", matched_entry_id: inflow.id } }

    assert_equal 1, RejectedTransfer.where(inflow_transaction_id: unrelated_inflow.entryable_id).count
  end
end
