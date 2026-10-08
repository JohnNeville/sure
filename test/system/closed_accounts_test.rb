require "application_system_test_case"

class ClosedAccountsTest < ApplicationSystemTestCase
  include ActionView::RecordIdentifier

  setup do
    sign_in @user = users(:family_admin)
    @account = @user.family.accounts.create!(
      name: "Closed account system test", balance: 0, currency: "USD",
      accountable: Depository.new, owner: @user
    )
    visit accounts_url
  end

  test "can close an account and reopen it from the closed section" do
    within "##{dom_id(@account)}" do
      find("button[aria-haspopup='menu']").click
      click_on "Close account"
    end

    assert_text "What this means"
    click_button "Close account"

    assert_text "closed as of"
    assert_text "1 closed account"
    assert @account.reload.closed?

    find("summary", text: "1 closed account").click
    within "##{dom_id(@account)}" do
      assert_text "Closed"
      find("button[aria-haspopup='menu']").click
      click_on "Reopen account"
    end

    assert_text "reopened"
    assert_no_text "closed account"
    assert @account.reload.active?
  end
end
