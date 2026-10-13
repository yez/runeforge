# frozen_string_literal: true

RSpec.describe Runeforge::TestProbe do
  describe ".load_errors" do
    let(:output) do
      <<~OUT
        DEPRECATION WARNING: something noisy
        \e[31mAn error occurred while loading ./spec/lib/resume_build/snapshot_spec.rb.\e[0m
        Failure/Error:
          RSpec.describe ResumeBuild::Snapshot do

        NameError:
          uninitialized constant ResumeBuild
        # ./spec/lib/resume_build/snapshot_spec.rb:3:in '<top (required)>'
        # /opt/bundle/gems/rspec-core-3.13.0/lib/rspec/core/configuration.rb:2138:in 'load'
        An error occurred while loading ./spec/models/builder_spec.rb.
        Failure/Error: belongs_to :thing
        NoMethodError:
          undefined method 'belongs_to'
        No examples found.

        Finished in 0.00004 seconds (files took 1.4 seconds to load)
        0 examples, 0 failures, 2 errors occurred outside of examples
      OUT
    end

    it "returns each spec file's load error, without gem backtrace lines or what follows" do
      errors = described_class.load_errors(output)

      expect(errors.size).to eq(2)
      expect(errors.first).to eq(<<~TEXT.strip)
        An error occurred while loading ./spec/lib/resume_build/snapshot_spec.rb.
        Failure/Error:
          RSpec.describe ResumeBuild::Snapshot do

        NameError:
          uninitialized constant ResumeBuild
        # ./spec/lib/resume_build/snapshot_spec.rb:3:in '<top (required)>'
      TEXT
      expect(errors.last).to start_with("An error occurred while loading ./spec/models/builder_spec.rb.")
                         .and end_with("undefined method 'belongs_to'")
    end

    it "is empty for a run whose files loaded, and caps a long error" do
      expect(described_class.load_errors("12 examples, 3 failures\n")).to eq([])
      long = "An error occurred while loading ./spec/a_spec.rb.\n#{'x' * 2000}\n0 examples, 0 failures\n"
      expect(described_class.load_errors(long, max: 100).first).to end_with("...").and(satisfy { |text| text.bytesize <= 103 })
    end
  end
end
