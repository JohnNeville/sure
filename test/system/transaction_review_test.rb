require "application_system_test_case"

class TransactionReviewTest < ApplicationSystemTestCase
  include ActionView::RecordIdentifier

  setup do
    sign_in @user = users(:family_admin)
    @entry = @user.family.entries.transactions.order(date: :desc).first
    @entry.transaction.update_columns(reviewed_at: nil)
    page.current_window.resize_to(1280, 900)
  end

  test "a row's review button marks a transaction reviewed and back, updating in place" do
    visit transactions_url
    button = "##{dom_id(@entry.entryable, :review)} button"

    assert_selector "#{button}[aria-pressed='false']"

    find(button).click
    assert_selector "#{button}[aria-pressed='true']"
    assert @entry.transaction.reload.reviewed?

    find(button).click
    assert_selector "#{button}[aria-pressed='false']"
    assert_not @entry.transaction.reload.reviewed?
  end

  test "the details pane shows the review state and its toggle updates the row behind it" do
    visit transactions_url

    # Load the details pane into the drawer frame, as the row's link does.
    page.execute_script <<~JS
      document.querySelector("turbo-frame#drawer").src = "#{transaction_path(@entry)}"
    JS

    status = "##{dom_id(@entry.entryable, :review_status)}"
    assert_selector status, text: "Not reviewed yet", visible: :all

    find("#{status} label", visible: :all).click

    assert_selector status, text: "Marked reviewed on", visible: :all
    assert_selector "##{dom_id(@entry.entryable, :review)} button[aria-pressed='true']", visible: :all
    assert @entry.transaction.reload.reviewed?
  end
end
