# frozen_string_literal: true

module Runeforge
  # Agent conversations that outlive one run (`agent.conversation: step`, the default). Each planner
  # run starts a conversation, a re-plan included, and the coder's attempts at that plan continue it,
  # so the coder starts from what the planner learned instead of reading the project again.
  #
  # Claude Code keeps the transcript itself: Runeforge records its session id, resumes it with
  # `--resume`, and keeps the session files in sessions/<id> under the home (mounted into the
  # container). The ruby_llm agent hands its transcript back as RubyLLM::Message#to_h hashes,
  # which are stored here and given to the next run in its workspace.
  class Conversations
    ROLES = %w[system user assistant tool].freeze

    attr_reader :db

    def initialize(db, home:)
      @db = db
      @home = home
    end

    def table = db[:runeforge_conversations]

    def messages_table = db[:runeforge_conversation_messages]

    def start(task_id:, repo:, adapter:)
      now = Runeforge.now
      find(table.insert(task_id:, repo:, adapter:, created_at: now, updated_at: now))
    end

    def find(id) = table.where(id:).first

    # The task's newest conversation: the one its latest plan started.
    def latest(task_id) = table.where(task_id:).order(Sequel.desc(:id)).first

    # Where Claude Code keeps this conversation's session files.
    def sessions_dir(conversation) = File.join(@home, "sessions", conversation[:id].to_s).tap { |dir| FileUtils.mkdir_p(dir) }

    # Records the Claude Code session a run used and the session's cost so far. Returns the part of
    # that cost the run added: a resumed session reports the whole session's cost, not the run's.
    def record_session(conversation, session_id:, cost_usd:)
      added = [cost_usd.to_f - conversation[:reported_cost_usd].to_f, 0.0].max
      table.where(id: conversation[:id]).update(session_id:, reported_cost_usd: cost_usd.to_f, updated_at: Runeforge.now)
      added
    end

    # The stored transcript, ready to hand to the next run: without a trailing tool call that never
    # got its result (a run killed mid-tool), which a provider would reject.
    def messages(conversation)
      list = messages_table.where(conversation_id: conversation[:id]).order(:seq).select_map(:payload)
                           .map { |payload| JSON.parse(payload) }
      self.class.finished(list)
    end

    # Appends what a run added to the transcript. The list comes from the agent's workspace, so it
    # is checked before it is stored: hashes with a known role, nothing else.
    def append(conversation, list, message_id: nil)
      list = self.class.validate(list)
      seq = messages_table.where(conversation_id: conversation[:id]).max(:seq) || 0
      now = Runeforge.now
      rows = list.each_with_index.map do |message, index|
        { conversation_id: conversation[:id], seq: seq + index + 1, role: message["role"], payload: JSON.generate(message),
          message_id:, created_at: now }
      end
      messages_table.multi_insert(rows) if rows.any?
      table.where(id: conversation[:id]).update(updated_at: now)
      rows.size
    end

    def self.validate(list)
      raise Error, "the conversation isn't a list of messages" unless list.is_a?(Array)

      list.each do |message|
        unless message.is_a?(Hash) && ROLES.include?(message["role"].to_s)
          raise Error, "the conversation has a message without a known role"
        end
      end
      list.map { |message| message.merge("role" => message["role"].to_s) }
    end

    def self.finished(list)
      list = list.dup
      list.pop while list.last && list.last["role"] == "assistant" && list.last["tool_calls"].is_a?(Hash) &&
                     !list.last["tool_calls"].empty?
      list
    end
  end
end
