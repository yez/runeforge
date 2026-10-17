# frozen_string_literal: true

# The code index (see Runeforge::CodeIndex): a project's source split into chunks once per file
# version, so planners and coders are handed the code their step needs instead of reading the
# whole project again. Keyed by git object id, so a commit only adds the files it changed.
Sequel.migration do
  up do
    json_type = database_type == :postgres ? :jsonb : :text

    create_table(:runeforge_code_files) do
      primary_key :id, type: :Bignum
      String :repo, size: 100, null: false
      String :blob, size: 64, null: false           # git object id of the file's content
      String :lang, size: 20
      column :imports, json_type                    # paths the file imports, as written
      DateTime :created_at

      index %i[repo blob], unique: true
    end

    create_table(:runeforge_chunks) do
      primary_key :id, type: :Bignum
      String :repo, size: 100, null: false
      String :blob, size: 64, null: false
      String :symbol, size: 255
      String :kind, size: 20, null: false           # route | function | class | component | test | migration | window
      Integer :line_start, null: false
      Integer :line_end, null: false
      String :content_hash, size: 64, null: false   # the vector cache key
      String :signature, text: true                 # the chunk's first line, the fallback card
      String :text, text: true, null: false         # the chunk's source, at most CodeIndex::CHUNK_CHARS

      index %i[repo blob]
      index :content_hash
    end

    # One vector per chunk text and model, shared across commits, branches and repositories.
    create_table(:runeforge_chunk_vectors) do
      String :content_hash, size: 64, null: false
      String :model, size: 100, null: false
      Integer :dims, null: false
      File :vector, null: false                     # float32, packed and normalised

      primary_key %i[content_hash model]
    end

    create_table(:runeforge_index_state) do
      String :repo, size: 100, null: false
      String :sha, size: 64, null: false
      Integer :files, null: false, default: 0
      Integer :chunks, null: false, default: 0
      String :model, size: 100
      DateTime :indexed_at

      primary_key %i[repo sha]
    end
  end

  down do
    drop_table(:runeforge_index_state, :runeforge_chunk_vectors, :runeforge_chunks, :runeforge_code_files)
  end
end
