# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# Note that this schema.rb definition is the authoritative source for your
# database schema. If you need to create the application database on another
# system, you should be using db:schema:load, not running all the migrations
# from scratch. The latter is a flawed and unsustainable approach (the more migrations
# you'll amass, the slower it'll run and the greater likelihood for issues).
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema.define(version: 20180606205114) do
  # Enable pgcrypto extension and uuid_generate_v7 function for PostgreSQL only
  if ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
    enable_extension 'pgcrypto'

    execute <<-SQL
      CREATE OR REPLACE FUNCTION uuid_generate_v7()
      RETURNS uuid
      LANGUAGE plpgsql
      PARALLEL SAFE
      AS $$
      DECLARE
        unix_time_ms CONSTANT bytea NOT NULL DEFAULT substring(int8send((extract(epoch FROM clock_timestamp()) * 1000)::bigint) from 3);
        buffer bytea NOT NULL DEFAULT unix_time_ms || gen_random_bytes(10);
      BEGIN
        buffer = set_byte(buffer, 6, (b'0111' || get_byte(buffer, 6)::bit(4))::bit(8)::int);
        buffer = set_byte(buffer, 8, (b'10' || get_byte(buffer, 8)::bit(6))::bit(8)::int);
        RETURN encode(buffer, 'hex');
      END
      $$;
    SQL
  end

  create_table "widgets", force: :cascade do |t|
    t.string "name"
    t.string "other_column"
  end

  # Use uuid_generate_v7() for PostgreSQL, nil for SQLite (outbox tests require PostgreSQL)
  id_default = if ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
    -> { "uuid_generate_v7()" }
  else
    nil
  end

  create_table "journaled_outbox_events", id: :uuid, default: id_default, force: :cascade do |t|
    t.string "event_type", null: false
    t.text "event_data", null: false
    t.string "partition_key", null: false
    t.string "stream_name", null: false
    t.text "failure_reason"
    t.datetime "failed_at"
    t.datetime "created_at", null: false, default: -> { "clock_timestamp()" }
    t.index ["failed_at"], name: "index_journaled_outbox_events_on_failed_at"
  end
end
