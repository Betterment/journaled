# frozen_string_literal: true

class Journaled::ActorUriProvider
  include Singleton

  def actor_uri
    actor_global_id_uri || fallback_global_id_uri
  end

  private

  def actor_global_id_uri
    Journaled::Current.actor&.to_global_id&.to_s
  end

  def fallback_global_id_uri
    if defined?(::Rails::Console) || File.basename($PROGRAM_NAME) == "rake"
      "gid://local/#{Etc.getlogin}"
    else
      "gid://#{Rails.application.config.global_id.app}"
    end
  end
end
