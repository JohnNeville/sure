# The counterpart of ExcludeTransaction: puts excluded transactions back into
# budgeting and reports. Beware that transactions converted to a trade are
# excluded on purpose, so the original and the trade don't count twice. A rule
# that matches them will include them again, so keep such rules off investment
# accounts.
class Rule::ActionExecutor::IncludeTransaction < Rule::ActionExecutor
  def label
    I18n.t("rules.action_executors.include_transaction.label")
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    scope = transaction_scope.with_entry.where(entries: { excluded: true })

    unless ignore_attribute_locks
      # A user's own choice (a manual edit or bulk edit locks `excluded` on the
      # entry) is left alone, exactly as ExcludeTransaction leaves it alone.
      scope = scope.where.not(Arel.sql("entries.locked_attributes ? 'excluded'"))
    end

    count_modified_resources(scope) do |txn|
      txn.entry.enrich_attribute(
        :excluded,
        false,
        source: "rule",
        ignore_locks: ignore_attribute_locks
      )
    end
  end
end
