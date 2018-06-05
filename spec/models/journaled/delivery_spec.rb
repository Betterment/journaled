require 'rails_helper'

RSpec.describe Journaled::Delivery do
  let(:stream_name) { 'test_events' }
  let(:partition_key) { 'fake_partition_key' }
  let(:serialized_event) { '{"foo":"bar"}' }

  around do |example|
    with_env(JOURNALED_STREAM_NAME: stream_name) { example.run }
  end

  subject { described_class.new serialized_event: serialized_event, partition_key: partition_key, app_name: nil }

  describe '#perform' do
    let!(:stubbed_request) do
      stub_request(:post, 'https://kinesis.us-east-1.amazonaws.com').to_return(status: return_status_code, body: return_status_body)
    end
    let(:return_status_code) { 200 }
    let(:return_status_body) { return_status_body_hash.to_json }
    let(:return_status_body_hash) { { RecordId: '101' } }

    let(:stubbed_body) do
      {
        'StreamName' => stream_name,
        'Data' => Base64.encode64(serialized_event).strip,
        'PartitionKey' => 'fake_partition_key'
      }
    end

    before do
      allow(Journaled).to receive(:enabled?).and_return(true)
    end

    it 'makes requests to AWS to put the event on the Kinesis with the correct body' do
      subject.perform

      expect(stubbed_request.with(body: stubbed_body.to_json)).to have_been_requested.once
    end

    context 'when the stream name env var is NOT set' do
      let(:stream_name) { nil }

      it 'raises an KeyError error' do
        expect { subject.perform }.to raise_error KeyError
      end
    end

    context 'when Amazon responds with an InternalFailure' do
      let(:return_status_code) { 500 }
      let(:return_status_body_hash) { { __type: 'InternalFailure' } }

      it 'catches the error and re-raises a subclass of NotTrulyExceptionalError and logs about the failure' do
        expect(Rails.logger).to receive(:error).with("Kinesis Error - Server Error occurred - Aws::Kinesis::Errors::InternalFailure").once
        expect { subject.perform }.to raise_error described_class::KinesisTemporaryFailure
        expect(stubbed_request).to have_been_requested.once
      end
    end

    context 'when Amazon responds with a ServiceUnavailable' do
      let(:return_status_code) { 503 }
      let(:return_status_body_hash) { { __type: 'ServiceUnavailable' } }

      it 'catches the error and re-raises a subclass of NotTrulyExceptionalError and logs about the failure' do
        allow(Rails.logger).to receive(:error)
        expect { subject.perform }.to raise_error described_class::KinesisTemporaryFailure
        expect(stubbed_request).to have_been_requested.once
        expect(Rails.logger).to have_received(:error).with(/\AKinesis Error/).once
      end
    end

    context 'when we receive a 504 Gateway timeout' do
      let(:return_status_code) { 504 }
      let(:return_status_body) { nil }

      it 'raises an error that subclasses Aws::Kinesis::Errors::ServiceError' do
        expect { subject.perform }.to raise_error Aws::Kinesis::Errors::ServiceError
        expect(stubbed_request).to have_been_requested.once
      end
    end

    context 'when the IAM user does not have permission to put_record to the specified stream' do
      let(:return_status_code) { 400 }
      let(:return_status_body_hash) { { __type: 'AccessDeniedException' } }

      it 'raises an AccessDeniedException error' do
        expect { subject.perform }.to raise_error Aws::Kinesis::Errors::AccessDeniedException
        expect(stubbed_request).to have_been_requested.once
      end
    end

    context 'when the request timesout' do
      let!(:stubbed_request) do
        stub_request(:post, 'https://kinesis.us-east-1.amazonaws.com').to_timeout
      end

      it 'catches the error and re-raises a subclass of NotTrulyExceptionalError and logs about the failure' do
        expect(Rails.logger).to receive(:error).with("Kinesis Error - Networking Error occurred - Seahorse::Client::NetworkingError").once
        expect { subject.perform }.to raise_error described_class::KinesisTemporaryFailure
        expect(stubbed_request).to have_been_requested.once
      end
    end
  end

  describe "#stream_name" do
    context "when app_name is unspecified" do
      subject { described_class.new serialized_event: serialized_event, partition_key: partition_key, app_name: nil }

      it "is fetched from a prefixed ENV var if specified" do
        allow(ENV).to receive(:fetch).and_return("expected_stream_name")
        expect(subject.stream_name).to eq("expected_stream_name")
        expect(ENV).to have_received(:fetch).with("JOURNALED_STREAM_NAME")
      end
    end

    context "when app_name is specified" do
      subject { described_class.new serialized_event: serialized_event, partition_key: partition_key, app_name: "my_funky_app_name" }

      it "is fetched from a prefixed ENV var if specified" do
        allow(ENV).to receive(:fetch).and_return("expected_stream_name")
        expect(subject.stream_name).to eq("expected_stream_name")
        expect(ENV).to have_received(:fetch).with("MY_FUNKY_APP_NAME_JOURNALED_STREAM_NAME")
      end
    end
  end

  describe "#kinesis_client_config" do
    it "is in us-east-1 by default" do
      with_env(AWS_DEFAULT_REGION: nil) do
        expect(subject.kinesis_client_config).to include(region: 'us-east-1')
      end
    end

    it "respects AWS_DEFAULT_REGION env var" do
      with_env(AWS_DEFAULT_REGION: 'us-west-2') do
        expect(subject.kinesis_client_config).to include(region: 'us-west-2')
      end
    end

    it "doesn't limit retry" do
      expect(subject.kinesis_client_config).to include(retry_limit: 0)
    end

    it "provides no AWS credentials by default" do
      with_env(RUBY_AWS_ACCESS_KEY_ID: nil, RUBY_AWS_SECRET_ACCESS_KEY: nil) do
        expect(subject.kinesis_client_config).not_to have_key(:access_key_id)
        expect(subject.kinesis_client_config).not_to have_key(:secret_access_key)
      end
    end

    it "will use legacy credentials if specified" do
      with_env(RUBY_AWS_ACCESS_KEY_ID: 'key_id', RUBY_AWS_SECRET_ACCESS_KEY: 'secret') do
        expect(subject.kinesis_client_config).to include(access_key_id: 'key_id', secret_access_key: 'secret')
      end
    end
  end
end
