require 'active_support/core_ext/module/attribute_accessors_per_thread'

module Journaled
  module AuditLog
    extend ActiveSupport::Concern

    DEFAULT_EXCLUDED_CLASSES = %w(
      Delayed::Job
      PaperTrail::Version
      ActiveStorage::Attachment
      ActiveStorage::Blob
      ActiveRecord::InternalMetadata
      ActiveRecord::SchemaMigration
    ).freeze

    mattr_accessor(:default_ignored_columns) { %i(created_at updated_at) }
    mattr_accessor(:default_stream_name) { Journaled.default_stream_name }
    mattr_accessor(:excluded_classes) { DEFAULT_EXCLUDED_CLASSES.dup }
    thread_mattr_accessor(:snapshots_enabled) { false }
    thread_mattr_accessor(:_disabled) { false }
    thread_mattr_accessor(:_force) { false }

    class << self
      def exclude_classes!
        excluded_classes.each do |name|
          if Rails::VERSION::MAJOR >= 6 && Rails.autoloaders.zeitwerk_enabled?
            zeitwerk_exclude!(name)
          else
            classic_exclude!(name)
          end
        end
      end

      def with_snapshots
        snapshots_enabled_was = snapshots_enabled
        self.snapshots_enabled = true
        yield
      ensure
        self.snapshots_enabled = snapshots_enabled_was
      end

      def without_audit_logging
        disabled_was = _disabled
        self._disabled = true
        yield
      ensure
        self._disabled = disabled_was
      end

      private

      def zeitwerk_exclude!(name)
        if Object.const_defined?(name)
          name.constantize.skip_audit_log
        else
          Rails.autoloaders.main.on_load(name) { |klass, _path| klass.skip_audit_log }
        end
      end

      def classic_exclude!(name)
        name.constantize.skip_audit_log
      rescue NameError
        nil
      end
    end

    Config = Struct.new(:enabled, :ignored_columns) do
      private :enabled
      def enabled?
        !AuditLog._disabled && self[:enabled].present?
      end
    end

    included do
      prepend BlockedMethods
      singleton_class.prepend BlockedClassMethods

      class_attribute :audit_log_config, default: Config.new(false, AuditLog.default_ignored_columns)
      attr_accessor :_log_snapshot

      after_create { _emit_audit_log!('insert') }
      after_update { _emit_audit_log!('update') if _audit_log_changes.any? }
      after_destroy { _emit_audit_log!('delete') }
    end

    class_methods do
      def has_audit_log(ignore: [])
        ignored_columns = _audit_log_inherited_ignored_columns + [ignore].flatten(1)
        self.audit_log_config = Config.new(true, ignored_columns.uniq)
      end

      def skip_audit_log
        self.audit_log_config = Config.new(false, _audit_log_inherited_ignored_columns.uniq)
      end

      private

      def _audit_log_inherited_ignored_columns
        (superclass.try(:audit_log_config)&.ignored_columns || []) + audit_log_config.ignored_columns
      end
    end

    module BlockedMethods
      BLOCKED_METHODS = {
        delete: '#destroy',
        update_column: '#update!',
        update_columns: '#update!',
      }.freeze

      def delete(**kwargs)
        _journaled_audit_log_check!(:delete, **kwargs) do
          super()
        end
      end

      def update_column(name, value, **kwargs)
        _journaled_audit_log_check!(:update_column, **kwargs.merge(name => value)) do
          super(name, value)
        end
      end

      def update_columns(**kwargs)
        _journaled_audit_log_check!(:update_columns, **kwargs) do
          super(**kwargs.except(:_force))
        end
      end

      def _journaled_audit_log_check!(method, **kwargs) # rubocop:disable Metrics/AbcSize
        force_was = AuditLog._force
        AuditLog._force = kwargs.delete(:_force) if kwargs.key?(:_force)
        audited_columns = kwargs.keys - audit_log_config.ignored_columns

        if method == :delete || audited_columns.any?
          column_message = <<~MSG if kwargs.any?
            You are attempting to change the following audited columns:
              #{audited_columns.inspect}

          MSG
          raise <<~MSG if audit_log_config.enabled? && !AuditLog._force
            #{column_message}Using `#{method}` is blocked because it skips audit logging (and other Rails callbacks)!
            Consider using `#{BLOCKED_METHODS[method]}` instead, or pass `_force: true` as an argument.
          MSG
        end

        yield
      ensure
        AuditLog._force = force_was
      end
    end

    module BlockedClassMethods
      BLOCKED_METHODS = {
        delete_all: '.destroy_all',
        insert: '.create!',
        insert_all: '.each { create!(...) }',
        update_all: '.find_each { update!(...) }',
        upsert: '.create_or_find_by!',
        upsert_all: '.each { create_or_find_by!(...) }',
      }.freeze

      BLOCKED_METHODS.each do |method, alternative|
        define_method(method) do |*args, **kwargs, &block|
          force_was = AuditLog._force
          AuditLog._force = kwargs.delete(:_force) if kwargs.key?(:_force)

          raise <<~MSG if audit_log_config.enabled? && !AuditLog._force
            `#{method}` is blocked because it skips callbacks and audit logs!
            Consider using `#{alternative}` instead, or pass `_force: true` as an argument.
          MSG

          super(*args, **kwargs, &block)
        ensure
          AuditLog._force = force_was
        end
      end
    end

    def _emit_audit_log!(database_operation)
      if audit_log_config.enabled?
        event = Journaled::AuditLog::Event.new(self, database_operation, _audit_log_changes)
        ActiveSupport::Notifications.instrument('journaled.audit_log.journal', event: event) do
          event.journal!
        end
      end
    end

    def _audit_log_changes
      previous_changes.except(*audit_log_config.ignored_columns)
    end
  end
end

ActiveSupport.on_load(:active_record) { include Journaled::AuditLog }
Journaled::Engine.config.after_initialize { Journaled::AuditLog.exclude_classes! }
