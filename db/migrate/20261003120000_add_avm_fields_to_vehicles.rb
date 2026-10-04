class AddAvmFieldsToVehicles < ActiveRecord::Migration[8.1]
  def change
    add_column :vehicles, :avm_provider, :string
    add_column :vehicles, :avm_last_synced_on, :date

    add_check_constraint :vehicles,
      "avm_provider IS NULL OR avm_provider IN ('cardog')",
      name: "vehicles_avm_provider_check"

    # Keyed on avm_last_synced_on to match the monthly job's
    # ORDER BY avm_last_synced_on ASC NULLS FIRST.
    add_index :vehicles, :avm_last_synced_on,
      order: { avm_last_synced_on: "ASC NULLS FIRST" },
      where: "avm_provider IS NOT NULL",
      name: "index_vehicles_on_avm_provider_sync"
  end
end
