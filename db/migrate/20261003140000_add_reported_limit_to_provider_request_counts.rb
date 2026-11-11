class AddReportedLimitToProviderRequestCounts < ActiveRecord::Migration[8.1]
  def change
    # The monthly allowance a provider reports about itself (e.g. Cardog's
    # X-Credits-Allowance header), so paid plans don't need a manual cap.
    add_column :provider_request_counts, :reported_limit, :integer
  end
end
