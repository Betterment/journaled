require 'rails_helper'

RSpec.describe Journaled::Event do
  let(:sample_journaled_event_class_name) { 'SomeClassName' }
  let(:sample_journaled_event_class) do
    Class.new do
      include Journaled::Event
    end
  end

  before do
    stub_const(sample_journaled_event_class_name, sample_journaled_event_class)
  end

  let(:sample_journaled_event) { sample_journaled_event_class.new }

  describe '#journal!' do
    let(:mock_journaled_writer) { instance_double(Journaled::Writer, journal!: nil) }

    before do
      allow(Journaled::Writer).to receive(:new).and_return(mock_journaled_writer)
    end

    context 'when no app job priority is set' do
      it 'creates a Journaled::Writer with this event and journals it with the default priority' do
        sample_journaled_event.journal!
        expect(Journaled::Writer).to have_received(:new)
          .with(journaled_event: sample_journaled_event)
        expect(mock_journaled_writer).to have_received(:journal!)
      end
    end
  end

  describe '#journaled_schema_name' do
    it 'returns the underscored version on the class name' do
      expect(sample_journaled_event.journaled_schema_name).to eq 'some_class_name'
    end

    context 'when the class is modularized' do
      let(:sample_journaled_event_class_name) { 'SomeModule::SomeClassName' }

      it 'returns the underscored version on the class name' do
        expect(sample_journaled_event.journaled_schema_name).to eq 'some_module/some_class_name'
      end
    end
  end

  describe '#event_type' do
    it 'returns the underscored version on the class name' do
      expect(sample_journaled_event.event_type).to eq 'some_class_name'
    end

    context 'when the class is modularized' do
      let(:sample_journaled_event_class_name) { 'SomeModule::SomeClassName' }

      it 'returns the underscored version on the class name, with slashes replaced with underscores' do
        expect(sample_journaled_event.event_type).to eq 'some_module_some_class_name'
      end
    end
  end

  describe '#journaled_partition_key' do
    it 'returns the #event_type' do
      expect(sample_journaled_event.journaled_partition_key).to eq 'some_class_name'
    end
  end

  describe '#journaled_app_name' do
    it 'returns nil in the base class so it can be set explicitly in apps spanning multiple app domains' do
      expect(sample_journaled_event.journaled_app_name).to be_nil
    end

    it 'returns the journaled default if set' do
      allow(Journaled).to receive(:default_app_name).and_return("my_app")
      expect(sample_journaled_event.journaled_app_name).to eq("my_app")
    end
  end

  describe '#journaled_attributes' do
    let(:fake_uuid) { 'FAKE_UUID' }
    let(:frozen_time) { Time.zone.parse('15/2/2017 13:00') }
    before do
      allow(SecureRandom).to receive(:uuid).and_return(fake_uuid).once
    end
    around do |example|
      Timecop.freeze(frozen_time) { example.run }
    end

    context 'when no additional attributes have been defined' do
      it 'returns the base attributes, and memoizes them after the first call' do
        expect(sample_journaled_event.journaled_attributes).to eq id: fake_uuid, created_at: frozen_time, event_type: 'some_class_name'
        expect(sample_journaled_event.journaled_attributes).to eq id: fake_uuid, created_at: frozen_time, event_type: 'some_class_name'
      end
    end

    context 'when there are additional attributes specified, but not defined' do
      let(:sample_journaled_event_class) do
        Class.new do
          include Journaled::Event

          journal_attributes :foo
        end
      end

      it 'raises a no method error' do
        expect { sample_journaled_event.journaled_attributes }.to raise_error NoMethodError
      end
    end

    context 'when there are additional attributes specified and defined' do
      let(:sample_journaled_event_class) do
        Class.new do
          include Journaled::Event

          journal_attributes :foo, :bar

          def foo
            'foo_return'
          end

          def bar
            'bar_return'
          end
        end
      end

      it 'returns the specified attributes plus the base ones' do
        expect(sample_journaled_event.journaled_attributes).to eq(
          id: fake_uuid,
          created_at: frozen_time,
          event_type: 'some_class_name',
          foo: 'foo_return',
          bar: 'bar_return',
        )
      end
    end
  end
end
