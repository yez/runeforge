# frozen_string_literal: true

require "socket"

RSpec.describe Runeforge::Embedder do
  # A one-request-at-a-time stand-in for Ollama's /api/embed on a free local port.
  def fake_ollama(status: 200)
    server = TCPServer.new("127.0.0.1", 0)
    requests = []
    thread = Thread.new do
      loop do
        client = server.accept
        head = +""
        head << client.gets until head.end_with?("\r\n\r\n")
        length = head[/Content-Length: (\d+)/i, 1].to_i
        body = JSON.parse(client.read(length))
        requests << body
        answer = JSON.generate("embeddings" => body["input"].map { |text| [text.size.to_f, 1.0] })
        client.write("HTTP/1.1 #{status} OK\r\nContent-Type: application/json\r\nContent-Length: #{answer.bytesize}\r\nConnection: close\r\n\r\n#{answer}")
        client.close
      end
    rescue IOError
      nil
    end
    [server, thread, requests]
  end

  it "embeds through a local Ollama in batches and normalises the vectors" do
    server, thread, requests = fake_ollama
    embedder = described_class.new({ "embedding_provider" => "ollama", "embedding_model" => "nomic-embed-text",
                                     "embedding_url" => "http://127.0.0.1:#{server.addr[1]}" })
    vectors = embedder.embed(Array.new(40) { |i| "x" * (i + 1) })

    expect(vectors.size).to eq(40)
    expect(requests.map { |r| r["input"].size }).to eq([32, 8])
    expect(requests.first["model"]).to eq("nomic-embed-text")
    expect(Math.sqrt(vectors.first.sum { |x| x * x })).to be_within(1e-9).of(1.0)
    expect(embedder.check).to eq([true, "nomic-embed-text answers (2 dimensions)"])
  ensure
    server&.close
    thread&.kill
  end

  it "is off without a model, and falls back (nil) when the model can't be reached" do
    expect(described_class.new({}).embed(["x"])).to be_nil
    expect(described_class.new({}).check.first).to be(true)

    down = described_class.new({ "embedding_provider" => "ollama", "embedding_model" => "m", "embedding_url" => "http://127.0.0.1:9" })
    expect { expect(down.embed(["x"])).to be_nil }.to output(/searching by words instead/).to_stderr
    ok, message = down.check
    expect(ok).to be(false)
    expect(message).to include("ollama pull m")
  end

  it "packs vectors for the database and scores them by dot product" do
    vector = described_class.normalize([3.0, 4.0])
    expect(described_class.unpack(described_class.pack(vector))).to all(be_within(1e-6).of(0.6).or(be_within(1e-6).of(0.8)))
    expect(described_class.dot(vector, vector)).to be_within(1e-6).of(1.0)
  end
end
