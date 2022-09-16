# FIXME: This cannot be included in lib/ because Journaled::Event is autoloaded via app/models
#        Autoloading Journaled::Event isn't strictly necessary, and for compatibility it would
#        make sense to move it to lib/.
module Journaled
  module AuditLog
    Event = Struct.new(:record, :database_operation, :unfiltered_changes, :enqueue_opts) do
      include Journaled::Event

      journal_attributes :class_name, :table_name, :record_id,
                         :database_operation, :changes, :snapshot, :actor, tagged: true

      def journaled_stream_name
        AuditLog.default_stream_name || super
      end

      def journaled_enqueue_opts
        record.class.audit_log_config.enqueue_opts
      end

      def created_at
        case database_operation
          when 'insert'
            record_created_at
          when 'update'
            record_updated_at
          when 'delete'
            Time.zone.now
          else
            raise "Unhandled database operation type: #{database_operation}"
        end
      end

      def record_created_at
        record.try(:created_at) || Time.zone.now
      end

      def record_updated_at
        record.try(:updated_at) || Time.zone.now
      end

      def class_name
        record.class.name
      end

      def table_name
        record.class.table_name
      end

      def record_id
        record.id
      end

      def changes
        filtered_changes = unfiltered_changes.deep_dup.deep_symbolize_keys
        filtered_changes.each do |key, value|
          filtered_changes[key] = value.map { |val| '[FILTERED]' if val } if filter_key?(key)
        end
      end

      def snapshot
        filtered_attributes if record._log_snapshot || AuditLog.snapshots_enabled
      end

      def actor
        Journaled.actor_uri
      end

      private

      def filter_key?(key)
        filter_params.include?(key) || encrypted_column?(key)
      end

      def encrypted_column?(key)
        key.to_s.end_with?('_crypt', '_hmac') ||
          (Rails::VERSION::MAJOR >= 7 && record.encrypted_attribute?(key))
      end

      def filter_params
        Rails.application.config.filter_parameters
      end

      def filtered_attributes
        attrs = record.attributes.dup.symbolize_keys
        attrs.each do |key, _value|
          attrs[key] = '[FILTERED]' if filter_key?(key)
        end
      end
    end
  end
end
