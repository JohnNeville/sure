# frozen_string_literal: true

class Api::V1::SecuritiesController < Api::V1::BaseController
  include Pagy::Backend
  include Api::V1::SecurityResourceFiltering

  before_action :ensure_read_scope, only: [ :index, :show ]
  before_action :ensure_write_scope, only: :update
  before_action :ensure_manual_price_manager, only: :update
  before_action :set_security, only: [ :show, :update ]

  def index
    securities_query = apply_filters(securities_scope).order(:ticker, :exchange_operating_mic, :name)
    @per_page = safe_per_page_param

    @pagy, @securities = pagy(
      securities_query,
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

  # Turns manual pricing on or off for a security. A security's prices are shared by
  # every family on the instance, so this is for admins, and only for securities the
  # caller's own accounts hold or traded.
  def update
    manual_prices = params.dig(:security, :manual_prices)
    unless manual_prices.to_s.downcase.in?(%w[true false 1 0])
      return render_validation_error("security[manual_prices] must be true or false")
    end

    if ActiveModel::Type::Boolean.new.cast(manual_prices)
      @security.enable_manual_prices!
    else
      @security.disable_manual_prices!
    end

    render :show
  end

  private

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def ensure_manual_price_manager
      return if current_resource_owner.admin?

      render json: {
        error: "forbidden",
        message: "Only an admin can change how a security is priced"
      }, status: :forbidden
    end

    def set_security
      raise ActiveRecord::RecordNotFound, "Security not found" unless valid_uuid?(params[:id])

      @security = securities_scope.find(params[:id])
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def securities_scope
      Security
        .where(id: scoped_security_ids)
    end

    def apply_filters(query)
      query = query.where("LOWER(securities.ticker) = ?", params[:ticker].to_s.strip.downcase) if params[:ticker].present?
      query = query.where(exchange_operating_mic: params[:exchange_operating_mic].to_s.strip.upcase) if params[:exchange_operating_mic].present?
      if params[:kind].present?
        invalid_filter!("kind must be one of: #{Security::KINDS.join(', ')}") unless Security::KINDS.include?(params[:kind])

        query = query.where(kind: params[:kind])
      end
      if params.key?(:offline)
        offline = parse_boolean_filter_param(:offline)
        query = query.where(offline: offline)
      end
      if params.key?(:manual_prices)
        manual = parse_boolean_filter_param(:manual_prices)
        query = manual ? query.manual_prices : query.excluding_manual_prices
      end
      query
    end
end
