require 'securerandom'
require 'net/http'
require 'uri'
require 'json'
require 'logger'
require 'open3'
require 'time'

# --- Constants ---
LLAMA_API_ENDPOINT = 'http://localhost:8080/v1/completions'
MISSION = 'Write a Python script that calculates prime numbers up to 100.'
LOG_FILE = 'pllm.log'

# --- Logger Setup ---
logger = Logger.new(LOG_FILE, 'daily')
logger.level = Logger::DEBUG

# --- Classes ---

# Manages the TMux session
class SessionManager
  attr_reader :session_name

  def initialize
    @session_name = "pllm-#{SecureRandom.uuid}"
    create_session
  end

  def create_session
    system("tmux new-session -d -s #{@session_name} -n main")
    system("tmux set-option -t #{@session_name} status off")
    logger.info("Created TMux session #{@session_name}")
  rescue StandardError => e
    logger.error("Failed to create TMux session: #{e}")
  end

  def send_keys(keys)
    sanitized_keys = keys.gsub('"', '\"')
    system("tmux send-keys -t #{@session_name} \"#{sanitized_keys}\" Enter")
  end

  def capture_output
    stdout, stderr, status = Open3.capture3("tmux capture-pane -pt #{@session_name}")
    raise "TMux capture error: #{stderr}" unless status.success?
    stdout
  end

  def cleanup
    system("tmux kill-session -t #{@session_name}")
    logger.info("Killed TMux session #{@session_name}")
  end
end

# Manages the scratchpad state
class Scratchpad
  attr_reader :content

  def initialize
    @content = "First iteration"
  end

  def update(reasoning)
    timestamp = Time.now.utc.iso8601
    @content += "\n[#{timestamp}] #{reasoning}"
  end

  def to_s
    @content
  end
end

# Handles communication with the LLM API
class LLMClient
  def initialize(endpoint)
    @endpoint = endpoint
  end

  def query(prompt)
    uri = URI.parse(@endpoint)
    request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
    request.body = { prompt: prompt, max_tokens: 256 }.to_json

    response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
    JSON.parse(response.body)
  rescue JSON::ParserError => e
    logger.error("Failed to parse LLM response: #{e}")
    { 'reasoning' => 'Error parsing response', 'actions' => [], 'mission_complete' => false }
  end
end

# Main controller
class PLLMController
  def initialize
    @session_manager = SessionManager.new
    @scratchpad = Scratchpad.new
    @llm_client = LLMClient.new(LLAMA_API_ENDPOINT)
    @mission_complete = false
  end

  def run
    while !@mission_complete
      terminal_state = @session_manager.capture_output
      prompt = build_prompt(terminal_state)
      response = @llm_client.query(prompt)
      process_response(response)
    end
    @session_manager.cleanup
  rescue Interrupt
    puts "\nInterrupted. Cleaning up..."
    @session_manager.cleanup
  end

  private

  def build_prompt(terminal_state)
    <<~PROMPT
      Mission: #{MISSION}
      Scratchpad: #{@scratchpad}
      Terminal State:
      #{terminal_state}

      What should be done next? Provide reasoning and actions.
    PROMPT
  end

  def process_response(response)
    reasoning = response['reasoning']
    actions = response['actions']
    @mission_complete = response['mission_complete']

    logger.info("Reasoning: #{reasoning}")
    @scratchpad.update(reasoning)

    actions.each do |action|
      keys = action['keys']
      logger.info("Executing keys: #{keys}")
      @session_manager.send_keys(keys)
      sleep(1) # Give some time for command execution
    end
  end
end

# --- Run the PLLM Controller ---
controller = PLLMController.new
controller.run
