class RejectedTransfersController < ApplicationController
  before_action :set_rejected_transfer, only: :destroy

  # Transfer matches the user rejected. Automatic matching never proposes them
  # again, so this is where a mistaken rejection is found and undone.
  def index
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.transactions"), transactions_path ],
      [ t(".title"), nil ]
    ]
    @pagy, @rejected_transfers = pagy(
      rejected_transfers_scope
        .includes(inflow_transaction: { entry: :account }, outflow_transaction: { entry: :account })
        .order(created_at: :desc),
      limit: safe_per_page(25)
    )
  end

  # Forgets the rejection: the pair can be proposed again by automatic matching
  # and shows without a label in the manual match dialog.
  def destroy
    return unless require_account_permission!(@rejected_transfer.outflow_transaction.entry.account, redirect_path: rejected_transfers_path)

    @rejected_transfer.destroy!
    redirect_to rejected_transfers_path, notice: t(".success"), status: :see_other
  end

  private
    def set_rejected_transfer
      @rejected_transfer = rejected_transfers_scope.find(params[:id])
    end

    # Only pairs whose two transactions are both in accounts the user can access.
    def rejected_transfers_scope
      accessible_transaction_ids = Transaction.joins(:entry)
                                              .where(entries: { account_id: Current.accessible_accounts.select(:id) })
                                              .select(:id)

      RejectedTransfer.where(inflow_transaction_id: accessible_transaction_ids, outflow_transaction_id: accessible_transaction_ids)
    end
end
