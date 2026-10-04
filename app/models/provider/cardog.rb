class Provider::Cardog < Provider
  include VehicleValuationConcept, RateLimitable
  extend SslConfigurable

  # Subclass so errors caught in this provider are raised as Provider::Cardog::Error
  Error = Class.new(Provider::Error)
  RateLimitError = Class.new(Error)

  # Minimum delay between requests to avoid rate limiting (in seconds)
  MIN_REQUEST_INTERVAL = 1.0

  # Cardog bills in credits: resolving a name to a model-year costs 1 and a
  # market quote costs 5, so one valuation lookup is 6.
  RESOLVE_CREDITS = 1
  QUOTE_CREDITS = 5
  LOOKUP_CREDITS = RESOLVE_CREDITS + QUOTE_CREDITS

  # Monthly credits on Cardog's free tier. Override with
  # CARDOG_MAX_REQUESTS_PER_MONTH for paid plans.
  MAX_CREDITS_PER_MONTH = 50

  def initialize(api_key)
    @api_key = api_key # pipelock:ignore
  end

  # Returns the median live-listing asking price for the vehicle's model year.
  # This is market data, not a mileage- or condition-adjusted valuation.
  def fetch_vehicle_valuation(year:, make:, model:)
    with_provider_response do
      # Reserve the whole lookup up front so a nearly spent budget can't pay
      # for the resolve call and then fail on the quote.
      record_credits!(LOOKUP_CREDITS)
      @credits_spent = 0
      @reported_usage = nil

      begin
        ref = resolve_model_year("#{year} #{make} #{model}".squish)
        price = fetch_quote(ref)["priceMedian"]
        raise Error.new(I18n.t("providers.cardog.errors.no_valuation")) if price.blank?

        VehicleValuation.new(
          valuation: BigDecimal(price.to_s),
          currency: valuation_currency,
          year: year,
          make: make,
          model: model
        )
      ensure
        if @reported_usage
          # Cardog's own figures cover every use of the key, so they replace
          # the local estimate.
          ProviderRequestCount.set!(provider_key, @reported_usage[:used], limit: @reported_usage[:allowance])
        else
          # Cardog doesn't charge for non-2xx responses, so only calls that
          # succeeded count against the budget.
          refund_credits!(LOOKUP_CREDITS - @credits_spent)
        end
      end
    end
  end

  private
    attr_reader :api_key

    def resolve_model_year(query)
      parsed = metered_get("/v2/entities/resolve", RESOLVE_CREDITS, q: query, domain: "model-year")
      parsed.dig("best", "ref").presence || raise(Error.new(I18n.t("providers.cardog.errors.not_found")))
    end

    def fetch_quote(ref)
      metered_get("/v2/quotes/#{ERB::Util.url_encode(ref)}", QUOTE_CREDITS)
    end

    def metered_get(path, cost, params = {})
      throttle_request

      response = client.get(path) { |req| req.params.merge!(params) }
      @credits_spent += cost
      remember_reported_usage(response)
      JSON.parse(response.body)
    end

    # Metered responses report the account's allowance and what is left of it.
    def remember_reported_usage(response)
      allowance = Integer(response.headers["X-Credits-Allowance"], exception: false)
      remaining = Integer(response.headers["X-Credits-Remaining"], exception: false)
      return unless allowance && remaining

      @reported_usage = { used: [ allowance - remaining, 0 ].max, allowance: allowance }
    end

    def default_error_transformer(error)
      case error
      when Faraday::UnauthorizedError
        Error.new(I18n.t("providers.cardog.errors.unauthorized"))
      when Faraday::ClientError
        if error.response_status == 402
          Error.new(I18n.t("providers.cardog.errors.insufficient_credits"))
        elsif error.is_a?(Faraday::ResourceNotFound)
          Error.new(I18n.t("providers.cardog.errors.not_found"))
        else
          super
        end
      else
        super
      end
    end

    def base_url
      ENV["CARDOG_URL"] || "https://api.cardog.app"
    end

    def client
      @client ||= Faraday.new(url: base_url, ssl: self.class.faraday_ssl_options) do |faraday|
        # Retry transient connection failures so a network blip doesn't burn
        # credits from the tight monthly budget
        faraday.request(:retry, {
          max: 3,
          interval: 1.0,
          interval_randomness: 0.5,
          backoff_factor: 2,
          exceptions: Faraday::Retry::Middleware::DEFAULT_EXCEPTIONS + [ Faraday::ConnectionFailed ]
        })
        faraday.request :json
        faraday.response :raise_error
        faraday.options.timeout = 10
        faraday.options.open_timeout = 5
        faraday.headers["x-api-key"] = api_key
        faraday.headers["Accept"] = "application/json"
      end
    end
end
