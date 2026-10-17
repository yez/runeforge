# frozen_string_literal: true

RSpec.describe Runeforge::Handoff do
  let(:files) do
    {
      "server/routes/bookings.js" => "export function createBooking(req) {\n  return 1;\n}\n",
      "test/guests.test.js" => "describe(\"guests\", () => {\n  it(\"charges 1000 cents per guest\", async () => {});\n});\n",
      "README.md" => (1..70).map { |n| "line #{n}" }.join("\n")
    }
  end
  let(:file) { ->(path) { files[path] } }

  it "keeps the planner's tests, code and cites that exist, and lists what it dropped" do
    data = {
      "requirements" => [
        { "id" => "t1.r1", "status" => "new", "tests" => ["test/guests.test.js > charges 1000 cents per guest", "test/guests.test.js > made up",
                                                       "test/guests.test.js > guests > charges 1000 cents per guest"],
          "code" => [{ "path" => "server/routes/bookings.js", "symbol" => "createBooking", "note" => "creates the row" },
                     { "path" => "server/nope.js" }, { "path" => "server/routes/bookings.js", "symbol" => "missingFn" }],
          "cites" => ["README.md:65", "README.md:900"] },
        { "status" => "new" }
      ],
      "facts" => [{ "key" => "fixture", "kind" => "convention", "text" => "club() makes a club", "paths" => ["test/helpers.js", "README.md"] }],
      "discovered" => [{ "title" => "Slow list", "why" => "N+1", "evidence" => "server/routes/bookings.js:2" }]
    }
    checked = described_class.check(data, role: :planner, file:)

    req = checked.data["requirements"].first
    expect(req["tests"]).to eq([{ "path" => "test/guests.test.js", "name" => "charges 1000 cents per guest" }] * 2)
    expect(req["code"]).to eq([{ "path" => "server/routes/bookings.js", "symbol" => "createBooking", "line_start" => 1, "note" => "creates the row" }])
    expect(req["cites"]).to eq(["README.md:65"])
    expect(checked.data["requirements"].size).to eq(1)
    expect(checked.data["facts"].first["paths"]).to eq(["README.md"])
    expect(checked.data["discovered"].first["title"]).to eq("Slow list")
    expect(checked.dropped).to include("test test/guests.test.js > made up: not in that file", "code server/nope.js: no such file",
                                       "code server/routes/bookings.js missingFn: not in that file", "cite README.md:900: not found",
                                       "a requirement without an id")
  end

  it "keeps the coder's implemented code, and ignores a handoff that isn't an object" do
    checked = described_class.check({ "implemented" => [{ "id" => "t1.r1", "code" => [{ "path" => "server/routes/bookings.js" }] }] },
                                    role: :coder, file:)
    expect(checked.data["implemented"]).to eq([{ "id" => "t1.r1", "code" => [{ "path" => "server/routes/bookings.js" }] }])
    expect(described_class.check([1, 2], role: :coder, file:)).to be_nil
  end

  it "finds test names in common frameworks" do
    text = <<~JS
      describe("guests", () => {
        it("charges a fee", () => {});
        test('refunds', () => {});
      });
      it "works in rspec" do
      end
      def test_python_style():
    JS
    expect(Runeforge::TestNames.in(text)).to include("charges a fee", "refunds", "works in rspec", "test_python_style")
  end
end
