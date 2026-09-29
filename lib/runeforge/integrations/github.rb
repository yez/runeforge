# frozen_string_literal: true

module Runeforge
  module Integrations
    class GitHub
      def self.from_config(config)
        new(token: ENV[config.fetch("token_env")], api_url: config.fetch("api_url"))
      end

      # "owner/name" for GitHub remotes, nil for anything else.
      def self.slug(repo_url)
        match = repo_url.to_s.match(%r{github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?/?\z})
        match && "#{match[1]}/#{match[2]}"
      end

      def initialize(token:, api_url: "https://api.github.com")
        @token = token
        @api_url = api_url
      end

      # Returns the URL of the open PR for `head`, creating it if needed. Nil for non-GitHub remotes.
      def find_or_create_pull(repo_url:, head:, base:, title:, body:)
        slug = self.class.slug(repo_url)
        return nil unless slug
        raise Error, "GitHub token is not set; cannot open a pull request" if @token.to_s.empty?

        owner = slug.split("/").first
        query = URI.encode_www_form(head: "#{owner}:#{head}", state: "open")
        existing = api(:get, "/repos/#{slug}/pulls?#{query}")
        return existing.first["html_url"] if existing.any?

        api(:post, "/repos/#{slug}/pulls", body: { title:, head:, base:, body: })["html_url"]
      end

      private

      def api(method, path, body: nil)
        HTTP.request(method, "#{@api_url}#{path}", body:, headers: {
                       "Authorization" => "Bearer #{@token}",
                       "Accept" => "application/vnd.github+json",
                       "X-GitHub-Api-Version" => "2022-11-28"
                     })
      end
    end
  end
end
