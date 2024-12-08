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

  def initialize(logger)
    @logger = logger
    @session_name = "pllm-#{SecureRandom.uuid}"
    create_session
  end

  def create_session
    system("tmux new-session -d -s #{@session_name} -n main")
    system("tmux set-option -t #{@session_name} status off")
    system("tmux resize-pane -t #{@session_name} -x 80 -y 40")
    @logger.info("Created TMux session #{@session_name} with window size 80x40")
  rescue StandardError => e
    @logger.error("Failed to create TMux session: #{e}")
  end  

  def send_keys(keys)
    parsed_keys = parse_key_sequence(keys)
    system("tmux send-keys -t #{@session_name} #{parsed_keys}")
  end

  def parse_key_sequence(keys)
    key_mappings = {
      'Enter' => 'Enter',
      'Tab' => 'Tab',
      'Backspace' => 'Backspace',
      'Space' => 'Space',
      'Escape' => 'Escape',
      'Up' => 'Up',
      'Down' => 'Down',
      'Left' => 'Left',
      'Right' => 'Right'
    }

    keys.map do |key|
      key.strip!

      # Handle Ctrl+<letter> or Alt+<letter> sequences
      if key =~ /^Ctrl\+([A-Za-z])$/
        "\"C-#{$1.downcase}\""
      elsif key =~ /^Alt\+([A-Za-z])$/
        "\"M-#{$1.downcase}\""
      elsif key_mappings.key?(key)
        "\"#{key_mappings[key]}\""
      else
        "\"#{key}\""
      end
    end.join(' ')
  end

  def capture_output
    stdout, stderr, status = Open3.capture3("tmux capture-pane -pt #{@session_name}")
    raise "TMux capture error: #{stderr}" unless status.success?
    stdout
  end

  def cleanup
    system("tmux kill-session -t #{@session_name}")
    @logger.info("Killed TMux session #{@session_name}")
  end
end

# Manages the scratchpad state
class Scratchpad
  attr_reader :content

  def initialize
    @content = "First iteration"
  end

  def update(reasoning, new_content)
    timestamp = Time.now.utc.iso8601
    @content += "\n[#{timestamp}] #{reasoning}\n#{new_content}"
  end

  def to_s
    @content
  end
end

# Handles communication with the LLM API
class LLMClient
  def initialize(endpoint, logger)
    @endpoint = endpoint
    @logger = logger
  end

  def query(prompt)
    uri = URI.parse(@endpoint)
    request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
    request.body = { prompt: prompt, max_tokens: 256 }.to_json

    response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
    JSON.parse(response.body)
  rescue JSON::ParserError => e
    @logger.error("Failed to parse LLM response: #{e}")
    { 'reasoning' => 'Error parsing response.', 'keypresses' => [], 'mission_complete' => false, 'new_scratchpad' => 'Error parsing response.' }
  end
end

# Main controller
class PLLMController
  def initialize(logger)
    @logger = logger
    @session_manager = SessionManager.new(logger)
    @scratchpad = Scratchpad.new
    @llm_client = LLMClient.new(LLAMA_API_ENDPOINT, logger)
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
You are a helpful software system designed to suggest key presses to accomplish the given mission.

You are being run iteratively to complete a mission.

Every iteration, you receive:
- the mission statement
- the current state of the terminal
- the scratchpad from the previous iteration

You can provide reasoning, a set of key presses, and a new scratchpad message to achieve the mission.

Special key format:
- Use 'Ctrl+<letter>' for Control key combinations (e.g., 'Ctrl+C')
- Use 'Alt+<letter>' for Alt key combinations (e.g., 'Alt+F')
- Special keys: 'Enter', 'Tab', 'Backspace', 'Space', 'Escape', 'Up', 'Down', 'Left', 'Right'

Return your response in the following JSON format:

{
  "reasoning": "Explain your thought process here.",
  "keypresses": ["Enter", "Ctrl+S", "Ctrl+X"],
  "mission_complete": false,
  "new_scratchpad": "Add any notes or context for the next iteration."
}

-------------------------------------------------------------------------------
Mission statement
-------------------------------------------------------------------------------
#{MISSION}
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
Scratchpad:
-------------------------------------------------------------------------------
#{@scratchpad}
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
Terminal State:
-------------------------------------------------------------------------------
#{terminal_state}
-------------------------------------------------------------------------------
PROMPT
  end

  def process_response(response)
    # Output the prompt and the raw response for transparency
    puts "\n--- Raw Response from LLM ---"
    puts response.to_json

    # Extract fields from the response
    reasoning = response['reasoning']
    keypresses = response['keypresses'] || []
    @mission_complete = response['mission_complete']
    new_scratchpad = response['new_scratchpad']

    @logger.info("Reasoning: #{reasoning}")
    @logger.info("New Scratchpad: #{new_scratchpad}")
    @scratchpad.update(reasoning, new_scratchpad)

    # Execute keypresses
    unless keypresses.empty?
      @logger.info("Executing keypresses: #{keypresses.join(', ')}")
      @session_manager.send_keys(keypresses)
      sleep(1) # Give some time for command execution
    end
  end
end

# --- Run the PLLM Controller ---
controller = PLLMController.new(logger)
controller.run
