class AddSoldierTable < ActiveRecord::Migration[5.2]
  def change
    create_table :soldiers do |t|
      t.string :name
      t.string :rank
      t.string :serial_number
      t.datetime :last_sign_in_at
    end
  end
end
