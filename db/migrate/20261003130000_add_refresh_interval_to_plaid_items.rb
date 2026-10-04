class AddRefreshIntervalToPlaidItems < ActiveRecord::Migration[8.1]
  def change
    # The default keeps existing items refreshing on every sync, exactly as
    # before. Both columns are cheap to add to a populated table.
    add_column :plaid_items, :refresh_interval, :string, default: "always", null: false
    add_column :plaid_items, :last_refresh_requested_at, :datetime
  end
end
