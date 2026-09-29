# frozen_string_literal: true

require_relative "lib/runeforge/version"

Gem::Specification.new do |spec|
  spec.name = "runeforge"
  spec.version = Runeforge::VERSION
  spec.authors = ["Jake Yesbeck"]
  spec.email = ["yesbeckjs@gmail.com"]

  spec.summary = "Message-driven orchestrator that turns tickets into reviewed pull requests with sandboxed coding agents."
  spec.description = <<~DESC
    Runeforge runs coding-agent CLIs (Claude Code, Codex, Aider) through a fixed ticket-to-PR workflow.
    Agents coordinate through a messages table in SQLite or PostgreSQL, code is versioned in git,
    and every step that runs generated code happens in a throwaway container.
  DESC
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "db/**/*.rb", "exe/*", "docker/*", "README.md", "LICENSE.txt", "runeforge.yml.example"]
  spec.bindir = "exe"
  spec.executables = ["runeforge"]
  spec.require_paths = ["lib"]

  spec.add_dependency "rack", ">= 3.0"
  spec.add_dependency "rackup", "~> 2.1"
  spec.add_dependency "sequel", "~> 5.0"
  spec.add_dependency "sqlite3", ">= 1.7"
  spec.add_dependency "thor", "~> 1.3"
  spec.add_dependency "webrick", "~> 1.8"
end
