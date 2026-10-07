# frozen_string_literal: true

json.parent do
  json.partial! "api/v1/transactions/transaction", transaction: @entry.transaction
end

json.children @entry.child_entries.includes(entryable: [ :category, :merchant, :tags ]).order(:created_at, :id) do |child|
  json.partial! "api/v1/transactions/transaction", transaction: child.transaction
end
