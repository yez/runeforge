# frozen_string_literal: true

require "webrick"

# Runs the real agent script (lib/runeforge/agent_runner.rb) against a fake provider that speaks
# the OpenAI-style chat/completions protocol, the way ruby_llm's DeepSeek provider does.
RSpec.describe "Runeforge's ruby_llm agent" do
  let(:runner) { File.expand_path("../../lib/runeforge/agent_runner.rb", __dir__) }
  let(:workspace) { File.join(tmpdir, "ws").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:requests) { [] }

  # `script` gets the request body and returns the assistant message to send back.
  def serve(&script)
    server = WEBrick::HTTPServer.new(Port: 0, BindAddress: "127.0.0.1", Logger: WEBrick::Log.new(File::NULL),
                                     AccessLog: [])
    server.mount_proc("/") do |request, response|
      body = JSON.parse(request.body)
      requests << body
      message = script.call(body)
      response["Content-Type"] = "application/json"
      response.body = JSON.generate(
        "id" => "chatcmpl-#{requests.size}", "object" => "chat.completion", "model" => body["model"],
        "choices" => [{ "index" => 0, "message" => message, "finish_reason" => message["tool_calls"] ? "tool_calls" : "stop" }],
        "usage" => { "prompt_tokens" => 100, "completion_tokens" => 20, "total_tokens" => 120 }
      )
    end
    Thread.new { server.start }
    @server = server
    "http://127.0.0.1:#{server.config[:Port]}"
  end

  after { @server&.shutdown }

  def tool_name(body, pattern) = body["tools"].map { |tool| tool.dig("function", "name") }.find { |name| name.match?(pattern) }

  def call_tool(body, pattern, args)
    { "role" => "assistant", "content" => nil, "tool_calls" => [
      { "id" => "call_#{requests.size}", "type" => "function",
        "function" => { "name" => tool_name(body, pattern), "arguments" => JSON.generate(args) } }
    ] }
  end

  def run_agent(base, max_tool_calls: 20)
    env = { "RUNEFORGE_PROMPT" => "Create lib/hello.txt saying hi", "RUNEFORGE_MODEL" => "fake-coder",
            "RUNEFORGE_PROVIDER" => "deepseek", "RUNEFORGE_API_KEY_VAR" => "DEEPSEEK_API_KEY",
            "DEEPSEEK_API_KEY" => "test-key", "RUNEFORGE_API_BASE" => base,
            "RUNEFORGE_MAX_TOOL_CALLS" => max_tool_calls.to_s, "HOME" => tmpdir }
    out, err, status = Open3.capture3(env, RbConfig.ruby, runner, chdir: workspace)
    [out, err, status, JSON.parse(out.lines.last.to_s)]
  end

  it "uses tools to change the workspace and reports its usage" do
    base = serve do |body|
      if body["messages"].none? { |m| m["role"] == "tool" }
        call_tool(body, /write/, "path" => "lib/hello.txt", "content" => "hi\n")
      else
        { "role" => "assistant", "content" => "Wrote lib/hello.txt." }
      end
    end
    out, err, status, result = run_agent(base)

    expect(status).to be_success, err
    expect(File.read(File.join(workspace, "lib/hello.txt"))).to eq("hi\n")
    expect(out).to include("Runeforge agent: fake-coder via deepseek", "→ write_file lib/hello.txt")
    expect(result).to include("result" => "Wrote lib/hello.txt.", "input_tokens" => 200, "output_tokens" => 40)
    expect(requests.first["model"]).to eq("fake-coder")
    expect(requests.first["messages"].first["content"]).to include("autonomous coding agent")
    expect(requests.first["tools"].map { |t| t.dig("function", "name") })
      .to contain_exactly("list_files", "read_file", "write_file", "edit_file", "search", "run_command")
  end

  it "keeps the agent inside the workspace and out of .git and .runeforge" do
    FileUtils.mkdir_p(File.join(workspace, ".runeforge"))
    attempts = [{ "path" => "../escape.txt", "content" => "x" }, { "path" => ".runeforge/agent.rb", "content" => "x" },
                { "path" => ".runeforge/spec.md", "content" => "The spec.\n" }]
    base = serve do |body|
      args = attempts[body["messages"].count { |m| m["role"] == "tool" }]
      args ? call_tool(body, /write/, args) : { "role" => "assistant", "content" => "Gave up." }
    end
    _out, err, status, = run_agent(base)

    expect(status).to be_success, err
    expect(File.exist?(File.join(tmpdir, "escape.txt"))).to be(false)
    expect(Dir.children(File.join(workspace, ".runeforge"))).to eq(["spec.md"]) # the planner's spec is allowed
    tool_results = requests.last["messages"].select { |m| m["role"] == "tool" }.map { |m| m["content"].to_s }
    expect(tool_results).to include(a_string_including("outside the repository"), a_string_including("not available to the agent"))
  end

  it "hands a bad tool call back to the model instead of crashing" do
    base = serve do |body|
      if body["messages"].none? { |m| m["role"] == "tool" }
        call_tool(body, /list_files/, "command" => "ls")
      else
        { "role" => "assistant", "content" => "Recovered." }
      end
    end
    _out, err, status, result = run_agent(base)

    expect(status).to be_success, err
    expect(result["result"]).to eq("Recovered.")
    expect(requests.last["messages"].find { |m| m["role"] == "tool" }["content"]).to include("command")
  end

  it "stops an agent that never finishes and says why" do
    base = serve { |body| call_tool(body, /list_files/, "path" => ".") }
    _out, _err, status, result = run_agent(base, max_tool_calls: 3)

    expect(status.exitstatus).to eq(1)
    expect(result["error"]).to eq("stopped after 3 tool calls without finishing")
  end
end
