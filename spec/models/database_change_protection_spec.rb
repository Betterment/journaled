# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Rails/SkipsModelValidations
RSpec.describe "Raw database change protection" do
  let(:journaled_class) do
    Class.new(ActiveRecord::Base) do
      include Journaled::Changes

      self.table_name = 'widgets'

      journal_changes_to :name, as: :attempt
    end
  end

  let(:journaled_class_with_no_journaled_columns) do
    Class.new(ActiveRecord::Base) do
      include Journaled::Changes

      self.table_name = 'widgets'
    end
  end

  describe "the relation" do
    describe "#update_all" do
      it "refuses on journaled columns passed as hash" do
        expect { journaled_class.update_all(name: nil) }.to raise_error(/aborted by Journaled/)
      end

      it "refuses on journaled columns passed as string" do
        expect { journaled_class.update_all("\"name\" = NULL") }.to raise_error(/aborted by Journaled/)
        expect { journaled_class.update_all("name = null") }.to raise_error(/aborted by Journaled/)
        expect { journaled_class.update_all("widgets.name = null") }.to raise_error(/aborted by Journaled/)
        expect { journaled_class.update_all("other_column = 'name'") }.not_to raise_error
      end

      it "succeeds on unjournaled columns" do
        expect { journaled_class.update_all(other_column: "") }.not_to raise_error
      end

      it "succeeds when forced on journaled columns" do
        expect { journaled_class.update_all({ name: nil }, force: true) }.not_to raise_error
      end
    end

    describe "#delete" do
      it "refuses if journaled columns exist" do
        expect { journaled_class.delete(1) }.to raise_error(/aborted by Journaled/)
      end

      it "succeeds if no journaled columns exist" do
        expect { journaled_class_with_no_journaled_columns.delete(1) }.not_to raise_error
      end

      it "succeeds if journaled columns exist when forced" do
        expect { journaled_class.delete(1, force: true) }.not_to raise_error
      end
    end

    describe "#delete_all" do
      it "refuses if journaled columns exist" do
        expect { journaled_class.delete_all }.to raise_error(/aborted by Journaled/)
      end

      it "succeeds if no journaled columns exist" do
        expect { journaled_class_with_no_journaled_columns.delete_all }.not_to raise_error
      end

      it "succeeds if journaled columns exist when forced" do
        expect { journaled_class.delete_all(force: true) }.not_to raise_error
      end
    end
  end

  describe "an instance" do
    subject { journaled_class.create!(name: 'foo') }

    describe "#update_columns" do
      it "refuses on journaled columns" do
        expect { subject.update_columns(name: nil) }.to raise_error(/aborted by Journaled/)
      end

      it "succeeds on unjournaled columns" do
        expect { subject.update_columns(other_column: "") }.not_to raise_error
      end

      it "succeeds when forced on journaled columns" do
        expect { subject.update_columns({ name: nil }, force: true) }.not_to raise_error
      end
    end

    describe "#delete" do
      it "refuses if journaled columns exist" do
        expect { subject.delete }.to raise_error(/aborted by Journaled/)
      end

      it "succeeds if no journaled columns exist" do
        instance = journaled_class_with_no_journaled_columns.create!
        expect { instance.delete }.not_to raise_error
      end

      it "succeeds if journaled columns exist when forced" do
        expect { subject.delete(force: true) }.not_to raise_error
      end
    end
  end
end
# rubocop:enable Rails/SkipsModelValidations
