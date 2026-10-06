# frozen_string_literal: true

class Api::V1::TransfersController < Api::V1::BaseController
  include Pagy::Backend
  include Api::V1::TransferDecisionFiltering

  before_action :ensure_read_scope, only: %i[index show]
  before_action :ensure_write_scope, only: %i[confirm reject]
  before_action :set_transfer, only: %i[show confirm reject]
  before_action :ensure_writable_transfer, only: %i[confirm reject]

  def index
    transfers_query = apply_transfer_decision_filters(transfers_scope, status_model: Transfer).order(created_at: :desc)
    @per_page = safe_per_page_param

    @pagy, @transfers = pagy(
      transfers_query,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  rescue Api::V1::TransferDecisionFiltering::InvalidFilterError => e
    render_validation_error(e.message)
  end

  def show
    render :show
  end

  # Confirms a pending match. Confirming a transfer that is already confirmed
  # succeeds without changing anything, so a retry is safe.
  def confirm
    @transfer.confirm! unless @transfer.confirmed?

    render :show
  rescue ActiveRecord::RecordInvalid => e
    render_validation_error(e.record.errors.full_messages.to_sentence)
  end

  # Denies a match: the pair is recorded as a rejected transfer, so automatic
  # matching won't propose it again, and the transactions go back to being
  # ordinary transactions. The transfer itself no longer exists afterwards, so
  # the response is the rejected transfer that replaced it.
  def reject
    inflow_transaction_id = @transfer.inflow_transaction_id
    outflow_transaction_id = @transfer.outflow_transaction_id

    @transfer.reject!
    @rejected_transfer = RejectedTransfer
      .includes(inflow_transaction: { entry: :account }, outflow_transaction: { entry: :account })
      .find_by!(inflow_transaction_id: inflow_transaction_id, outflow_transaction_id: outflow_transaction_id)

    render :reject
  end

  private

    def ensure_write_scope
      authorize_scope!(:write)
    end

    # Reading a transfer only needs access to its accounts; deciding on it
    # needs write access to the outflow account, as it does in the web app.
    def ensure_writable_transfer
      outflow_account_id = @transfer.outflow_transaction.entry.account_id
      return if current_resource_owner.family.accounts.writable_by(current_resource_owner).exists?(id: outflow_account_id)

      render_json({ error: "forbidden", message: "You do not have permission to change this transfer" }, status: :forbidden)
    end

    def set_transfer
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @transfer = transfers_scope.find(params[:id])
    end

    def transfers_scope
      transfer_decision_scope(Transfer)
    end
end
