# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Journaled::DeliveryJob do
  let(:kinesis_client) { Aws::Kinesis::Client.new(stub_responses: true) }
  let(:args) do
    [
      { serialized_event: '{"foo":"bar"}', partition_key: 'fake_partition_key', stream_name: 'test_events' },
      { serialized_event: '{"baz":"bat"}', partition_key: 'fake_partition_key_2', stream_name: 'test_events_2' },
    ]
  end

  describe '#perform' do
    let(:return_status_body) { { shard_id: '101', sequence_number: '101123' } }
    let(:return_object) { instance_double Aws::Kinesis::Types::PutRecordOutput, return_status_body }

    before do
      allow(Aws::AssumeRoleCredentials).to receive(:new).and_call_original
      allow(Aws::Kinesis::Client).to receive(:new).and_return kinesis_client
      kinesis_client.stub_responses(:put_record, return_status_body)
      allow(kinesis_client).to receive(:put_record).and_call_original

      allow(Journaled).to receive(:enabled?).and_return(true)
    end

    it 'makes requests to AWS to put the event on the Kinesis with the correct body' do
      events = described_class.perform_now(*args)

      expect(events.count).to eq 2
      expect(events.first.shard_id).to eq '101'
      expect(events.first.sequence_number).to eq '101123'
      expect(kinesis_client).to have_received(:put_record).with(
        stream_name: 'test_events',
        data: '{"foo":"bar"}',
        partition_key: 'fake_partition_key',
      )
      expect(kinesis_client).to have_received(:put_record).with(
        stream_name: 'test_events_2',
        data: '{"baz":"bat"}',
        partition_key: 'fake_partition_key_2',
      )
    end

    context 'when JOURNALED_IAM_ROLE_ARN is defined' do
      let(:aws_sts_client) { Aws::STS::Client.new(stub_responses: true) }

      around do |example|
        with_env(JOURNALED_IAM_ROLE_ARN: 'iam-role-arn-for-assuming-kinesis-access') { example.run }
      end

      before do
        allow(Aws::STS::Client).to receive(:new).and_return aws_sts_client
        aws_sts_client.stub_responses(:assume_role, assume_role_response)
      end

      let(:assume_role_response) do
        {
          assumed_role_user: {
            arn: 'iam-role-arn-for-assuming-kinesis-access',
            assumed_role_id: "ARO123EXAMPLE123:Bob",
          },
          credentials: {
            access_key_id: "AKIAIOSFODNN7EXAMPLE",
            secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYzEXAMPLEKEY",
            session_token: "EXAMPLEtc764bNrC9SAPBSM22wDOk4x4HIZ8j4FZTwdQWLWsKWHGBuFqwAeMicRXmxfpSPfIeoIYRqTflfKD8YUuwthAx7mSEI",
            expiration: Time.zone.parse("2011-07-15T23:28:33.359Z"),
          },
        }
      end

      it 'initializes a Kinesis client with assume role credentials' do
        described_class.perform_now(*args)

        expect(Aws::AssumeRoleCredentials).to have_received(:new).with(
          client: aws_sts_client,
          role_arn: "iam-role-arn-for-assuming-kinesis-access",
          role_session_name: "JournaledAssumeRoleAccess",
        )
      end
    end

    context 'when the stream name is not set' do
      let(:args) { [{ serialized_event: '{"foo":"bar"}', partition_key: 'fake_partition_key', stream_name: nil }] }

      it 'raises an ArgumentError error' do
        expect { described_class.perform_now(*args) }.to raise_error ArgumentError, /missing keyword: :?stream_name/
      end
    end

    context 'when Amazon responds with an InternalFailure' do
      before do
        kinesis_client.stub_responses(:put_record, 'InternalFailure')
      end

      it 'catches the error and re-raises a subclass of NotTrulyExceptionalError and logs about the failure' do
        allow(Rails.logger).to receive(:error)
        expect { described_class.perform_now(*args) }.to raise_error described_class::KinesisTemporaryFailure
        expect(Rails.logger).to have_received(:error).with(
          "Kinesis Error - Server Error occurred - Aws::Kinesis::Errors::InternalFailure",
        ).once
      end
    end

    context 'when Amazon responds with a ServiceUnavailable' do
      before do
        kinesis_client.stub_responses(:put_record, 'ServiceUnavailable')
      end

      it 'catches the error and re-raises a subclass of NotTrulyExceptionalError and logs about the failure' do
        allow(Rails.logger).to receive(:error)
        expect { described_class.perform_now(*args) }.to raise_error described_class::KinesisTemporaryFailure
        expect(Rails.logger).to have_received(:error).with(/\AKinesis Error/).once
      end
    end

    context 'when we receive a 504 Gateway timeout' do
      before do
        kinesis_client.stub_responses(:put_record, 'Aws::Kinesis::Errors::ServiceError')
      end

      it 'raises an error that subclasses Aws::Kinesis::Errors::ServiceError' do
        expect { described_class.perform_now(*args) }.to raise_error Aws::Kinesis::Errors::ServiceError
      end
    end

    context 'when the IAM user does not have permission to put_record to the specified stream' do
      before do
        kinesis_client.stub_responses(:put_record, 'AccessDeniedException')
      end

      it 'raises an AccessDeniedException error' do
        expect { described_class.perform_now(*args) }.to raise_error Aws::Kinesis::Errors::AccessDeniedException
      end
    end

    context 'when the request timesout' do
      before do
        kinesis_client.stub_responses(:put_record, Seahorse::Client::NetworkingError.new(Timeout::Error.new))
      end

      it 'catches the error and re-raises a subclass of NotTrulyExceptionalError and logs about the failure' do
        allow(Rails.logger).to receive(:error)
        expect { described_class.perform_now(*args) }.to raise_error described_class::KinesisTemporaryFailure
        expect(Rails.logger).to have_received(:error).with(
          "Kinesis Error - Networking Error occurred - Seahorse::Client::NetworkingError",
        ).once
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

    it "will set http_idle_timeout by default" do
      expect(subject.kinesis_client_config).to include(http_idle_timeout: 5)
    end

    it "will set http_open_timeout by default" do
      expect(subject.kinesis_client_config).to include(http_open_timeout: 2)
    end

    it "will set http_read_timeout by default" do
      expect(subject.kinesis_client_config).to include(http_read_timeout: 60)
    end

    context "when Journaled.http_idle_timeout is specified" do
      it "will set http_idle_timeout by specified value" do
        allow(Journaled).to receive(:http_idle_timeout).and_return(2)
        expect(subject.kinesis_client_config).to include(http_idle_timeout: 2)
      end
    end

    context "when Journaled.http_open_timeout is specified" do
      it "will set http_open_timeout by specified value" do
        allow(Journaled).to receive(:http_open_timeout).and_return(1)
        expect(subject.kinesis_client_config).to include(http_open_timeout: 1)
      end
    end

    context "when Journaled.http_read_timeout is specified" do
      it "will set http_read_timeout by specified value" do
        allow(Journaled).to receive(:http_read_timeout).and_return(2)
        expect(subject.kinesis_client_config).to include(http_read_timeout: 2)
      end
    end
  end
end
