module EnvironmentSpecHelper
  def with_env(opts = {})
    old = {}
    opts.each do |k, v|
      k = k.to_s
      v = v.to_s unless v.nil?
      old[k] = ENV[k]
      ENV[k] = v
    end
    yield
  ensure
    old.each do |k, v|
      ENV[k] = v
    end
  end
end
