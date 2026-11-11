class Rule::ConditionFilter::TransactionExcluded < Rule::ConditionFilter
  def label
    I18n.t("rules.condition_filters.transaction_excluded.label")
  end

  def type
    "select"
  end

  def options
    [
      [ I18n.t("rules.condition_filters.transaction_excluded.yes"), "true" ],
      [ I18n.t("rules.condition_filters.transaction_excluded.no"), "false" ]
    ]
  end

  def operators
    [ [ I18n.t("rules.condition_filters.transaction_excluded.equal_to"), "=" ] ]
  end

  def prepare(scope)
    scope.with_entry
  end

  def apply(scope, operator, value)
    # A value that isn't yes or no matches nothing rather than everything, so
    # a corrupt condition can't widen what a rule's actions touch.
    return scope.none unless %w[true false].include?(value)

    scope.where(entries: { excluded: value == "true" })
  end
end
