class TransferMatchesController < ApplicationController
  before_action :set_entry

  def new
    # Preloaded for the logo selects, which call Account#logo_url per option.
    @accounts = Current.family.accounts.writable_by(Current.user).visible.alphabetically.where.not(id: @entry.account_id)
      .includes(:account_providers, logo_attachment: :blob)
    @candidate_entries = writable_candidate_entries
  end

  def create
    return unless require_account_permission!(@entry.account, redirect_path: transactions_path)

    target_account = resolve_target_account
    return unless require_account_permission!(target_account, redirect_path: transactions_path)

    @transfer = build_transfer
    Transfer.transaction do
      @transfer.save!
      @transfer.confirm!

      # The user has now matched this pair, so an earlier rejection no longer applies.
      RejectedTransfer.where(
        inflow_transaction_id: @transfer.inflow_transaction_id,
        outflow_transaction_id: @transfer.outflow_transaction_id
      ).delete_all
    end

    @transfer.sync_account_later

    redirect_back_or_to transactions_path, notice: t(".success")
  end

  # "Not a transfer" on the list's transfer hint.
  def destroy
    return unless require_account_permission!(@entry.account, redirect_path: transactions_path)

    Current.family.dismiss_transfer_hint!(@entry.transaction, user: Current.user)

    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.remove(helpers.dom_id(@entry.transaction, :transfer_hint)) }
      format.html { redirect_back_or_to transactions_path }
    end
  end

  private
    def set_entry
      @entry = Current.accessible_entries.find(params[:transaction_id])
    end

    # Counterpart entries of the family-wide candidates, in candidate order and
    # limited to accounts the user can write to (create would reject the others
    # anyway).
    def writable_candidate_entries
      candidates = @entry.transaction.transfer_match_candidates
      counterpart_of = ->(candidate) { @entry.amount.negative? ? candidate.outflow_transaction_id : candidate.inflow_transaction_id }
      counterpart_ids = candidates.map(&counterpart_of)
      rejected_transaction_ids = candidates.select(&:previously_rejected).map(&counterpart_of)

      entries_by_transaction_id = Entry
        .where(entryable_type: "Transaction", entryable_id: counterpart_ids, account_id: @accounts.map(&:id))
        .includes(account: [ :account_providers, { logo_attachment: :blob } ])
        .index_by(&:entryable_id)

      # Entries of pairs the user rejected before, which the dialog still offers
      # but labels.
      @rejected_entry_ids = entries_by_transaction_id.values_at(*rejected_transaction_ids).compact.map(&:id)

      counterpart_ids.filter_map { |id| entries_by_transaction_id[id] }
    end

    def transfer_match_params
      params.require(:transfer_match).permit(:method, :matched_entry_id, :target_account_id)
    end

    def resolve_target_account
      if transfer_match_params[:method] == "new"
        accessible_accounts.find(transfer_match_params[:target_account_id])
      else
        Current.accessible_entries.find(transfer_match_params[:matched_entry_id]).account
      end
    end

    def build_transfer
      if transfer_match_params[:method] == "new"
        target_account = accessible_accounts.find(transfer_match_params[:target_account_id])

        missing_transaction = Transaction.new(
          entry: target_account.entries.build(
            amount: @entry.amount * -1,
            currency: @entry.currency,
            date: @entry.date,
            name: "Transfer to #{@entry.amount.negative? ? @entry.account.name : target_account.name}",
            user_modified: true,
          )
        )

        transfer = Transfer.find_or_initialize_by(
          inflow_transaction: @entry.amount.positive? ? missing_transaction : @entry.transaction,
          outflow_transaction: @entry.amount.positive? ? @entry.transaction : missing_transaction
        )
        transfer.status = "confirmed"
        transfer
      else
        target_transaction = Current.accessible_entries.find(transfer_match_params[:matched_entry_id])

        transfer = Transfer.find_or_initialize_by(
          inflow_transaction: @entry.amount.negative? ? @entry.transaction : target_transaction.transaction,
          outflow_transaction: @entry.amount.negative? ? target_transaction.transaction : @entry.transaction
        )
        transfer.status = "confirmed"
        transfer
      end
    end
end
