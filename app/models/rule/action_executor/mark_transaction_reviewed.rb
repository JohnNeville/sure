class Rule::ActionExecutor::MarkTransactionReviewed < Rule::ActionExecutor
  def label
    I18n.t("rules.action_executors.mark_transaction_reviewed.label")
  end

  # Reviewed state isn't an enrichable attribute that a user edit locks, so
  # attribute locks don't apply. Only unreviewed transactions count as modified.
  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    transaction_ids = transaction_scope.unreviewed.pluck(:id)
    return 0 if transaction_ids.empty?

    now = Time.current
    Transaction.where(id: transaction_ids).update_all(reviewed_at: now)
    # Touch the entries so caches keyed on them, such as search totals, refresh.
    Entry.where(entryable_type: "Transaction", entryable_id: transaction_ids).update_all(updated_at: now)

    transaction_ids.size
  end
end
