# frozen_string_literal: true

RSpec.describe Runeforge::Web::WebhookApp do
  let(:backend) { "sqlite" }
  let(:env) { build_env("jira" => { "project_repos" => { "DEV" => "demo" } }).tap { |e| add_repo(e) } }
  let(:app) { Rack::MockRequest.new(described_class.new(env)) }

  around do |example|
    ENV["RUNEFORGE_WEBHOOK_SECRET"] = "s3cret"
    example.run
  ensure
    ENV.delete("RUNEFORGE_WEBHOOK_SECRET")
  end

  def deliver(issue, token: "s3cret")
    app.post("/webhooks/jira?token=#{token}", input: JSON.generate("issue" => issue))
  end

  def issue(labels: ["runeforge"], description: "Make it greet")
    { "key" => "DEV-7", "fields" => { "summary" => "Greet people", "labels" => labels, "description" => description } }
  end

  it "rejects a bad token" do
    expect(deliver(issue, token: "nope").status).to eq(401)
  end

  it "ignores issues without the trigger label" do
    expect(deliver(issue(labels: [])).status).to eq(202)
    expect(env.tasks.list).to be_empty
  end

  it "creates one task per labelled issue, flattening rich-text descriptions" do
    adf = { "type" => "doc", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Make it greet" }] }] }
    response = deliver(issue(description: adf))

    expect(response.status).to eq(201)
    expect(env.tasks.find!("DEV-7")).to include(ticket: "DEV-7", title: "Greet people", repo: "demo", branch: "runeforge/DEV-7")
    created = env.tasks.messages("DEV-7").first
    expect(created.payload["description"]).to eq("Make it greet\n")

    expect(deliver(issue).status).to eq(200)
    expect(env.tasks.list.size).to eq(1)
  end

  it "answers 404 for other paths" do
    expect(app.get("/").status).to eq(404)
  end
end
