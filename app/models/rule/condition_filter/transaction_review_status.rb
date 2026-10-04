class Rule::ConditionFilter::TransactionReviewStatus < Rule::ConditionFilter
  def label
    I18n.t("rules.condition_filters.transaction_review_status.label")
  end

  def type
    "select"
  end

  def options
    [
      [ I18n.t("rules.condition_filters.transaction_review_status.reviewed"), "reviewed" ],
      [ I18n.t("rules.condition_filters.transaction_review_status.unreviewed"), "unreviewed" ]
    ]
  end

  def operators
    [ [ I18n.t("rules.condition_filters.transaction_review_status.equal_to"), "=" ] ]
  end

  def apply(scope, operator, value)
    # A value that isn't a review state matches nothing rather than everything,
    # so a corrupt condition can't widen what a rule's actions touch.
    return scope.none unless Transaction::REVIEW_STATUSES.include?(value)

    scope.with_review_state([ value ])
  end
end
