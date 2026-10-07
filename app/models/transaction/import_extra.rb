# Validates and merges the `import` namespace of Transaction#extra.
#
# `extra` is shared with the bank-sync providers (plaid, simplefin) and with
# system features (goal, potential_posted_match, exchange_rate), so API clients
# may only write under one key of their own: `import`. It carries the details a
# backfill or a retailer integration knows about a transaction that Sure has no
# column for -- the bank's original description, a statement reference, an order
# number -- and renders in the same "Additional details" section as provider data.
#
#   requested = Transaction::ImportExtra.new(extra: { "import" => { "source" => "Quicken" } })
#   requested.valid?                 # => true
#   requested.apply_to(tx.extra)     # => tx.extra with import deep-merged, nothing else touched
class Transaction::ImportExtra
  NAMESPACE = "import".freeze
  KEY_FORMAT = /\A[a-z][a-z0-9_]{0,63}\z/
  MAX_KEYS = 30
  MAX_VALUE_LENGTH = 1_000

  # Keys the UI labels. Others are accepted and shown under a humanized name.
  KNOWN_KEYS = %w[
    original_description posting_date bank_transaction_id reference
    check_number original_memo original_category source source_account
  ].freeze

  attr_reader :errors

  # @param extra [ActionController::Parameters, Hash, nil] the request's `extra` value
  def initialize(extra)
    @errors = []
    @changes = parse(extra)
  end

  def valid?
    errors.empty?
  end

  # Deep-merges the requested keys into the existing import hash. A null or blank
  # value removes that key; a null namespace removes all of it. Everything outside
  # `import` is returned untouched.
  #
  # @param existing [Hash, nil] the transaction's current extra
  # @return [Hash] the new extra
  def apply_to(existing)
    result = (existing.is_a?(Hash) ? existing : {}).deep_dup
    return result unless @changes

    current = result[NAMESPACE].is_a?(Hash) ? result[NAMESPACE] : {}
    merged = @changes == :clear ? {} : current.merge(@changes).compact

    if merged.size > MAX_KEYS
      errors << "extra.import can hold at most #{MAX_KEYS} keys"
      return result
    end

    merged.empty? ? result.delete(NAMESPACE) : result[NAMESPACE] = merged
    result
  end

  private
    # @return [Hash, Symbol, nil] the key changes, :clear to drop the namespace, nil when none requested
    def parse(extra)
      extra = extra.to_unsafe_h if extra.respond_to?(:to_unsafe_h)
      unless extra.is_a?(Hash)
        errors << "extra must be an object"
        return nil
      end

      extra = extra.stringify_keys
      unknown = extra.keys - [ NAMESPACE ]
      errors << "extra only accepts the \"#{NAMESPACE}\" key (got: #{unknown.join(", ")})" if unknown.any?
      return nil unless extra.key?(NAMESPACE)

      requested = extra[NAMESPACE]
      return :clear if requested.nil?

      unless requested.is_a?(Hash)
        errors << "extra.#{NAMESPACE} must be an object or null"
        return nil
      end

      requested.each_with_object({}) do |(key, value), changes|
        key = key.to_s
        unless key.match?(KEY_FORMAT)
          errors << "extra.#{NAMESPACE} key #{key.inspect} must be lowercase letters, digits and underscores"
          next
        end

        case value
        when nil
          changes[key] = nil
        when String, Numeric
          text = value.to_s.strip
          if text.length > MAX_VALUE_LENGTH
            errors << "extra.#{NAMESPACE}.#{key} must be at most #{MAX_VALUE_LENGTH} characters"
          else
            changes[key] = text.presence
          end
        else
          errors << "extra.#{NAMESPACE}.#{key} must be a string"
        end
      end
    end
end
