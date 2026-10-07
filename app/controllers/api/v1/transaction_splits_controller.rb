# frozen_string_literal: true

# Splits one posted transaction into several child transactions that together
# add up to it -- for example one card charge into per-category parts. The parent
# stays in place, excluded from reports, and the children carry the amounts.
#
# Children share the parent's date, account, currency and sign, so a client sends
# positive amounts that sum to the parent's absolute amount.
class Api::V1::TransactionSplitsController < Api::V1::BaseController
  MAX_SPLITS = 50
  BOOLEAN = ActiveModel::Type::Boolean.new

  before_action :ensure_read_scope, only: :show
  before_action :ensure_write_scope, only: [ :create, :update, :destroy ]
  before_action :set_entry

  # The split parent and its children. A child's id resolves to its parent.
  def show
    return render_not_split unless @entry.split_parent?

    render :show
  end

  def create
    reason = unsplittable_reason
    return render_validation_failed("Transaction cannot be split: #{reason}") if reason

    splits = parse_splits
    return if performed?

    @entry.split!(splits)
    @entry.sync_account_later

    render :show, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_validation_failed(e.message)
  end

  # Replaces an existing split with the one in the request.
  def update
    return render_not_split unless @entry.split_parent?

    splits = parse_splits
    return if performed?

    Entry.transaction do
      @entry.unsplit!
      @entry.split!(splits)
    end
    @entry.sync_account_later

    render :show
  rescue ActiveRecord::RecordInvalid => e
    render_validation_failed(e.message)
  end

  # Removes the children and restores the parent.
  def destroy
    return render_not_split unless @entry.split_parent?

    @entry.unsplit!
    @entry.sync_account_later

    render :show
  end

  private

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def set_entry
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:transaction_id])

      accounts = action_name == "show" ? Account.accessible_by(current_resource_owner) : Account.writable_by(current_resource_owner)
      transaction = current_resource_owner.family.transactions
        .joins(entry: :account)
        .merge(accounts)
        .find(params[:transaction_id])

      @entry = transaction.entry
      @entry = @entry.parent_entry if @entry.split_child? && action_name != "create"
    rescue ActiveRecord::RecordNotFound
      render json: { error: "not_found", message: "Transaction not found" }, status: :not_found
    end

    # Why Transaction#splittable? is false, in words.
    def unsplittable_reason
      transaction = @entry.transaction
      return nil if transaction.splittable?

      if @entry.split_child? then "it is already part of a split"
      elsif @entry.split_parent? then "it is already split (use PUT to replace the split)"
      elsif transaction.transfer? then "it is part of a transfer"
      elsif transaction.pending? then "it is pending"
      elsif @entry.excluded? then "it is excluded from budgets and reports"
      else "it is not splittable"
      end
    end

    # @return [Array<Hash>] attributes for Entry#split!, signed like the parent,
    #   or renders a 422 and returns nil
    def parse_splits
      raw = params.permit(splits: [ :name, :amount, :category_id, :notes, :excluded ])[:splits]

      unless raw.is_a?(Array) && raw.size >= 2
        return fail_splits("splits must be a list of at least two entries")
      end
      return fail_splits("splits can hold at most #{MAX_SPLITS} entries") if raw.size > MAX_SPLITS

      precision = Money::Currency.new(@entry.currency).default_precision || 2
      sign = @entry.amount.negative? ? -1 : 1
      category_ids = raw.filter_map { |split| split[:category_id].presence }
      known = current_resource_owner.family.categories
        .where(id: category_ids.select { |id| valid_uuid?(id) }).pluck(:id)
      unknown = category_ids - known
      return fail_splits("Unknown category_id: #{unknown.first}") if unknown.any?

      splits = raw.each_with_index.map do |split, index|
        amount = BigDecimal(split[:amount].to_s, exception: false)
        if amount.nil? || amount <= 0
          return fail_splits("splits[#{index}].amount must be a positive number")
        end
        if amount != amount.round(precision)
          return fail_splits("splits[#{index}].amount has more than #{precision} decimal places for #{@entry.currency}")
        end

        {
          name: split[:name].to_s.strip.presence || @entry.name,
          amount: sign * amount,
          category_id: split[:category_id].presence,
          notes: split[:notes].to_s.strip.presence,
          excluded: BOOLEAN.cast(split[:excluded]) || false
        }
      end

      total = splits.sum { |split| split[:amount] }
      unless total == @entry.amount
        return fail_splits("Split amounts must sum to the transaction amount (expected #{@entry.amount.abs.to_s("F")}, got #{total.abs.to_s("F")})")
      end

      splits
    end

    def fail_splits(message)
      render_validation_failed(message)
      nil
    end

    def render_validation_failed(message)
      render json: { error: "validation_failed", message: message, errors: [ message ] }, status: :unprocessable_entity
    end

    def render_not_split
      render json: { error: "not_found", message: "Transaction is not split" }, status: :not_found
    end
end
