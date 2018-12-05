class AddFeeCurrencyToOrders < ActiveRecord::Migration
  def change
    add_column :orders, :fee_currency_id, :string
    add_index :orders, :fee_currency_id
  end
end
