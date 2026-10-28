# Local repair. This fork's database once recorded version 20261003120000 for the
# Cardog vehicle migration, which upstream later reused for the migration that adds
# this column, so Rails treats upstream's as already run and skips it. Adds the
# column when it is missing; does nothing on a database that already has it.
class EnsureInvestmentContributionsAsSpendingOnFamilies < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:families, :investment_contributions_as_spending)

    add_column :families, :investment_contributions_as_spending, :boolean, default: true, null: false
  end
end
