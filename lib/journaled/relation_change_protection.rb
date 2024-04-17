# frozen_string_literal: true

module Journaled::RelationChangeProtection
  def update_all(updates, opts = { force: false }) # rubocop:disable Metrics/AbcSize
    unless opts[:force] || !@klass.respond_to?(:journaled_attribute_names) || @klass.journaled_attribute_names.empty?
      conflicting_journaled_attribute_names = case updates
                                                when Hash
                                                  @klass.journaled_attribute_names & updates.keys.map(&:to_sym)
                                                when String
                                                  @klass.journaled_attribute_names.select do |a|
                                                    updates.match?(/\b(?<!')#{a}(?!')\b/)
                                                  end
                                                else
                                                  raise "unsupported type '#{updates.class}' for 'updates'"
                                              end
      raise(<<~ERROR) if conflicting_journaled_attribute_names.present?
        .update_all aborted by Journaled::Changes due to journaled attributes:

          #{conflicting_journaled_attribute_names.join(', ')}

        Consider using .all(lock: true) or .find_each with #update to ensure journaling or invoke
         .update_all with additional arg `{ force: true }` to override and skip journaling.
      ERROR
    end
    super(updates)
  end

  def delete_all(force: false)
    if force || !@klass.respond_to?(:journaled_attribute_names) || @klass.journaled_attribute_names.empty?
      super()
    else
      raise(<<~ERROR)
        #delete_all aborted by Journaled::Changes.

        Call .destroy_all instead to ensure journaling or invoke .delete_all(force: true)
        to override and skip journaling.
      ERROR
    end
  end
end
