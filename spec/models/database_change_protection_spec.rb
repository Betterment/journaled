require 'rails_helper'

if Rails::VERSION::MAJOR > 5 || (Rails::VERSION::MAJOR == 5 && Rails::VERSION::MINOR >= 2)
  # rubocop:disable Rails/SkipsModelValidations
  RSpec.describe "Raw database change protection" do
    let(:journaled_class) do
      Class.new(Delayed::Job) do
        include Journaled::Changes

        journal_changes_to :locked_at, as: :attempt
      end
    end

    let(:journaled_class_with_no_journaled_columns) do
      Class.new(Delayed::Job) do
        include Journaled::Changes
      end
    end

    describe "the relation" do
      describe "#update_all" do
        it "refuses on journaled columns passed as hash" do
          expect { journaled_class.update_all(locked_at: nil) }.to raise_error(/aborted by Journaled/)
        end

        it "refuses on journaled columns passed as string" do
          expect { journaled_class.update_all("\"locked_at\" = NULL") }.to raise_error(/aborted by Journaled/)
          expect { journaled_class.update_all("locked_at = null") }.to raise_error(/aborted by Journaled/)
          expect { journaled_class.update_all("last_error = 'locked_at'") }.not_to raise_error
        end

        it "succeeds on unjournaled columns" do
          expect { journaled_class.update_all(handler: "") }.not_to raise_error
        end

        it "succeeds when forced on journaled columns" do
          expect { journaled_class.update_all({ locked_at: nil }, force: true) }.not_to raise_error
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
      let(:job) do
        module TestJob
          def perform
            "foo"
          end

          module_function :perform
        end
      end

      subject { journaled_class.enqueue(job) }

      describe "#update_columns" do
        it "refuses on journaled columns" do
          expect { subject.update_columns(locked_at: nil) }.to raise_error(/aborted by Journaled/)
        end

        it "succeeds on unjournaled columns" do
          expect { subject.update_columns(handler: "") }.not_to raise_error
        end

        it "succeeds when forced on journaled columns" do
          expect { subject.update_columns({ locked_at: nil }, force: true) }.not_to raise_error
        end
      end

      describe "#delete" do
        it "refuses if journaled columns exist" do
          expect { subject.delete }.to raise_error(/aborted by Journaled/)
        end

        it "succeeds if no journaled columns exist" do
          instance = journaled_class_with_no_journaled_columns.enqueue(job)
          expect { instance.delete }.not_to raise_error
        end

        it "succeeds if journaled columns exist when forced" do
          expect { subject.delete(force: true) }.not_to raise_error
        end
      end
    end
  end
  # rubocop:enable Rails/SkipsModelValidations
end
