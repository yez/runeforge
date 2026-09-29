# frozen_string_literal: true

module Runeforge
  module Integrations
    class Jira
      def self.from_config(config)
        new(url: config["url"], email: ENV[config.fetch("email_env")], token: ENV[config.fetch("token_env")])
      end

      def initialize(url:, email:, token:)
        @url = url&.chomp("/")
        @email = email
        @token = token
      end

      def configured? = [@url, @email, @token].none? { |value| value.to_s.empty? }

      def issue(key)
        data = api(:get, "/rest/api/2/issue/#{URI.encode_www_form_component(key)}?fields=summary,description")
        { "title" => data.dig("fields", "summary"), "description" => data.dig("fields", "description").to_s }
      end

      def comment(key, text)
        api(:post, "/rest/api/2/issue/#{URI.encode_www_form_component(key)}/comment", body: { body: text })
      end

      private

      def api(method, path, body: nil)
        raise Error, "JIRA is not configured (jira.url, JIRA_EMAIL, JIRA_API_TOKEN)" unless configured?

        auth = ["#{@email}:#{@token}"].pack("m0")
        HTTP.request(method, "#{@url}#{path}", body:, headers: { "Authorization" => "Basic #{auth}", "Accept" => "application/json" })
      end
    end
  end
end
