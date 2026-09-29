# frozen_string_literal: true

require "net/http"
require "uri"

module Runeforge
  module Integrations
    class HTTPError < Error; end

    module HTTP
      module_function

      def request(method, url, headers: {}, body: nil)
        uri = URI(url)
        request = Net::HTTP.const_get(method.to_s.capitalize).new(uri)
        headers.each { |key, value| request[key] = value }
        if body
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(body)
        end
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                       open_timeout: 10, read_timeout: 30) do |http|
          http.request(request)
        end
        unless response.is_a?(Net::HTTPSuccess)
          raise HTTPError, "#{method.upcase} #{uri.host}#{uri.path} returned #{response.code}: #{response.body.to_s[0, 300]}"
        end

        response.body.to_s.empty? ? {} : JSON.parse(response.body)
      end
    end
  end
end
