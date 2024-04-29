# frozen_string_literal: true

module Journaled
  class ApplicationJob < Journaled.job_base_class_name.constantize
  end
end
