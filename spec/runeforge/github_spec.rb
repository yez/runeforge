# frozen_string_literal: true

RSpec.describe Runeforge::Integrations::GitHub do
  let(:client) { described_class.new(token: "t0ken") }
  let(:calls) { [] }

  def stub_api(responses)
    allow(Runeforge::Integrations::HTTP).to receive(:request) do |method, url, **opts|
      calls << [method, url.delete_prefix("https://api.github.com"), opts[:body]]
      response = responses.fetch([method, calls.last[1]])
      response.is_a?(Exception) ? raise(response) : response
    end
  end

  it "merges the open pull request for a branch at the expected head" do
    stub_api(
      [:get, "/repos/acme/api/pulls?head=acme%3Aruneforge%2FT-1&state=open"] => [{ "number" => 7 }],
      [:put, "/repos/acme/api/pulls/7/merge"] => { "sha" => "abc123", "merged" => true }
    )
    sha = client.merge_pull(repo_url: "git@github.com:acme/api.git", head: "runeforge/T-1", sha: "f00", method: "squash", title: "T-1: Greet")

    expect(sha).to eq("abc123")
    expect(calls.last).to eq([:put, "/repos/acme/api/pulls/7/merge", { sha: "f00", merge_method: "squash", commit_title: "T-1: Greet" }])
  end

  it "raises when GitHub refuses the merge or there is no open pull request" do
    refused = Runeforge::Integrations::HTTPError.new("PUT api.github.com/... returned 405: Required status check is expected")
    stub_api(
      [:get, "/repos/acme/api/pulls?head=acme%3Aruneforge%2FT-1&state=open"] => [{ "number" => 7 }],
      [:put, "/repos/acme/api/pulls/7/merge"] => refused,
      [:get, "/repos/acme/api/pulls?head=acme%3Aruneforge%2FT-2&state=open"] => []
    )
    args = { repo_url: "https://github.com/acme/api", sha: "f00" }
    expect { client.merge_pull(head: "runeforge/T-1", **args) }.to raise_error(Runeforge::Integrations::HTTPError, /405/)
    expect { client.merge_pull(head: "runeforge/T-2", **args) }.to raise_error(Runeforge::Error, /no open pull request/)
  end
end
