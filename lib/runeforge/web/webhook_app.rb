# frozen_string_literal: true

require "rack"

module Runeforge
  module Web
    # Rack app for JIRA webhooks. Mount it in Rails (`mount Runeforge::Web::WebhookApp.new => "/runeforge"`)
    # or run it with `runeforge webhook`. Issues carrying the trigger label become tasks.
    class WebhookApp
      def initialize(env = nil)
        @env = env
      end

      def call(rack_env)
        request = Rack::Request.new(rack_env)
        return respond(404, "not found") unless request.post? && request.path_info == "/webhooks/jira"
        return respond(503, "webhook secret is not configured") if secret.to_s.empty?

        token = request.get_header("HTTP_X_RUNEFORGE_TOKEN") || request.GET["token"]
        return respond(401, "bad token") unless token && Rack::Utils.secure_compare(token, secret)

        handle(JSON.parse(request.body.read))
      rescue JSON::ParserError
        respond(400, "body is not JSON")
      rescue Error => e
        respond(422, e.message)
      end

      private

      def handle(payload)
        issue = payload["issue"]
        return respond(202, "ignored: no issue") unless issue.is_a?(Hash)

        fields = issue["fields"] || {}
        return respond(202, "ignored: missing #{jira['trigger_label']} label") unless Array(fields["labels"]).include?(jira["trigger_label"])

        key = issue["key"].to_s
        return respond(200, "task #{key} already exists") if env.tasks.find(key)

        repo = jira["project_repos"][key.split("-").first] || jira["default_repo"]
        raise Error, "no repo mapped for #{key}; set jira.project_repos or jira.default_repo" unless repo

        task = Intake.new(env).create(repo:, ticket: key, title: fields["summary"], description: plain_text(fields["description"]))
        respond(201, "created task #{task[:id]}")
      end

      BLOCK_NODES = %w[paragraph heading listItem codeBlock blockquote].freeze

      # JIRA sends descriptions as plain text or as Atlassian Document Format; flatten ADF to text.
      def plain_text(node)
        case node
        when String then node
        when Array then node.map { |child| plain_text(child) }.join
        when Hash
          text = node["text"] || plain_text(node["content"])
          BLOCK_NODES.include?(node["type"]) ? "#{text}\n" : text.to_s
        else ""
        end
      end

      def env = (@env ||= Runeforge.environment)

      def jira = env.config["jira"]

      def secret = ENV[jira.fetch("webhook_secret_env")]

      def respond(status, message)
        [status, { "content-type" => "application/json" }, [JSON.generate(message: message)]]
      end
    end
  end
end
