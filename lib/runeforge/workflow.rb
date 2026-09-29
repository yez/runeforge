# frozen_string_literal: true

module Runeforge
  # Routing rules: which command to send when a result arrives. Handlers run inside the
  # supervisor's transaction through a Supervisor::Context.
  class Workflow
    attr_reader :name

    def initialize(name, &block)
      @name = name
      @handlers = {}
      instance_eval(&block)
    end

    def on(type, &block)
      @handlers[type.to_s] = block
    end

    def handler_for(type) = @handlers[type.to_s]
  end
end
