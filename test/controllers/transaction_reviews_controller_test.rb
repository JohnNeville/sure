require "test_helper"

class TransactionReviewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @entry = entries(:transaction)
    @transaction = transactions(:one)
  end

  test "marks a transaction as reviewed" do
    assert_not @transaction.reviewed?

    patch transaction_review_url(@entry), params: { reviewed: true }, as: :turbo_stream

    assert_response :success
    assert @transaction.reload.reviewed?
    assert_match "review_transaction_#{@transaction.id}", response.body
  end

  test "marks a reviewed transaction as not reviewed" do
    @transaction.mark_reviewed!

    patch transaction_review_url(@entry), params: { reviewed: false }, as: :turbo_stream

    assert_response :success
    assert_not @transaction.reload.reviewed?
  end

  test "html requests redirect back" do
    patch transaction_review_url(@entry), params: { reviewed: true }, headers: { "HTTP_REFERER" => transactions_url }

    assert_redirected_to transactions_url
    assert @transaction.reload.reviewed?
  end

  test "reviewing does not mark the entry as user modified" do
    patch transaction_review_url(@entry), params: { reviewed: true }, as: :turbo_stream

    assert_not @entry.reload.user_modified?
  end

  test "reviewing refreshes the entries cache version" do
    family = families(:dylan_family)
    before = family.entries_cache_version

    travel 1.minute do
      patch transaction_review_url(@entry), params: { reviewed: true }, as: :turbo_stream
    end

    assert_not_equal before, family.reload.entries_cache_version
  end

  test "cannot review another family's transaction" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en")
    account = other_family.accounts.create!(name: "Checking", balance: 0, currency: "USD", accountable: Depository.new)
    foreign = account.entries.create!(name: "Foreign", date: Date.current, amount: 5, currency: "USD", entryable: Transaction.new)

    patch transaction_review_url(foreign), params: { reviewed: true }, as: :turbo_stream

    assert_response :not_found
    assert_not foreign.transaction.reload.reviewed?
  end

  test "requires the reviewed parameter" do
    patch transaction_review_url(@entry), as: :turbo_stream

    assert_response :bad_request
    assert_not @transaction.reload.reviewed?
  end
end
