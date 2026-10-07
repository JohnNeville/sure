# Validates and merges the namespaces API clients may write into Transaction#extra.
#
# `extra` is shared with the bank-sync providers (plaid, simplefin) and with
# system features (goal, potential_posted_match, exchange_rate), so a client may
# only write under keys of its own:
#
# - `import`: what a backfill knows about a transaction that Sure has no column
#   for -- the bank's original description, a statement reference, a source.
# - `retail`: an order behind a charge, pushed by a retailer integration -- the
#   retailer, order number and totals, plus the order's `items`.
#
# Both render in the "Additional details" section next to provider data.
#
#   request = Transaction::ClientExtra.new({ "import" => { "source" => "Quicken" } })
#   request.valid?                 # => true
#   request.apply_to(tx.extra)     # => tx.extra with import deep-merged, nothing else touched
class Transaction::ClientExtra
  NAMESPACES = %w[import retail].freeze
  KEY_FORMAT = /\A[a-z][a-z0-9_]{0,63}\z/
  MAX_KEYS = 30
  MAX_VALUE_LENGTH = 1_000
  MAX_ITEMS = 100

  # Keys the UI labels, in display order. Others are accepted and shown under a
  # humanized name.
  KNOWN_KEYS = {
    "import" => %w[
      original_description posting_date bank_transaction_id reference
      check_number original_memo original_category source source_account
    ],
    "retail" => %w[
      retailer order_number order_date order_url status
      order_total subtotal shipping tax discounts payment_last4
    ]
  }.freeze

  # Keys inside a namespace that hold a list of flat objects instead of a string.
  # The list is replaced as a whole when sent, since merging two lists of items
  # has no sensible meaning.
  LIST_KEYS = { "retail" => %w[items] }.freeze

  attr_reader :errors

  # @param extra [ActionController::Parameters, Hash, nil] the request's `extra` value
  def initialize(extra)
    @errors = []
    @changes = parse(extra)
  end

  def valid?
    errors.empty?
  end

  # Deep-merges the requested keys into each namespace. A null or blank value
  # removes that key; a null namespace removes all of it. Everything outside the
  # requested namespaces is returned untouched. Adds to #errors, and returns the
  # extra unchanged, if the merge would exceed a limit.
  #
  # @param existing [Hash, nil] the transaction's current extra
  # @return [Hash] the new extra
  def apply_to(existing)
    result = (existing.is_a?(Hash) ? existing : {}).deep_dup

    @changes.each do |namespace, changes|
      current = result[namespace].is_a?(Hash) ? result[namespace] : {}
      merged = changes == :clear ? {} : current.merge(changes).compact

      if merged.except(*LIST_KEYS.fetch(namespace, [])).size > MAX_KEYS
        errors << "extra.#{namespace} can hold at most #{MAX_KEYS} keys"
        return (existing.is_a?(Hash) ? existing : {}).deep_dup
      end

      merged.empty? ? result.delete(namespace) : result[namespace] = merged
    end

    result
  end

  private
    # @return [Hash{String => Hash, Symbol}] per namespace, the key changes or :clear
    def parse(extra)
      extra = extra.to_unsafe_h if extra.respond_to?(:to_unsafe_h)
      unless extra.is_a?(Hash)
        errors << "extra must be an object"
        return {}
      end

      extra = extra.stringify_keys
      unknown = extra.keys - NAMESPACES
      errors << "extra only accepts the #{NAMESPACES.map { |n| "\"#{n}\"" }.to_sentence} keys (got: #{unknown.join(", ")})" if unknown.any?

      extra.slice(*NAMESPACES).each_with_object({}) do |(namespace, requested), changes|
        parsed = parse_namespace(namespace, requested)
        changes[namespace] = parsed unless parsed.nil?
      end
    end

    def parse_namespace(namespace, requested)
      return :clear if requested.nil?

      requested = requested.to_unsafe_h if requested.respond_to?(:to_unsafe_h)
      unless requested.is_a?(Hash)
        errors << "extra.#{namespace} must be an object or null"
        return nil
      end

      list_keys = LIST_KEYS.fetch(namespace, [])

      requested.each_with_object({}) do |(key, value), changes|
        key = key.to_s
        unless key.match?(KEY_FORMAT)
          errors << "extra.#{namespace} key #{key.inspect} must be lowercase letters, digits and underscores"
          next
        end

        if list_keys.include?(key)
          changes[key] = parse_list("#{namespace}.#{key}", value)
        else
          changes[key] = parse_text("#{namespace}.#{key}", value)
        end
      end
    end

    # @return [String, nil] the stripped text, nil to remove the key
    def parse_text(path, value)
      case value
      when nil
        nil
      when String, Numeric
        text = value.to_s.strip
        if text.length > MAX_VALUE_LENGTH
          errors << "extra.#{path} must be at most #{MAX_VALUE_LENGTH} characters"
          nil
        else
          text.presence
        end
      else
        errors << "extra.#{path} must be a string"
        nil
      end
    end

    # A list of flat objects, such as an order's items. Blank values inside an
    # object are dropped and objects left empty are skipped.
    #
    # @return [Array<Hash>, nil] nil removes the key
    def parse_list(path, value)
      return nil if value.nil?

      value = value.values if value.respond_to?(:values) && !value.is_a?(Array) # form-encoded arrays arrive as index hashes
      unless value.is_a?(Array)
        errors << "extra.#{path} must be a list of objects or null"
        return nil
      end

      if value.size > MAX_ITEMS
        errors << "extra.#{path} can hold at most #{MAX_ITEMS} entries"
        return nil
      end

      value.each_with_index.filter_map do |entry, index|
        entry = entry.to_unsafe_h if entry.respond_to?(:to_unsafe_h)
        unless entry.is_a?(Hash)
          errors << "extra.#{path}[#{index}] must be an object"
          next
        end

        if entry.size > MAX_KEYS
          errors << "extra.#{path}[#{index}] can hold at most #{MAX_KEYS} keys"
          next
        end

        fields = entry.each_with_object({}) do |(field, field_value), item|
          field = field.to_s
          unless field.match?(KEY_FORMAT)
            errors << "extra.#{path}[#{index}] key #{field.inspect} must be lowercase letters, digits and underscores"
            next
          end

          item[field] = parse_text("#{path}[#{index}].#{field}", field_value)
        end.compact

        fields.presence
      end.presence
    end
end
