# frozen_string_literal: true

# Renumbered from 20261008120000, which upstream later used for its own migration.
# Guarded so a database that already ran it under the old number is left alone.
class AddClosedOnToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :closed_on, :date unless column_exists?(:accounts, :closed_on)
  end
end
