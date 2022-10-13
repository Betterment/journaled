require 'rails_helper'

RSpec.describe Journaled::AuditLog do
  let(:auditable_model) do
    Class.new do
      extend ActiveModel::Callbacks
      define_model_callbacks :create, :update, :destroy, only: %i(after)

      include Journaled::AuditLog

      def self.table_name
        'objects'
      end

      def id
        'random-id'
      end

      def created_at
        'very-recently'
      end

      def updated_at
        'close-to-now'
      end

      def attributes
        { all: 'attributes', password: true }
      end

      if Rails::VERSION::MAJOR >= 7
        def encrypted_attribute?(_key)
          false
        end
      end
    end
  end

  before do
    stub_const('MyModel', auditable_model)
  end

  around do |example|
    Journaled.tagged(request_id: 123) do
      example.run
    end
  end

  describe '.default_ignored_columns' do
    it 'defaults to timestamps, but is configurable' do
      expect(described_class.default_ignored_columns).to eq %i(created_at updated_at)
      described_class.default_ignored_columns = []
      expect(described_class.default_ignored_columns).to eq []
    ensure
      described_class.default_ignored_columns = %i(created_at updated_at)
    end
  end

  describe '.default_stream_name' do
    it 'defaults to primary default, but is configurable' do
      expect(described_class.default_stream_name).to be_nil
      described_class.default_stream_name = 'dont_cross_the_streams'
      expect(described_class.default_stream_name).to eq 'dont_cross_the_streams'
    ensure
      described_class.default_stream_name = nil
    end
  end

  describe '.default_enqueue_opts' do
    it 'defaults to timestamps, but is configurable' do
      expect(described_class.default_enqueue_opts).to eq({})
      described_class.default_enqueue_opts = { priority: 99 }
      expect(described_class.default_enqueue_opts).to eq(priority: 99)
    ensure
      described_class.default_enqueue_opts = {}
    end
  end

  describe '.excluded_classes' do
    let(:defaults) do
      %w(
        Delayed::Job
        PaperTrail::Version
        ActiveStorage::Attachment
        ActiveStorage::Blob
        ActiveRecord::InternalMetadata
        ActiveRecord::SchemaMigration
      )
    end

    it 'defaults to DJ and papertrail, but is configurable, and will disable audit logging' do
      expect(described_class.excluded_classes).to eq defaults
      described_class.excluded_classes += %w(MyModel)
      expect(described_class.excluded_classes).to eq defaults + %w(MyModel)
    ensure
      described_class.excluded_classes = defaults
    end
  end

  describe '.has_audit_log, .skip_audit_log' do
    around do |example|
      described_class.default_ignored_columns = %i(DEFAULTS)
      example.run
    ensure
      described_class.default_ignored_columns = %i(created_at updated_at)
    end

    subject { MyModel }

    it 'enables/disables audit logging' do
      expect(subject.audit_log_config.enabled?).to be(false)
      expect(subject.audit_log_config.ignored_columns).to eq(%i(DEFAULTS))
      expect(subject.audit_log_config.enqueue_opts).to eq({})
      subject.has_audit_log
      expect(subject.audit_log_config.enabled?).to be(true)
      expect(subject.audit_log_config.ignored_columns).to eq(%i(DEFAULTS))
      expect(subject.audit_log_config.enqueue_opts).to eq({})
      subject.has_audit_log ignore: %i(foo bar baz), enqueue_with: { priority: 30 }
      expect(subject.audit_log_config.enabled?).to be(true)
      expect(subject.audit_log_config.ignored_columns).to eq(%i(DEFAULTS foo bar baz))
      expect(subject.audit_log_config.enqueue_opts).to eq(priority: 30)
      subject.skip_audit_log
      expect(subject.audit_log_config.enabled?).to be(false)
      expect(subject.audit_log_config.ignored_columns).to eq(%i(DEFAULTS foo bar baz))
      expect(subject.audit_log_config.enqueue_opts).to eq(priority: 30)
    end

    it 'can be composed with multiple calls' do
      subject.has_audit_log ignore: %i(foo)
      subject.has_audit_log ignore: %i(bar)
      expect(subject.audit_log_config.ignored_columns).to eq(%i(DEFAULTS foo bar))
    end

    it 'deduplicates identical fields' do
      subject.has_audit_log ignore: %i(foo)
      subject.has_audit_log ignore: %i(DEFAULTS foo)
      expect(subject.audit_log_config.ignored_columns).to eq(%i(DEFAULTS foo))
    end

    it 'accepts a single name (instead of an array)' do
      subject.has_audit_log ignore: :bar
      expect(subject.audit_log_config.ignored_columns).to eq(%i(DEFAULTS bar))
    end

    context 'with a subclass' do
      let(:auditable_subclass) do
        Class.new(subject) { include Journaled::AuditLog }
      end

      before do
        stub_const('MySubclass', auditable_subclass)
      end

      it 'inherits the config by default, and merges ignored columns' do
        expect(MySubclass.audit_log_config.enabled?).to be(false)
        expect(MySubclass.audit_log_config.ignored_columns).to eq(%i(DEFAULTS))
        expect(MySubclass.audit_log_config.enqueue_opts).to eq({})
        subject.has_audit_log ignore: %i(foo), enqueue_with: { priority: 10 }
        expect(MySubclass.audit_log_config.enabled?).to be(true)
        expect(MySubclass.audit_log_config.ignored_columns).to eq(%i(DEFAULTS foo))
        expect(MySubclass.audit_log_config.enqueue_opts).to eq(priority: 10)
        MySubclass.has_audit_log ignore: :bar, enqueue_with: { priority: 30 }
        expect(MySubclass.audit_log_config.enabled?).to be(true)
        expect(subject.audit_log_config.ignored_columns).to eq(%i(DEFAULTS foo))
        expect(subject.audit_log_config.enqueue_opts).to eq(priority: 10)
        expect(MySubclass.audit_log_config.ignored_columns).to eq(%i(DEFAULTS foo bar))
        expect(MySubclass.audit_log_config.enqueue_opts).to eq(priority: 30)
      end

      it 'allows the subclass to skip audit logging, and vice versa' do
        subject.has_audit_log ignore: %i(foo)
        MySubclass.skip_audit_log
        expect(subject.audit_log_config.enabled?).to be(true)
        expect(subject.audit_log_config.ignored_columns).to eq(%i(DEFAULTS foo))
        expect(MySubclass.audit_log_config.enabled?).to be(false)
        expect(MySubclass.audit_log_config.ignored_columns).to eq(%i(DEFAULTS foo))
        subject.skip_audit_log
        MySubclass.has_audit_log ignore: %i(foo)
        expect(subject.audit_log_config.enabled?).to be(false)
        expect(subject.audit_log_config.ignored_columns).to eq(%i(DEFAULTS foo))
        expect(MySubclass.audit_log_config.enabled?).to be(true)
        expect(MySubclass.audit_log_config.ignored_columns).to eq(%i(DEFAULTS foo))
      end

      it 'does not apply to subclasses that are in the exclusion list' do
        excluded_classes_was = described_class.excluded_classes.dup
        described_class.excluded_classes << 'MySubclass'
        described_class.exclude_classes! # typically run via an initializer

        subject.has_audit_log
        expect(subject.audit_log_config.enabled?).to be(true)
        expect(MySubclass.audit_log_config.enabled?).to be(false)
      ensure
        described_class.excluded_classes = excluded_classes_was
      end
    end
  end

  describe '#save, #update, #destroy' do
    let(:attributes) { %i(name email_addr json synced_at) }

    before do
      attrs = attributes
      auditable_model.class_eval do
        include ActiveModel::Dirty

        attr_reader(*attrs)

        define_attribute_methods(*attrs)

        attrs.each do |attr|
          define_method("#{attr}=") do |val|
            send("#{attr}_will_change!") unless val == send(attr)
            instance_variable_set("@#{attr}", val)
          end
        end

        def initialize(**attrs)
          assign_attrs(**attrs)
        end

        def save
          run_callbacks(:create) { changes_applied } # always a 'create' action, for simplicity
        end

        def update(**attrs)
          run_callbacks(:update) { assign_attrs(**attrs) && changes_applied }
        end

        def destroy
          run_callbacks(:destroy) { changes_applied }
        end

        def assign_attrs(**attrs)
          attrs.each { |attr, value| send("#{attr}=", value) }
        end
      end
    end

    subject { MyModel.new(name: 'bob', email_addr: 'bob@example.org', json: { asdf: 123 }, synced_at: 'now') }

    it 'does not emit a journaled event (because audit logging is not enabled)' do
      expect { subject.save }
        .to not_journal_event_including(event_type: 'journaled_audit_log_event')
      expect { subject.update(name: 'robert') }
        .to not_journal_event_including(event_type: 'journaled_audit_log_event')
      expect { subject.destroy }
        .to not_journal_event_including(event_type: 'journaled_audit_log_event')
    end

    context 'when audit logging is enabled' do
      around { |example| freeze_time { example.run } }
      before { auditable_model.class_eval { has_audit_log } }

      it 'emits events through the lifecycle of an object' do
        expect { subject.save }.to journal_event_including(
          event_type: 'journaled_audit_log_event',
          created_at: 'very-recently',
          class_name: 'MyModel',
          table_name: 'objects',
          record_id: 'random-id',
          database_operation: 'insert',
          changes: {
            name: [nil, 'bob'],
            email_addr: [nil, 'bob@example.org'],
            json: [nil, { asdf: 123 }],
            synced_at: [nil, 'now'],
          },
          snapshot: {},
          actor: 'gid://dummy',
          tags: { request_id: 123 },
        )
        expect { subject.update(name: 'robert') }.to journal_event_including(
          event_type: 'journaled_audit_log_event',
          created_at: 'close-to-now',
          database_operation: 'update',
          changes: { name: %w(bob robert) },
          snapshot: {},
        )
        expect { subject.update(name: 'robert') }
          .to not_journal_event_including(event_type: 'journaled_audit_log_event')
        expect { subject.destroy }.to journal_event_including(
          event_type: 'journaled_audit_log_event',
          created_at: Time.current,
          database_operation: 'delete',
          changes: {},
          snapshot: {},
        )
      end

      context 'when audit logging is disabled globally' do
        around do |example|
          described_class.without_audit_logging do
            example.run
          end
        end

        it 'does not emit a journaled event' do
          expect(subject.audit_log_config).not_to be_enabled
          expect { subject.save }
            .to not_journal_event_including(event_type: 'journaled_audit_log_event')
          expect { subject.update(name: 'robert') }
            .to not_journal_event_including(event_type: 'journaled_audit_log_event')
          expect { subject.destroy }
            .to not_journal_event_including(event_type: 'journaled_audit_log_event')
        end
      end

      context 'and a field is in the filter_paramters config' do
        around do |example|
          Rails.application.config.filter_parameters << :name
          example.run
        ensure
          Rails.application.config.filter_parameters = Rails.application.config.filter_parameters - [:name]
        end

        subject { MyModel.new(name: 'homer') }

        it 'filters that field through the lifecycle of the model' do
          expect { subject.save }
            .to journal_event_including(changes: { name: [nil, '[FILTERED]'] })
          expect { subject.update(name: 'bart') }
            .to journal_event_including(changes: { name: ['[FILTERED]', '[FILTERED]'] })
          expect { subject.update(name: 'bart') }
            .to not_journal_event_including(event_type: 'journaled_audit_log_event')
          expect { subject.destroy }.to journal_event_including(changes: {})
        end
      end

      context 'and fields end with _crypt or _hmac' do
        let(:attributes) { super() + %i(favorite_color_crypt favorite_color_hmac) }

        subject { MyModel.new(name: 'homer', favorite_color_crypt: '123', favorite_color_hmac: '456') }

        it 'filters those fields through the lifecycle of the model' do
          expect { subject.save }.to journal_event_including(
            changes: {
              name: [nil, 'homer'],
              favorite_color_crypt: [nil, '[FILTERED]'],
              favorite_color_hmac: [nil, '[FILTERED]'],
            },
          )
          expect { subject.update(name: 'bart', favorite_color_crypt: '789', favorite_color_hmac: '789') }
            .to journal_event_including(
              changes: {
                name: %w(homer bart),
                favorite_color_crypt: ['[FILTERED]', '[FILTERED]'],
                favorite_color_hmac: ['[FILTERED]', '[FILTERED]'],
              },
            )
          expect { subject.update(name: 'bart', favorite_color_crypt: '789', favorite_color_hmac: '789') }
            .to not_journal_event_including(event_type: 'journaled_audit_log_event')
          expect { subject.destroy }.to journal_event_including(changes: {})
        end
      end

      context 'and snapshotting is enabled via the attribute' do
        subject { MyModel.new(name: 'bob', _log_snapshot: true) }

        it 'emits snapshots when `:_log_snapshot` is `true`, and filters the expected fields' do
          expect { subject.save }
            .to journal_event_including(snapshot: { all: 'attributes', password: '[FILTERED]' })
          expect { subject.update(name: 'robert') }
            .to journal_event_including(snapshot: { all: 'attributes', password: '[FILTERED]' })
          subject._log_snapshot = false
          expect { subject.update(name: 'bob') }
            .to not_journal_event_including(snapshot: { all: 'attributes', password: '[FILTERED]' })
          subject._log_snapshot = true
          expect { subject.destroy }
            .to journal_event_including(snapshot: { all: 'attributes', password: '[FILTERED]' })
        end
      end

      context 'and snapshotting is enabled globally' do
        subject { MyModel.new(name: 'bob') }

        it 'emits snapshots through the lifecycle of the object, and filters the expected fields' do
          described_class.with_snapshots do
            expect { subject.save }
              .to journal_event_including(snapshot: { all: 'attributes', password: '[FILTERED]' })
            expect { subject.update(name: 'robert') }
              .to journal_event_including(snapshot: { all: 'attributes', password: '[FILTERED]' })
          end
          expect { subject.update(name: 'bob') }
            .to not_journal_event_including(snapshot: { all: 'attributes', password: '[FILTERED]' })
          described_class.with_snapshots do
            expect { subject.destroy }
              .to journal_event_including(snapshot: { all: 'attributes', password: '[FILTERED]' })
          end
        end
      end

      context 'and snapshotting is enabled only on deletion' do
        subject { MyModel.new(name: 'bob') }

        before do
          described_class.snapshot_on_deletion = true
        end

        it 'emits snapshots through the lifecycle of the object, and filters the expected fields' do
          expect { subject.save }
            .to not_journal_event_including(snapshot: { all: 'attributes', password: '[FILTERED]' })
          expect { subject.update(name: 'robert') }
            .to not_journal_event_including(snapshot: { all: 'attributes', password: '[FILTERED]' })
          expect { subject.destroy }
            .to journal_event_including(snapshot: { all: 'attributes', password: '[FILTERED]' })
        end
      end
    end

    context 'and a field is ignored' do
      before { auditable_model.class_eval { has_audit_log ignore: :synced_at } }

      subject { MyModel.new(name: 'bob', synced_at: 'earlier') }

      it 'excludes that field and does not emit events when the field changes' do
        expect { subject.save }
          .to journal_event_including(changes: { name: [nil, 'bob'] })
          .and not_journal_event_including(changes: { synced_at: [nil, 'earlier'] })
        expect { subject.update(synced_at: 'now') }
          .to not_journal_event_including(event_type: 'journaled_audit_log_event')
        expect { subject.destroy }.to journal_event_including(
          event_type: 'journaled_audit_log_event',
          database_operation: 'delete',
          changes: {},
        )
      end
    end

    context 'with a real ActiveRecord model' do
      let(:journaled_class) do
        Class.new(ActiveRecord::Base) do
          has_audit_log

          self.table_name = 'widgets'
        end
      end

      before do
        stub_const('Widget', journaled_class)
      end

      subject do
        Widget.new(name: 'test')
      end

      around { |example| freeze_time { example.run } }

      it 'is audited and supports snapshots' do
        expect { subject.save! }.to journal_event_including(
          event_type: 'journaled_audit_log_event',
          table_name: 'widgets',
          class_name: 'Widget',
          database_operation: 'insert',
          changes: {
            name: [nil, 'test'],
          },
          snapshot: {},
        ).and not_journal_event_including(changes: { created_at: [nil, Time.zone.now] })
          .and emit_notification('journaled.event.stage')
          .and emit_notification('journaled.batch.enqueue')
          .and emit_notification('journaled.audit_log.journal')
        expect { subject.save! }.to not_journal_event_including(
          event_type: 'journaled_audit_log_event',
          table_name: 'widgets',
        )
        expect { subject.update!(name: 'not_test', _log_snapshot: true) }.to journal_event_including(
          event_type: 'journaled_audit_log_event',
          table_name: 'widgets',
          database_operation: 'update',
          changes: {
            name: %w(test not_test),
          },
          snapshot: {
            name: 'not_test',
          },
        )
          .and emit_notification('journaled.audit_log.journal')

        # rubocop:disable Rails/SkipsModelValidations
        expect { subject.update_column(:name, 'banana') }
          .to raise_error(/skips audit logging/)
        expect { subject.update_column(:name, 'elephant', _force: true) }
          .not_to raise_error
        expect { subject.update_column(:name, 'other') }
          .to raise_error(/skips audit logging/)
        # rubocop:enable Rails/SkipsModelValidations

        expect { subject.destroy }.to journal_event_including(
          event_type: 'journaled_audit_log_event',
          table_name: 'widgets',
          class_name: 'Widget',
          database_operation: 'delete',
          changes: {},
          snapshot: {},
        )
          .and emit_notification('journaled.audit_log.journal')
      end
    end
  end

  # rubocop:disable Rails/SkipsModelValidations
  describe '#delete, #update_column, #update_columns' do
    before do
      auditable_model.class_eval do
        def delete(*); end
        def update_column(*); end
        def update_columns(*); end
      end
    end

    subject { MyModel.new }

    it 'does not block calls (because audit logging is disabled)' do
      expect { subject.delete }.to not_raise_error
      expect { subject.update_column(:foo, 'bar') }.to not_raise_error
      expect { subject.update_columns(foo: 'bar') }.to not_raise_error
    end

    context 'when audit logging is enabled' do
      before { auditable_model.class_eval { has_audit_log } }

      it 'blocks the action' do
        expect { subject.delete }.to raise_error(<<~MSG)
          Using `delete` is blocked because it skips audit logging (and other Rails callbacks)!
          Consider using `#destroy` instead, or pass `_force: true` as an argument.
        MSG
        expect { subject.update_column(:foo, 'bar') }.to raise_error(<<~MSG)
          You are attempting to change the following audited columns:
            [:foo]

          Using `update_column` is blocked because it skips audit logging (and other Rails callbacks)!
          Consider using `#update!` instead, or pass `_force: true` as an argument.
        MSG
        expect { subject.update_columns(foo: 'bar') }.to raise_error(<<~MSG)
          You are attempting to change the following audited columns:
            [:foo]

          Using `update_columns` is blocked because it skips audit logging (and other Rails callbacks)!
          Consider using `#update!` instead, or pass `_force: true` as an argument.
        MSG
      end

      it 'does not block the action if _force: true is passed' do
        expect { subject.delete(_force: true) }.to not_raise_error
        expect { subject.update_column(:foo, 'bar', _force: true) }.to not_raise_error
        expect { subject.update_columns(foo: 'bar', _force: true) }.to not_raise_error
      end
    end
  end

  describe '.delete_all, .insert, .insert_all, .update_all, .upsert, .upsert_all' do
    subject { MyModel }

    before do
      auditable_model.class_eval do
        def self.delete_all(*); end
        def self.insert(*); end
        def self.insert_all(*); end
        def self.update_all(*); end
        def self.upsert(*); end
        def self.upsert_all(*); end
      end
    end

    it 'does not block calls (because audit logging is disabled)' do
      expect { subject.delete_all }.to not_raise_error
      expect { subject.insert(foo: 'bar') }.to not_raise_error
      expect { subject.insert_all([{ foo: 'bar' }]) }.to not_raise_error
      expect { subject.update_all([{ foo: 'bar' }]) }.to not_raise_error
      expect { subject.upsert(foo: 'bar') }.to not_raise_error
      expect { subject.upsert_all([{ foo: 'bar' }]) }.to not_raise_error
    end

    context 'when audit logging is enabled' do
      before { auditable_model.class_eval { has_audit_log } }

      it 'blocks the action' do
        expect { subject.delete_all }.to raise_error(<<~MSG)
          `delete_all` is blocked because it skips callbacks and audit logs!
          Consider using `.destroy_all` instead, or pass `_force: true` as an argument.
        MSG
        expect { subject.insert(foo: 'bar') }.to raise_error(<<~MSG)
          `insert` is blocked because it skips callbacks and audit logs!
          Consider using `.create!` instead, or pass `_force: true` as an argument.
        MSG
        expect { subject.insert_all([{ foo: 'bar' }]) }.to raise_error(<<~MSG)
          `insert_all` is blocked because it skips callbacks and audit logs!
          Consider using `.each { create!(...) }` instead, or pass `_force: true` as an argument.
        MSG
        expect { subject.update_all([{ foo: 'bar' }]) }.to raise_error(<<~MSG)
          `update_all` is blocked because it skips callbacks and audit logs!
          Consider using `.find_each { update!(...) }` instead, or pass `_force: true` as an argument.
        MSG
        expect { subject.upsert(foo: 'bar') }.to raise_error(<<~MSG)
          `upsert` is blocked because it skips callbacks and audit logs!
          Consider using `.create_or_find_by!` instead, or pass `_force: true` as an argument.
        MSG
        expect { subject.upsert_all([{ foo: 'bar' }]) }.to raise_error(<<~MSG)
          `upsert_all` is blocked because it skips callbacks and audit logs!
          Consider using `.each { create_or_find_by!(...) }` instead, or pass `_force: true` as an argument.
        MSG
      end

      it 'does not block the action when _force: true is passed' do
        expect { subject.delete_all(_force: true) }.to not_raise_error
        expect { subject.insert(foo: 'bar', _force: true) }.to not_raise_error
        expect { subject.insert_all([{ foo: 'bar' }], _force: true) }.to not_raise_error
        expect { subject.update_all([{ foo: 'bar' }], _force: true) }.to not_raise_error
        expect { subject.upsert(foo: 'bar', _force: true) }.to not_raise_error
        expect { subject.upsert_all([{ foo: 'bar' }], _force: true) }.to not_raise_error
      end
    end
  end
  # rubocop:enable Rails/SkipsModelValidations
end
