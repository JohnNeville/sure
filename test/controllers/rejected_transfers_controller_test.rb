require "test_helper"

class RejectedTransfersControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @checking = @family.accounts.create!(name: "Rejected Checking", accountable: Depository.new, balance: 500, currency: "USD")
    @savings = @family.accounts.create!(name: "Rejected Savings", accountable: Depository.new, balance: 100, currency: "USD")
    @rejected = rejected_pair(@checking, @savings, "Bank withdrawal 1234", "Savings deposit 5678", 75)
  end

  def rejected_pair(from_account, to_account, outflow_name, inflow_name, amount)
    outflow = create_transaction(account: from_account, amount: amount, name: outflow_name, date: Date.current)
    inflow = create_transaction(account: to_account, amount: -amount, name: inflow_name, date: Date.current)
    Transfer.create!(outflow_transaction: outflow.entryable, inflow_transaction: inflow.entryable, status: "pending").reject!
    RejectedTransfer.find_by!(inflow_transaction_id: inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)
  end

  test "lists rejected transfer matches with the transaction recorded in each account" do
    get rejected_transfers_url

    assert_response :success
    assert_select "td", text: /Bank withdrawal 1234/
    assert_select "td", text: /Rejected Checking/
    assert_select "td", text: /Savings deposit 5678/
    assert_select "td", text: /Rejected Savings/
    assert_select "a[href=?]", new_transaction_transfer_match_path(@rejected.outflow_transaction.entry), text: "Match"
  end

  test "shows an empty state" do
    RejectedTransfer.delete_all

    get rejected_transfers_url

    assert_response :success
    assert_select "p", text: "You haven't rejected any transfer matches."
  end

  test "only lists pairs from the user's own family" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en")
    other_checking = other_family.accounts.create!(name: "Other Checking", accountable: Depository.new, balance: 0, currency: "USD")
    other_savings = other_family.accounts.create!(name: "Other Savings", accountable: Depository.new, balance: 0, currency: "USD")
    rejected_pair(other_checking, other_savings, "Foreign withdrawal", "Foreign deposit", 20)

    get rejected_transfers_url

    assert_no_match "Foreign withdrawal", response.body
    assert_match "Bank withdrawal 1234", response.body
  end

  test "restoring removes the rejection so the pair can be matched automatically again" do
    inflow_id = @rejected.inflow_transaction_id
    assert_empty(@family.transfer_match_candidates(include_rejected: false).select { |match| match.inflow_transaction_id == inflow_id })

    assert_difference -> { RejectedTransfer.count }, -1 do
      delete rejected_transfer_url(@rejected)
    end

    assert_redirected_to rejected_transfers_url
    assert_response :see_other
    assert_includes @family.transfer_match_candidates(include_rejected: false).map(&:inflow_transaction_id), inflow_id
  end

  test "cannot restore another family's rejection" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en")
    other_checking = other_family.accounts.create!(name: "Other Checking", accountable: Depository.new, balance: 0, currency: "USD")
    other_savings = other_family.accounts.create!(name: "Other Savings", accountable: Depository.new, balance: 0, currency: "USD")
    foreign = rejected_pair(other_checking, other_savings, "Foreign withdrawal", "Foreign deposit", 20)

    assert_no_difference -> { RejectedTransfer.count } do
      delete rejected_transfer_url(foreign)
    end

    assert_response :not_found
  end

  test "a user without write access to the outflow account cannot restore it" do
    member = users(:family_member)
    [ @checking, @savings ].each { |account| account.account_shares.find_or_initialize_by(user: member).update!(permission: "read_only") }
    sign_in member

    get rejected_transfers_url
    assert_response :success

    assert_no_difference -> { RejectedTransfer.count } do
      delete rejected_transfer_url(@rejected)
    end
  end
end
