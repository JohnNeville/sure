# Local repair. This fork's database recorded versions 20261003120000 and 20261008120000
# for its own Cardog and closed-account migrations, which upstream later reused for the
# migrations below, so Rails treats upstream's as already run and skips them. Adds each
# column when it is missing; does nothing on a database that already has them.
class RepairColumnsSkippedByReusedMigrationVersions < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:families, :investment_contributions_as_spending)
      add_column :families, :investment_contributions_as_spending, :boolean, default: true, null: false
    end

    if table_exists?(:trade_republic_items) && !column_exists?(:trade_republic_items, :timeline_cursors)
      add_column :trade_republic_items, :timeline_cursors, :jsonb, default: {}, null: false
    end
  end
end
