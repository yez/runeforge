# frozen_string_literal: true

require "runeforge"
require "runeforge/cli"
require "runeforge/web/webhook_app"

Dir[File.join(__dir__, "support", "**", "*.rb")].each { |file| require file }

RSpec.configure do |config|
  config.before { Runeforge::Platform.instance_variable_set(:@xcode, nil) } # its Xcode check is cached per process
  config.disable_monkey_patching!
  config.order = :random
  config.example_status_persistence_file_path = "tmp/rspec-status.txt"
  config.include Helpers
  config.extend Backends::GroupMethods
end
