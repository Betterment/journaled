require 'rails_helper'

RSpec.describe Journaled::Writer do
  subject { described_class.new journaled_event: journaled_event }

  describe '#initialize' do
    context 'when the Journaled Event does not implement all the necessary methods' do
      let(:journaled_event) { instance_double(Journaled::Event) }

      it 'raises on initialization' do
        expect { subject }.to raise_error RuntimeError, /An enqueued event must respond to/
      end
    end

    context 'when the Journaled Event returns non-present values for some of the required methods' do
      let(:journaled_event) do
        instance_double(
          Journaled::Event,
          journaled_schema_name: nil,
          journaled_attributes: {},
          journaled_partition_key: '',
          journaled_stream_name: nil,
          journaled_enqueue_opts: {},
        )
      end

      it 'raises on initialization' do
        expect { subject }.to raise_error RuntimeError, /An enqueued event must have a non-nil response to/
      end
    end

    context 'when the Journaled Event complies with the API' do
      let(:journaled_event) do
        instance_double(
          Journaled::Event,
          journaled_schema_name: :fake_schema_name,
          journaled_attributes: { foo: :bar },
          journaled_partition_key: 'fake_partition_key',
          journaled_stream_name: nil,
          journaled_enqueue_opts: {},
        )
      end

      it 'does not raise on initialization' do
        expect { subject }.not_to raise_error
      end
    end
  end

  describe '#journal!' do
    let(:schema_path) { Journaled::Engine.root.join "journaled_schemas/fake_schema_name.json" }
    let(:schema_file_contents) do
      <<-JSON
          {
            "title": "Foo",
            "type": "object",
            "properties": {
              "foo": {
                "type": "string"
              }
            },
            "required": ["foo"]
          }
      JSON
    end

    before do
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(schema_path).and_return(true)
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(schema_path).and_return(schema_file_contents)
    end

    let(:journaled_enqueue_opts) { {} }
    let(:journaled_event) do
      instance_double(
        Journaled::Event,
        journaled_schema_name: 'fake_schema_name',
        journaled_attributes: journaled_event_attributes,
        journaled_partition_key: 'fake_partition_key',
        journaled_stream_name: 'my_app_events',
        journaled_enqueue_opts: journaled_enqueue_opts,
        tagged?: false,
      )
    end

    context 'when the journaled event does NOT comply with the base_event schema' do
      let(:journaled_event_attributes) { { foo: 1 } }

      it 'raises an error and does not enqueue anything' do
        expect { subject.journal! }
          .to raise_error(JSON::Schema::ValidationError)
          .and not_journal_event_including(anything)
        expect(enqueued_jobs.count).to eq 0
      end
    end

    context 'when the event complies with the base_event schema' do
      context 'when the specific json schema is NOT valid' do
        let(:journaled_event_attributes) { { id: 'FAKE_UUID', event_type: 'fake_event', created_at: Time.zone.now, foo: 1 } }

        it 'raises an error and does not enqueue anything' do
          expect { subject.journal! }
            .to raise_error(JSON::Schema::ValidationError)
            .and not_journal_event_including(anything)
          expect(enqueued_jobs.count).to eq 0
        end
      end

      context 'when the specific json schema is also valid' do
        let(:journaled_event_attributes) { { id: 'FAKE_UUID', event_type: 'fake_event', created_at: Time.zone.now, foo: :bar } }

        it 'creates a delivery with the app name passed through' do
          expect { subject.journal! }
            .to change { enqueued_jobs.count }.from(0).to(1)
            .and journal_event_including(journaled_event_attributes)
            .with_schema_name('fake_schema_name')
            .with_partition_key('fake_partition_key')
            .with_stream_name('my_app_events')
            .with_enqueue_opts({})
          expect(enqueued_jobs.first[:args].first).to include('stream_name' => 'my_app_events')
        end

        context 'when there is no job priority specified in the enqueue opts' do
          around do |example|
            old_priority = Journaled.job_priority
            Journaled.job_priority = 999
            example.run
            Journaled.job_priority = old_priority
          end

          it 'defaults to the global default' do
            expect { subject.journal! }.to change {
              if Rails::VERSION::MAJOR < 6
                enqueued_jobs.count { |j| j[:job] == Journaled::DeliveryJob }
              else
                enqueued_jobs.count { |j| j['job_class'] == 'Journaled::DeliveryJob' && j['priority'] == 999 }
              end
            }.from(0).to(1)
              .and journal_event_including(journaled_event_attributes)
              .with_schema_name('fake_schema_name')
              .with_partition_key('fake_partition_key')
              .with_stream_name('my_app_events')
              .with_priority(999)
              .and not_journal_event_including(anything)
              .with_enqueue_opts(priority: 999) # with_enqueue_opts looks at event itself
          end
        end

        context 'when there is a job priority specified in the enqueue opts' do
          let(:journaled_enqueue_opts) { { priority: 13 } }

          it 'enqueues a Journaled::DeliveryJob with the given priority' do
            expect { subject.journal! }.to change {
              if Rails::VERSION::MAJOR < 6
                enqueued_jobs.count { |j| j[:job] == Journaled::DeliveryJob }
              else
                enqueued_jobs.count { |j| j['job_class'] == 'Journaled::DeliveryJob' && j['priority'] == 13 }
              end
            }.from(0).to(1)
              .and journal_event_including(journaled_event_attributes)
              .with_schema_name('fake_schema_name')
              .with_partition_key('fake_partition_key')
              .with_stream_name('my_app_events')
              .with_priority(13)
              .with_enqueue_opts(priority: 13)
          end
        end
      end
    end

    context 'when the event is tagged' do
      before do
        allow(journaled_event).to receive(:tagged?).and_return(true)
      end

      context 'and the "tags" attribute is not present' do
        let(:journaled_event_attributes) do
          { id: 'FAKE_UUID', event_type: 'fake_event', created_at: Time.zone.now, foo: 'bar' }
        end

        it 'raises an error and does not enqueue anything' do
          expect { subject.journal! }
            .to not_journal_events_including(anything)
            .and raise_error JSON::Schema::ValidationError
          expect(enqueued_jobs.count).to eq 0
        end
      end

      context 'and the "tags" attribute is present' do
        let(:journaled_event_attributes) do
          { id: 'FAKE_UUID', event_type: 'fake_event', created_at: Time.zone.now, foo: 'bar', tags: { baz: 'bat' } }
        end

        it 'creates a delivery with the app name passed through' do
          expect { subject.journal! }
            .to change { enqueued_jobs.count }.from(0).to(1)
            .and journal_event_including(journaled_event_attributes)
            .with_schema_name('fake_schema_name')
            .with_partition_key('fake_partition_key')
            .with_stream_name('my_app_events')
            .with_enqueue_opts({})
            .with_priority(Journaled.job_priority)
            .and not_journal_event_including(anything)
            .with_enqueue_opts(priority: Journaled.job_priority)
          expect(enqueued_jobs.first[:args].first).to include('stream_name' => 'my_app_events')
        end
      end
    end
  end
end
