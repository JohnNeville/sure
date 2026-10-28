require "application_system_test_case"

class AccountFilterGroupsTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)

    @cash = @user.family.accounts.create!(name: "Group Test Checking", accountable: Depository.new, balance: 100, currency: "USD")
    @other_cash = @user.family.accounts.create!(name: "Group Test Savings", accountable: Depository.new, balance: 100, currency: "USD")
    @card = @user.family.accounts.create!(name: "Group Test Card", accountable: CreditCard.new, balance: 100, currency: "USD")

    visit transactions_url
    find("#transaction-filters-button").click

    within "#transaction-filters-menu" do
      click_button "Account"
    end
  end

  def cash_group = find("#account_group_depository")

  test "checking a group checks all of its accounts and nothing else" do
    within "#transaction-filters-menu" do
      cash_group.check

      assert find_field(@cash.name).checked?
      assert find_field(@other_cash.name).checked?
      assert_not find_field(@card.name).checked?
    end
  end

  test "unchecking one account leaves the group indeterminate, and rechecking it checks the group" do
    within "#transaction-filters-menu" do
      cash_group.check
      uncheck(@cash.name)

      assert_not cash_group.checked?
      assert page.evaluate_script("document.getElementById('account_group_depository').indeterminate")

      check(@cash.name)

      assert cash_group.checked?
      assert_not page.evaluate_script("document.getElementById('account_group_depository').indeterminate")
    end
  end

  test "unchecking a checked group clears its accounts" do
    within "#transaction-filters-menu" do
      cash_group.check
      cash_group.uncheck

      assert_not find_field(@cash.name).checked?
      assert_not find_field(@other_cash.name).checked?
    end
  end

  test "searching hides groups with no matching account, and a group check only affects the matches" do
    within "#transaction-filters-menu" do
      fill_in "Filter accounts", with: "Group Test Checking"

      assert_selector "#account_group_depository"
      assert_no_selector "#account_group_credit_card"

      cash_group.check

      assert find_field(@cash.name).checked?
      assert_not find_field(@other_cash.name, visible: :all).checked?
      assert page.evaluate_script("document.getElementById('account_group_depository').indeterminate")
    end
  end

  test "the groups submit only the individual accounts to the filter" do
    within "#transaction-filters-menu" do
      cash_group.check
      click_button "Apply"
    end

    assert_current_path(/q%5Baccounts%5D%5B%5D=Group\+Test\+Checking/)
    assert_current_path(/q%5Baccounts%5D%5B%5D=Group\+Test\+Savings/)
    assert_no_match(/account_group/, page.current_url)
  end
end
