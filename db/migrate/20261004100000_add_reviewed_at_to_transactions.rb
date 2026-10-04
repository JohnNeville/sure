class AddReviewedAtToTransactions < ActiveRecord::Migration[8.1]
  def change
    add_column :transactions, :reviewed_at, :datetime

    # Transactions that already exist are treated as reviewed, so only ones
    # that arrive after this ships show up as needing review.
    up_only { execute "UPDATE transactions SET reviewed_at = created_at" }

    # The unreviewed set is the small, interesting one.
    add_index :transactions, :reviewed_at, where: "reviewed_at IS NULL", name: "index_transactions_on_unreviewed"
  end
end
