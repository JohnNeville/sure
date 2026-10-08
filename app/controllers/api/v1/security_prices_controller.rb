# frozen_string_literal: true

class Api::V1::SecurityPricesController < Api::V1::BaseController
  include Pagy::Backend
  include Api::V1::SecurityResourceFiltering

  MAX_PRICES_PER_REQUEST = 2_000
  PRICE_SCALE = 4 # security_prices.price is decimal(19, 4)

  before_action :ensure_read_scope, only: [ :index, :show ]
  before_action :ensure_write_scope, only: [ :create, :destroy_range ]
  before_action :ensure_manual_price_manager, only: [ :create, :destroy_range ]
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

  # Bulk upsert of daily prices for a manually priced security, keyed on
  # (security, date, currency) so the same request can be sent again. Prices are
  # stored as settled (not provisional).
  def create
    security = manual_security(params[:security_id])
    return if performed?

    currency = parse_currency(params[:currency].presence || "USD")
    rows = parse_price_rows(params[:prices])
    return if performed?

    existing = security.prices.where(currency: currency, date: rows.keys).pluck(:date, :price).to_h
    created = rows.keys.count { |date| !existing.key?(date) }
    changed = rows.count { |date, price| existing.key?(date) && existing[date] != price }

    if rows.any?
      Security::Price.upsert_all(
        rows.map { |date, price| { security_id: security.id, date: date, price: price, currency: currency, provisional: false } },
        unique_by: %i[security_id date currency]
      )
    end

    render json: { created: created, updated: changed, unchanged: rows.size - created - changed }, status: :ok
  rescue Api::V1::SecurityResourceFiltering::InvalidFilterError => e
    render_validation_error(e.message)
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

    def parse_currency(value)
      code = value.to_s.strip.upcase
      Money::Currency.new(code)
      code
    rescue Money::Currency::UnknownCurrencyError
      invalid_filter!("currency must be a valid ISO 4217 code")
    end

    # @return [Hash{Date => BigDecimal}] one price per date
    def parse_price_rows(raw)
      invalid_filter!("prices must be a list of { date, price } entries") unless raw.is_a?(Array) && raw.any?
      invalid_filter!("prices can hold at most #{MAX_PRICES_PER_REQUEST} entries per request") if raw.size > MAX_PRICES_PER_REQUEST

      raw.each_with_index.each_with_object({}) do |(entry, index), rows|
        entry = entry.to_unsafe_h if entry.respond_to?(:to_unsafe_h)
        invalid_filter!("prices[#{index}] must be an object with date and price") unless entry.is_a?(Hash)

        date = begin
          Date.iso8601(entry.with_indifferent_access[:date].to_s)
        rescue ArgumentError
          invalid_filter!("prices[#{index}].date must be an ISO 8601 date")
        end
        invalid_filter!("prices[#{index}].date cannot be in the future") if date > Date.current

        # Rounded to the column's scale, so storing it and comparing it later agree.
        price = BigDecimal(entry.with_indifferent_access[:price].to_s, exception: false)&.round(PRICE_SCALE)
        invalid_filter!("prices[#{index}].price must be a positive number") if price.nil? || !price.positive?
        invalid_filter!("prices[#{index}].date appears more than once") if rows.key?(date)

        rows[date] = price
      end
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
