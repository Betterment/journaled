# frozen_string_literal: true

module Journaled
  # Represents a failed event from Kinesis send operations
  #
  # Used by both KinesisBatchSender and KinesisSequentialSender to represent
  # events that failed to send to Kinesis, along with error details and whether
  # the failure is transient (retriable) or permanent.
  KinesisFailedEvent = Struct.new(:event, :error_code, :error_message, :transient, keyword_init: true) do
    def transient?
      transient
    end

    def permanent?
      !transient
    end
  end
end
