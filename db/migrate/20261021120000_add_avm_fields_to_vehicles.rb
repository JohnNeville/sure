# Renumbered from 20261003120000, which upstream later used for its own migration.
# Guarded so a database that already ran it under the old number is left alone.
class AddAvmFieldsToVehicles < ActiveRecord::Migration[8.1]
  def change
    add_column :vehicles, :avm_provider, :string unless column_exists?(:vehicles, :avm_provider)
    add_column :vehicles, :avm_last_synced_on, :date unless column_exists?(:vehicles, :avm_last_synced_on)

    unless check_constraint_exists?(:vehicles, name: "vehicles_avm_provider_check")
      add_check_constraint :vehicles,
        "avm_provider IS NULL OR avm_provider IN ('cardog')",
        name: "vehicles_avm_provider_check"
    end

    # Keyed on avm_last_synced_on to match the monthly job's
    # ORDER BY avm_last_synced_on ASC NULLS FIRST.
    add_index :vehicles, :avm_last_synced_on,
      order: { avm_last_synced_on: "ASC NULLS FIRST" },
      where: "avm_provider IS NOT NULL",
      name: "index_vehicles_on_avm_provider_sync",
      if_not_exists: true
  end
end
