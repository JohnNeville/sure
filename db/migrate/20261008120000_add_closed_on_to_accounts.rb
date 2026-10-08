# frozen_string_literal: true

class AddClosedOnToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :closed_on, :date
  end
end
