#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "optparse"
require "psych"
require "uri"

ROOT = File.expand_path("..", __dir__)
SOURCE_PATH = File.join(ROOT, "_data/locales/ru.yml")
TARGET_PATH = File.join(ROOT, "_data/locales/en.yml")
MEMORY_PATH = File.join(ROOT, ".translation-memory/en.yml")
API_URL = URI("https://api.openai.com/v1/responses")
DEFAULT_MODEL = "gpt-6-astra"
BATCH_SIZE = 30

NON_TRANSLATABLE_KEYS = %w[
  id icon avatar email linkedin github gitlab bitbucket codewars link
].freeze

options = {
  check: false,
  seed_approved: false,
  approve_all: false
}

OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/translate.rb [options]"
  parser.on("--check", "Fail if a Russian block needs translation; never call the API") { options[:check] = true }
  parser.on("--seed-approved", "Seed memory from the current English locale as approved") { options[:seed_approved] = true }
  parser.on("--approve-all", "Mark all current machine translations as approved") { options[:approve_all] = true }
end.parse!

def load_yaml(path)
  Psych.safe_load(File.read(path), permitted_classes: [], aliases: false) || {}
end

def dump_yaml(path, value)
  File.write(path, Psych.dump(value, line_width: -1))
end

def segment_for(item, index)
  item.is_a?(Hash) && item["id"] ? "[id=#{item.fetch('id')}]" : "[#{index}]"
end

def walk(value, path = [], result = {})
  case value
  when Hash
    value.each do |key, child|
      next if NON_TRANSLATABLE_KEYS.include?(key)

      walk(child, path + [key], result)
    end
  when Array
    value.each_with_index do |child, index|
      walk(child, path + [segment_for(child, index)], result)
    end
  when String
    key = path.join(".").gsub(".[", "[")
    return result if key.match?(%r{\Askills\.toolset\[.*\]\.(name|level)\z})
    return result if value.strip.empty?

    result[key] = value
  end
  result
end

def replace_translations(value, translations, path = [])
  case value
  when Hash
    value.each_with_object({}) do |(key, child), copy|
      child_path = path + [key]
      lookup = child_path.join(".").gsub(".[", "[")
      copy[key] = if child.is_a?(String) && translations.key?(lookup)
                    translations.fetch(lookup)
                  else
                    replace_translations(child, translations, child_path)
                  end
    end
  when Array
    value.each_with_index.map do |child, index|
      replace_translations(child, translations, path + [segment_for(child, index)])
    end
  else
    value
  end
end

def source_hash(text)
  Digest::SHA256.hexdigest(text)
end

def response_text(payload)
  payload.fetch("output").each do |item|
    next unless item["type"] == "message"

    item.fetch("content", []).each do |content|
      return content.fetch("text") if content["type"] == "output_text"
    end
  end
  raise "OpenAI response did not contain output text"
end

def translate_batch(blocks, api_key, model)
  schema = {
    type: "object",
    properties: {
      translations: {
        type: "array",
        items: {
          type: "object",
          properties: {
            id: { type: "string" },
            translation: { type: "string" }
          },
          required: %w[id translation],
          additionalProperties: false
        }
      }
    },
    required: ["translations"],
    additionalProperties: false
  }

  request_body = {
    model: model,
    store: false,
    instructions: <<~PROMPT.strip,
      Translate professional website content from Russian into natural English.
      Preserve Markdown, HTML entities, URLs, email addresses, product names, code,
      paragraph breaks, and list structure. Do not add, remove, or explain content.
      Return every supplied id exactly once.
    PROMPT
    input: JSON.generate(blocks.map { |id, text| { id: id, source: text } }),
    text: {
      format: {
        type: "json_schema",
        name: "website_translations",
        strict: true,
        schema: schema
      }
    }
  }

  request = Net::HTTP::Post.new(API_URL)
  request["Authorization"] = "Bearer #{api_key}"
  request["Content-Type"] = "application/json"
  request.body = JSON.generate(request_body)

  response = Net::HTTP.start(API_URL.host, API_URL.port, use_ssl: true, read_timeout: 180) do |http|
    http.request(request)
  end
  unless response.is_a?(Net::HTTPSuccess)
    raise "OpenAI API request failed (#{response.code}): #{response.body}"
  end

  parsed = JSON.parse(response_text(JSON.parse(response.body)))
  translated = parsed.fetch("translations").to_h { |item| [item.fetch("id"), item.fetch("translation")] }
  expected_ids = blocks.map(&:first).sort
  actual_ids = translated.keys.sort
  raise "Translation response ids do not match the requested blocks" unless actual_ids == expected_ids

  translated
end

source = load_yaml(SOURCE_PATH)
source_blocks = walk(source)
memory = File.exist?(MEMORY_PATH) ? load_yaml(MEMORY_PATH) : {}
memory["version"] ||= 1
memory["source_locale"] ||= "ru"
memory["target_locale"] ||= "en"
memory["entries"] ||= {}
entries = memory.fetch("entries")

if options[:seed_approved]
  target_blocks = walk(load_yaml(TARGET_PATH))
  missing = source_blocks.keys - target_blocks.keys
  raise "English locale is missing blocks: #{missing.join(', ')}" unless missing.empty?

  source_blocks.each do |id, text|
    entries[id] = {
      "source_hash" => source_hash(text),
      "source" => text,
      "translation" => target_blocks.fetch(id),
      "status" => "approved"
    }
  end
end

if options[:approve_all]
  entries.each_value { |entry| entry["status"] = "approved" }
end

# A manually reviewed entry may have a stale hash after its source and
# translation were edited by hand. Trust it only when the stored source is an
# exact match for the current canonical Russian block.
source_blocks.each do |id, text|
  entry = entries[id]
  next unless entry
  next unless entry["status"] == "approved"
  next unless entry["source"] == text
  next if entry["translation"].to_s.empty?

  entry["source_hash"] = source_hash(text)
end

reusable_by_hash = entries.values.each_with_object({}) do |entry, index|
  next if entry["translation"].to_s.empty?

  index[entry["source_hash"]] ||= entry
end

source_blocks.each do |id, text|
  hash = source_hash(text)
  current = entries[id]
  next if current && current["source_hash"] == hash && !current["translation"].to_s.empty?

  reusable = reusable_by_hash[hash]
  next unless reusable

  entries[id] = {
    "source_hash" => hash,
    "source" => text,
    "translation" => reusable.fetch("translation"),
    "status" => reusable.fetch("status", "machine")
  }
end

pending = source_blocks.filter do |id, text|
  entry = entries[id]
  entry.nil? || entry["source_hash"] != source_hash(text) || entry["translation"].to_s.empty?
end

if pending.any? && options[:check]
  warn "Translation required for:"
  pending.each_key { |id| warn "  - #{id}" }
  exit 1
end

if pending.any?
  api_key = ENV["OPENAI_API_KEY"].to_s
  abort "OPENAI_API_KEY is required to translate #{pending.length} new or changed blocks" if api_key.empty?

  model = ENV.fetch("OPENAI_TRANSLATION_MODEL", DEFAULT_MODEL)
  pending.to_a.each_slice(BATCH_SIZE) do |batch|
    translate_batch(batch, api_key, model).each do |id, translation|
      source_text = source_blocks.fetch(id)
      entries[id] = {
        "source_hash" => source_hash(source_text),
        "source" => source_text,
        "translation" => translation,
        "status" => "machine"
      }
    end
  end
end

entries.select! { |id, _entry| source_blocks.key?(id) }
translations = source_blocks.to_h do |id, _text|
  entry = entries.fetch(id)
  [id, entry.fetch("translation")]
end

dump_yaml(MEMORY_PATH, memory)
dump_yaml(TARGET_PATH, replace_translations(source, translations))

puts "English locale is current: #{source_blocks.length} translated blocks, #{pending.length} updated."
