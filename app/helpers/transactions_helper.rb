module TransactionsHelper
  # @return [Array<Hash>] the filters offered above the transaction list, each
  #   with the key its partial is named for, a translated label and an icon
  def transaction_search_filters
    [
      { key: "account_filter", label: t("transactions.search.filters.account"), icon: "layers" },
      { key: "date_filter", label: t("transactions.search.filters.date"), icon: "calendar" },
      { key: "type_filter", label: t("transactions.search.filters.type"), icon: "tag" },
      { key: "status_filter", label: t("transactions.search.filters.status"), icon: "clock" },
      { key: "review_filter", label: t("transactions.search.filters.review"), icon: "circle-check" },
      { key: "exclusion_filter", label: t("transactions.search.filters.exclusion"), icon: "eye-off" },
      { key: "amount_filter", label: t("transactions.search.filters.amount"), icon: "hash" },
      { key: "category_filter", label: t("transactions.search.filters.category"), icon: "shapes" },
      { key: "tag_filter", label: t("transactions.search.filters.tag"), icon: "tags" },
      { key: "merchant_filter", label: t("transactions.search.filters.merchant"), icon: "store" },
      { key: "ai_filter", label: t("transactions.search.filters.ai"), icon: "sparkles" }
    ]
  end

  # Accounts for the account filter, grouped by primary type in the order Sure
  # lists account types everywhere else (cash, investments, ... then
  # liabilities). Types without an account are left out.
  #
  # @param accounts [Enumerable<Account>] the accounts the user can see
  # @return [Array<Array>] [type, plural display name, accounts] for each type present
  def grouped_filter_accounts(accounts)
    by_type = accounts.group_by(&:accountable_type)

    Accountable::TYPES.filter_map do |type|
      next unless by_type.key?(type)

      [ type, Accountable.from_type(type).display_name, by_type[type] ]
    end
  end

  # @param filter [Hash] one entry from transaction_search_filters
  # @return [String] the partial that renders that filter's controls
  def get_transaction_search_filter_partial_path(filter)
    "transactions/searches/filters/#{filter[:key]}"
  end

  # @return [Hash] the filter shown when the user has not picked one
  def get_default_transaction_search_filter
    transaction_search_filters[0]
  end

  # A split child is only folded under its parent when the user asked for
  # grouping and the current view is rendering grouped.
  #
  # @param entry [Entry] the entry being rendered
  # @param params_grouped [String, nil] the grouped param as it arrived
  # @return [Boolean] whether to render this entry inside its split group
  def in_split_group?(entry, params_grouped)
    entry.split_child? && Current.user.show_split_grouped? && params_grouped == "true"
  end

  # Whether the current user may annotate (e.g. re-tag) entries on this
  # account. Memoized per request so list rows don't query per row.
  def can_annotate_account?(account)
    return false unless Current.user

    @annotatable_account_ids ||= Account.annotatable_by(Current.user).pluck(:id).to_set
    @annotatable_account_ids.include?(account.id)
  end

  # ---- Transaction extra details helpers ----
  # Returns a structured hash describing extra details for a transaction.
  # Input can be a Transaction, a Trade or an Entry (its transaction is used).
  # Structure:
  #   {
  #     kind: :simplefin | :plaid | :raw,
  #     simplefin: { payee:, description:, memo: },
  #     plaid: { original_description:, payment_channel:, transaction_code: },
  #     provider_extras: [ { key:, value:, multiline: } ],
  #       multiline marks values the view should render in a <pre> block
  #       rather than inline opposite their label.
  #     raw: String (pretty JSON) — only set for :raw, where we have no
  #       structured rendering for the provider
  #   }
  def build_transaction_extra_details(obj, raw_fallback: true)
    # An Entry holds its Transaction. Anything else (a Transaction, a Trade) is used
    # as is: every ActiveRecord model responds to #transaction, as the method that
    # opens a database transaction, so respond_to? cannot tell them apart.
    tx = obj.is_a?(Entry) ? obj.transaction : obj
    return nil unless tx.respond_to?(:extra) && tx.extra.present?

    extra = tx.extra
    unless extra.is_a?(Hash) &&
        (extra["simplefin"].present? || extra["plaid"].present? || extra["import"].present? || extra["retail"].present?)
      return raw_fallback ? transaction_extra_raw_details(extra) : nil
    end

    details = if extra["simplefin"].present?
      simplefin_extra_details(extra["simplefin"])
    elsif extra["plaid"].present?
      plaid_extra_details(extra["plaid"])
    end

    # A provider's own details come first, then whatever clients added under
    # import and retail.
    [ import_extra_details(extra["import"]), retail_extra_details(extra["retail"]) ].compact.reduce(details) do |combined, addition|
      combined.nil? ? addition : merge_extra_details(combined, addition)
    end
  end

  # Extra that no provider claims: show the payload as JSON.
  def transaction_extra_raw_details(extra)
    {
      kind: :raw,
      simplefin: {},
      plaid: {},
      import: {},
      provider_extras: [],
      raw: pretty_json(extra)
    }
  end

  def simplefin_extra_details(sf)
    simple = {
      payee: sf.is_a?(Hash) ? sf["payee"].presence : nil,
      description: sf.is_a?(Hash) ? sf["description"].presence : nil,
      memo: sf.is_a?(Hash) ? sf["memo"].presence : nil
    }.compact

    extras = []
    if sf.is_a?(Hash) && sf["extra"].is_a?(Hash) && sf["extra"].present?
      sf["extra"].each do |k, v|
        extras.concat(provider_extra_rows(provider_extra_field_label(k), v))
      end
    end

    # Same rule as the Plaid details. SimpleFIN always writes a pending flag, so
    # a transaction carrying nothing else would otherwise open an Additional
    # details section with no details in it.
    return nil if simple.blank? && extras.blank?

    {
      kind: :simplefin,
      simplefin: simple,
      plaid: {},
      import: {},
      provider_extras: extras,
      raw: nil
    }
  end

  def plaid_extra_details(plaid)
    simple = {
      original_description: plaid.is_a?(Hash) ? plaid["original_description"].presence : nil,
      payment_channel: plaid.is_a?(Hash) ? plaid["payment_channel"].presence : nil,
      transaction_code: plaid.is_a?(Hash) ? plaid["transaction_code"].presence : nil
    }.compact

    extras = []
    if plaid.is_a?(Hash)
      if plaid["payment_meta"].is_a?(Hash) && plaid["payment_meta"].present?
        plaid["payment_meta"].each do |k, v|
          extras.concat(provider_extra_rows(t("transactions.show.plaid_payment_meta_label", name: provider_extra_field_label(k)), v))
        end
      end

      if plaid["counterparties"].is_a?(Array) && plaid["counterparties"].present?
        plaid["counterparties"].each_with_index do |counterparty, index|
          extras.concat(provider_extra_rows(t("transactions.show.plaid_counterparty_label", index: index + 1), counterparty))
        end
      end
    end

    # Only show Additional details when there is something beyond pending flags
    return nil if simple.blank? && extras.blank?

    {
      kind: :plaid,
      simplefin: {},
      plaid: simple,
      import: {},
      provider_extras: extras,
      # No raw dump: the structured rows above already cover the payload, and
      # the only fields they omit (pending, pending_transaction_id) are what
      # the pending badge communicates.
      raw: nil
    }
  end

  # Details written through the API under extra["import"] (a history backfill, a
  # retailer integration). The bank's original description gets the named row a
  # provider's does; every other key becomes a labelled extras row, known keys
  # first in a fixed order.
  def import_extra_details(import)
    return nil unless import.is_a?(Hash) && import.present?

    known = Transaction::ClientExtra::KNOWN_KEYS.fetch("import")
    ordered = import.reject { |key, _| key == "original_description" }
      .sort_by { |key, _| [ known.index(key) || known.size, key ] }

    extras = ordered.flat_map do |key, value|
      label = t("transactions.show.import_field_labels.#{key}", default: provider_extra_field_label(key))
      provider_extra_rows(label, value)
    end
    simple = { original_description: import["original_description"].presence }.compact

    return nil if simple.blank? && extras.blank?

    {
      kind: :import,
      simplefin: {},
      plaid: {},
      import: simple,
      provider_extras: extras,
      raw: nil
    }
  end

  # Appends one client-written section to the details built so far. Both the
  # provider and an import can carry a bank-side "Original description"; the
  # first one keeps the named row and the other moves to the extras so neither
  # is lost.
  def merge_extra_details(base, addition)
    kind = base[:kind]
    named = base[kind] || {}
    extras = addition[:provider_extras].dup
    description = addition.dig(:import, :original_description)

    if description.present?
      if named[:original_description].present?
        extras.unshift(provider_extra_row(t("transactions.show.import_field_labels.original_description"), description))
      else
        named = { original_description: description }.merge(named)
      end
    end

    base.merge(kind => named, provider_extras: base[:provider_extras] + extras)
  end

  # An order pushed under extra["retail"] by a retailer integration: the order's
  # own fields as labelled rows (known keys first), then one row per item.
  def retail_extra_details(retail)
    return nil unless retail.is_a?(Hash) && retail.present?

    known = Transaction::ClientExtra::KNOWN_KEYS.fetch("retail")
    fields = retail.except("items")
      .sort_by { |key, _| [ known.index(key) || known.size, key ] }

    extras = fields.flat_map do |key, value|
      label = t("transactions.show.retail_field_labels.#{key}", default: provider_extra_field_label(key))
      provider_extra_rows(label, value)
    end

    Array(retail["items"]).each_with_index do |item, index|
      summary = retail_item_summary(item)
      extras << provider_extra_row(t("transactions.show.retail_item_label", index: index + 1), summary) if summary.present?
    end

    return nil if extras.blank?

    {
      kind: :retail,
      simplefin: {},
      plaid: {},
      import: {},
      provider_extras: extras,
      raw: nil
    }
  end

  # "Title × 2 · $11.50", falling back to whatever fields the item has.
  def retail_item_summary(item)
    return item.to_s.presence unless item.is_a?(Hash)

    title = item["title"].presence || item["name"].presence
    quantity = item["quantity"].presence
    price = (item["price"] || item["unit_price"]).presence
    detail = [ ("× #{quantity}" if quantity), price ].compact.join(" · ")
    text = [ title, detail.presence ].compact.join(" ")
    return text if text.present?

    item.except("title", "name", "quantity", "price", "unit_price").values.compact_blank.join(", ")
  end

  # Flatten hashes into labeled rows; pretty-print remaining nested structures.
  #
  # `key` arrives already presentable — localized by the caller, or run through
  # provider_extra_field_label here. Nothing downstream reformats it, because a
  # composed label is part translation and part provider identifier and
  # `humanize` would lowercase the translated half.
  #
  # An empty value yields no row. A row with nothing opposite its label is noise,
  # and it made the extras non-blank, which defeated the guard that keeps an
  # empty Additional details section closed.
  def provider_extra_rows(key, value, depth: 0)
    value = value.reject { |item| blank_provider_extra?(item) } if value.is_a?(Array)
    return [] if blank_provider_extra?(value)

    label = key.to_s

    case value
    when Hash
      value.flat_map do |child_key, child_value|
        child = provider_extra_field_label(child_key)
        child_label = depth.zero? ? "#{label} · #{child}" : "#{label}.#{child}"
        provider_extra_rows(child_label, child_value, depth: depth + 1)
      end
    when Array
      if value.all? { |item| !item.is_a?(Hash) && !item.is_a?(Array) }
        [ provider_extra_row(label, value.join(", ")) ]
      else
        # Pass the raw value — provider_extra_row does the single encode. Handing
        # it a pretty_json string here would re-encode it into an escaped one-liner.
        [ provider_extra_row(label, value, multiline: true) ]
      end
    else
      [ provider_extra_row(label, value) ]
    end
  end

  # Builds one row for the view. The key arrives already presentable and is not
  # reformatted here, since a composed label is part translation and part
  # provider identifier.
  #
  # @param key [String] the label to show
  # @param value [Object] the provider value
  # @param multiline [Boolean] render in a block rather than opposite the label
  # @return [Hash] a row of { key:, value:, multiline: }
  def provider_extra_row(key, value, multiline: false)
    display = if multiline || value.is_a?(Hash) || value.is_a?(Array)
      pretty_json(value)
    else
      value
    end

    {
      key: key.to_s,
      value: display,
      multiline: multiline || value.is_a?(Hash) || value.is_a?(Array)
    }
  end

  # Provider field names are schema identifiers (reference_number,
  # confidence_level), so they get a translation where we know the field and
  # `humanize` otherwise — the set is open-ended and a provider can add to it
  # without us, which is better served by a readable fallback than a missing key.
  #
  # The key becomes part of an i18n lookup, so a blank or dotted one would be read
  # as a scope rather than a field name: "" resolves to the whole
  # provider_extra_fields hash, which then rendered as the label. Those fall back
  # to the humanized key, as does any lookup that comes back as something other
  # than a string.
  def provider_extra_field_label(key)
    fallback = key.to_s.humanize
    return fallback if key.to_s.strip.empty? || key.to_s.include?(".")

    label = t("transactions.show.provider_extra_fields.#{key}", default: fallback)
    label.is_a?(String) ? label : fallback
  end

  # Nothing worth a row: nil, an empty or whitespace-only string, or an empty
  # collection. false and 0 are real values a provider meant to report, so they stay.
  #
  # @param value [Object] a provider value
  # @return [Boolean] whether the value has nothing to show
  def blank_provider_extra?(value)
    case value
    when nil then true
    when String then value.strip.empty?
    when Array, Hash then value.empty?
    else false
    end
  end

  # Provider payloads are arbitrary JSON, so anything that cannot be generated
  # falls back to its string form rather than raising in a view.
  #
  # @param value [Object] any provider value
  # @return [String] indented JSON, or the value's string form
  def pretty_json(value)
    JSON.pretty_generate(value)
  rescue StandardError
    value.to_s
  end
end
