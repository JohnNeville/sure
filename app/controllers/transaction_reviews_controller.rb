class TransactionReviewsController < ApplicationController
  include ActionView::RecordIdentifier

  def update
    @entry = Current.accessible_entries.transactions.find(params[:transaction_id])
    return unless require_account_permission!(@entry.account, :annotate, redirect_path: transaction_path(@entry))

    transaction = @entry.transaction
    transaction.mark_reviewed!(ActiveModel::Type::Boolean.new.cast(params.require(:reviewed)))

    respond_to do |format|
      format.html { redirect_back_or_to transactions_path }
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace(
            dom_id(transaction, :review),
            partial: "transactions/review_button",
            locals: { transaction: transaction }
          ),
          turbo_stream.replace(
            dom_id(transaction, :review_status),
            partial: "transactions/review_status",
            locals: { transaction: transaction, can_annotate: true }
          )
        ]
      end
    end
  end
end
