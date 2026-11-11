# frozen_string_literal: true

class Api::V1::SecurityPricesController < Api::V1::BaseController
  include Pagy::Backend
  include Api::V1::SecurityResourceFiltering

  before_action :ensure_read_scope, only: %i[index show]
  before_action :ensure_write_scope, only: %i[create destroy_range]
  before_action :ensure_self_hosted, only: :create
  before_action :reject_guest_writes!, only: %i[create destroy_range]
  before_action :ensure_manual_price_manager, only: :destroy_range
  before_action :set_security_price, only: :show

  def index
    security_prices_query = apply_filters(security_prices_scope).order(date: :desc, created_at: :desc)
    @per_page = safe_per_page_param

    @pagy, @security_prices = pagy(
      security_prices_query,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  rescue Api::V1::SecurityResourceFiltering::InvalidFilterError => e
    render_validation_error(e.message)
  end

  def show
    render :show
  end

  # Stores closing prices for one security no provider tracks, traded in an
  # account the caller can write to, or held in a linked one.
  # The rows are shared by every family holding that security, which is why
  # this is limited to self-hosted instances.
  def create
    security, accounts = writable_security_and_accounts

    @result = security.import_manual_prices!(price_rows, accounts: accounts)
    @security = security
    accounts.find_each(&:sync_later)

    render :create
  rescue Security::ManualPriceImport::Invalid => e
    render_json({ error: "validation_failed", message: "Prices were not imported", errors: e.errors }, status: :unprocessable_entity)
  end

  # Deletes a range of a manually priced security's prices, so a bad load can be
  # undone. Both bounds are required: there is no "delete everything" call.
  def destroy_range
    security = manual_security(params[:security_id])
    return if performed?

    unless params[:start_date].present? && params[:end_date].present?
      return render_validation_error("start_date and end_date are both required")
    end

    prices = security.prices.where("security_prices.date >= ?", parse_date_param(:start_date))
                            .where("security_prices.date <= ?", parse_date_param(:end_date))
    prices = prices.where(currency: params[:currency].to_s.strip.upcase) if params[:currency].present?

    render json: { deleted: prices.delete_all }
  rescue Api::V1::SecurityResourceFiltering::InvalidFilterError => e
    render_validation_error(e.message)
  end

  private
    def ensure_write_scope
      authorize_scope!(:write)
    end

    def ensure_self_hosted
      return if self_hosted?

      render_json({
        error: "self_hosted_only",
        message: "Security prices are shared across families, so importing them is only available on self-hosted instances"
      }, status: :forbidden)
    end

    # The security and the caller's writable accounts eligible to price it.
    # Unknown, malformed and unreachable ids all get the same 404.
    def writable_security_and_accounts
      security_id = params.require(:security_id).to_s
      security = Security.find_by(id: security_id) if valid_uuid?(security_id)
      accounts = writable_accounts_referencing(security) if security
      raise ActiveRecord::RecordNotFound, "Security not found" unless accounts&.exists?

      [ security, accounts ]
    end

    # Only accounts whose position survives the sync this request queues: one
    # with a trade in the security, or a linked account, whose holdings come
    # from its provider and whose reverse sync never purges. An unlinked
    # account's forward sync rebuilds holdings from trades and deletes every
    # other non-provider row (Holding::Materializer#purge_stale_holdings), so
    # a holding no trade backs would be removed rather than revalued.
    def writable_accounts_referencing(security)
      writable = current_resource_owner.family.accounts.visible.writable_by(current_resource_owner).select(:id)
      traded = Account.where(id: Trade.joins(:entry).where(security: security).select("entries.account_id"))
      provider_held = Account.where(id: Holding.where(security: security).select(:account_id))
        .where(id: Account.linked.select(:id))

      Account.where(id: writable).and(traded.or(provider_held))
    end

    def price_rows
      rows = params[:prices]
      unless rows.is_a?(Array)
        raise Security::ManualPriceImport::Invalid.new([ { index: nil, message: "prices must be a list" } ])
      end

      rows.map { |row| row.is_a?(ActionController::Parameters) ? row.permit(:date, :price, :currency).to_h : row }
    end

    # Prices are shared by every family on the instance, so writing them is for admins.
    def ensure_manual_price_manager
      return if current_resource_owner.admin?

      render json: {
        error: "forbidden",
        message: "Only an admin can change a security's prices"
      }, status: :forbidden
    end

    # The security must be one the caller's accounts hold or traded, and it must be
    # set to manual prices. Renders the error and returns nil otherwise.
    def manual_security(security_id)
      unless valid_uuid?(security_id.to_s)
        render_validation_error("security_id must be a valid UUID")
        return nil
      end

      security = Security.where(id: scoped_security_ids).find_by(id: security_id)
      unless security
        render json: { error: "not_found", message: "Security not found" }, status: :not_found
        return nil
      end

      unless security.manual_prices?
        render_validation_error("Security is not set to manual prices. Set security[manual_prices]=true on the security first.")
        return nil
      end

      security
    end

    def set_security_price
      raise ActiveRecord::RecordNotFound, "Security price not found" unless valid_uuid?(params[:id])

      @security_price = security_prices_scope.find(params[:id])
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def security_prices_scope
      Security::Price
        .where(security_id: scoped_security_ids)
        .includes(:security)
    end

    def apply_filters(query)
      if params[:security_id].present?
        invalid_filter!("security_id must be a valid UUID") unless valid_uuid?(params[:security_id])

        query = query.where(security_id: params[:security_id])
      end

      query = query.where(currency: params[:currency].to_s.strip.upcase) if params[:currency].present?
      query = query.where("security_prices.date >= ?", parse_date_param(:start_date)) if params[:start_date].present?
      query = query.where("security_prices.date <= ?", parse_date_param(:end_date)) if params[:end_date].present?
      if params.key?(:provisional)
        provisional = parse_boolean_filter_param(:provisional)
        query = query.where(provisional: provisional)
      end
      query
    end
end
