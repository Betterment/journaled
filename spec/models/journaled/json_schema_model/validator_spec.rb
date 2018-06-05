require 'rails_helper'

RSpec.describe Journaled::JsonSchemaModel::Validator do
  subject { described_class.new schema_name }

  describe '#validate!' do
    let(:json_to_validate) { attributes_to_validate.to_json }
    let(:attributes_to_validate) do
      {
        some_string: some_string_value,
        some_decimal: 0.1.to_d,
        some_time: Time.zone.parse('2017-01-20 15:16:17 -05:00'),
        some_int: some_int_value,
        some_optional_string: some_optional_string_value,
        some_nullable_field: some_nullable_field
      }
    end
    let(:some_int_value) { 3 }
    let(:some_string_value) { 'SOME_STRING' }
    let(:some_optional_string_value) { 'SOME_OPTIONAL_STRING' }
    let(:some_nullable_field) { 'VALUE' }

    subject { described_class.new schema_name }

    context 'when the schema name matches a schema in journaled' do
      let(:schema_name) { :fake_json_schema_name }
      let(:gem_path) { Journaled::Engine.root.join "journaled_schemas/#{schema_name}.json" }
      let(:schema_path) { Rails.root.join "journaled_schemas", "#{schema_name}.json" }
      let(:schema_file_contents) do
        <<-JSON
          {
            "title": "Person",
            "type": "object",
            "properties": {
              "some_string": {
                "type": "string"
              },
              "some_decimal": {
                "type": "string"
              },
              "some_time": {
                "type": "string"
              },
              "some_int": {
                "type": "integer"
              },
              "some_optional_string": {
                "type": "string"
              },
              "some_nullable_field": {
                "type": ["string", "null"]
              }
            },
            "required": ["some_string", "some_decimal", "some_time", "some_int", "some_nullable_field"]
          }
        JSON
      end

      before do
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with(gem_path).and_return(false)
        allow(File).to receive(:exist?).with(schema_path).and_return(true)
        allow(File).to receive(:read).with(schema_path).and_return(schema_file_contents)
      end

      context 'when all the required fields are provided' do
        context 'when all the fields are provided' do
          it 'is valid' do
            expect(subject.validate!(json_to_validate)).to eq true
          end
        end

        context 'when an optional field is missing' do
          let(:attributes_to_validate) do
            {
              some_string: some_string_value,
              some_decimal: 0.1.to_d,
              some_time: Time.zone.parse('2017-01-20 15:16:17 -05:00'),
              some_int: some_int_value,
              some_nullable_field: some_nullable_field
            }
          end

          it 'is valid' do
            expect(subject.validate!(json_to_validate)).to eq true
          end
        end

        context 'when a nullable field is nil' do
          let(:some_nullable_optional_field) { nil }

          it 'is valid' do
            expect(subject.validate!(json_to_validate)).to eq true
          end
        end

        context 'but one of the required fields is of the wrong type' do
          let(:some_int_value) { 'NOT_AN_INTEGER' }

          it 'is NOT valid' do
            expect { subject.validate! json_to_validate }.to raise_error JSON::Schema::ValidationError
          end
        end
      end

      context 'when not all the required fields are provided' do
        let(:attributes_to_validate) do
          {
            some_string: some_string_value,
            some_decimal: 0.1.to_d,
            some_time: Time.zone.parse('2017-01-20 15:16:17 -05:00')
          }
        end

        it 'is NOT valid' do
          expect { subject.validate! json_to_validate }.to raise_error JSON::Schema::ValidationError
        end
      end
    end

    context 'when the schema name does not match a schema in journaled' do
      let(:schema_name) { :nonexistent_avro_scehma }

      before do
        allow(File).to receive(:exist?).and_return(false)
      end

      it 'raises an error loading the schema' do
        expect { subject.validate! json_to_validate }.to raise_error(/not found in any of Journaled::Engine.root,/)
      end
    end
  end
end
