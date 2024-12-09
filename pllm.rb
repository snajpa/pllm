require 'securerandom'
require 'net/http'
require 'uri'
require 'json'
require 'open3'
require 'time'
require 'logger'

# --- Constants ---
LLAMA_API_ENDPOINT = 'http://localhost:8080/v1/completions'
MISSION = 'Write a Python script that calculates prime numbers up to 100.'
LOG_FILE = 'pllm.log'

# --- Logger Setup ---
logger = Logger.new(LOG_FILE, 'daily')
logger.level = Logger::DEBUG

# --- Variables ---
scratchpad = "First iteration"
session_name = "pllm-#{SecureRandom.uuid}"
mission_complete = false

# --- TMux Session Management ---
def create_tmux_session(session_name, logger)
  system("tmux new-session -d -s #{session_name} -n main")
  system("tmux set-option -t #{session_name} status off")
  system("tmux resize-pane -t #{session_name} -x 80 -y 40")
  logger.info("Created TMux session #{session_name} with window size 80x40")
  system("tmux send-keys -t #{session_name} 'clear' Enter")
  sleep(1) # Give time for the shell to initialize
end

def send_keys_to_tmux(session_name, keys)
  key_mappings = {
    '<enter>' => 'Enter',
    '<tab>' => 'Tab',
    '<backspace>' => 'Backspace',
    '<space>' => 'Space',
    '<escape>' => 'Escape',
    '<up>' => 'Up',
    '<down>' => 'Down',
    '<left>' => 'Left',
    '<right>' => 'Right'
  }

  parsed_keys = keys.map do |key|
    key = key.strip.downcase

    if key =~ /^<ctrl\+([a-z])>$/
      "\"C-#{$1}\""
    elsif key =~ /^<alt\+([a-z])>$/
      "\"M-#{$1}\""
    elsif key_mappings.key?(key)
      "\"#{key_mappings[key]}\""
    else
      logger.warn("Unknown keypress: #{key}")
      "\"#{key}\""
    end
  end

  puts "\nExecuting keypresses: #{parsed_keys.join(' ')}"
  system("tmux send-keys -t #{session_name} #{parsed_keys.join(' ')}")
end


def capture_tmux_output(session_name)
  stdout, stderr, status = Open3.capture3("tmux capture-pane -pt #{session_name}")
  raise "TMux capture error: #{stderr}" unless status.success?
  stdout.strip
end

def cleanup_tmux_session(session_name, logger)
  system("tmux kill-session -t #{session_name}")
  logger.info("Killed TMux session #{session_name}")
end

# --- LLM Interaction ---
def query_llm(endpoint, prompt, logger)
  uri = URI.parse(endpoint)
  request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
  request.body = { prompt: prompt, max_tokens: 256 }.to_json

  begin
    response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
    logger.info("Raw LLM Response: #{response.body}")
    parsed_response = JSON.parse(response.body)

    # Extract the 'content' key safely
    content = parsed_response['content'] || ''
    JSON.parse(content)
  rescue JSON::ParserError => e
    logger.error("Failed to parse LLM response content: #{e}")
    {
      'reasoning' => 'Error parsing response.',
      'keypresses' => [],
      'mission_complete' => false,
      'new_scratchpad' => "Error parsing response. #{content}"
    }
  rescue StandardError => e
    logger.error("Unexpected error: #{e}")
    {
      'reasoning' => 'Unexpected error occurred.',
      'keypresses' => [],
      'mission_complete' => false,
      'new_scratchpad' => 'Unexpected error occurred.'
    }
  end
end

# --- Prompt Building ---
def build_prompt(mission, scratchpad, terminal_state)
<<~PROMPT
You are a helpful AI system designed to suggest key presses to accomplish a mission.

-------------------------------------------------------------------------------
Mission:
-------------------------------------------------------------------------------
#{mission}
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
Instructions:
-------------------------------------------------------------------------------
- Provide key presses using the following symbols:
  - <Enter> for the Enter key
  - <Tab> for the Tab key
  - <Backspace> for the Backspace key
  - <Space> for the Space key
  - <Escape> for the Escape key
  - <Up>, <Down>, <Left>, <Right> for arrow keys
  - <Ctrl+X> for Control key combinations (e.g., Ctrl+X)
  - <Alt+F> for Alt key combinations (e.g., Alt+F)

Format your response in JSON with the following fields:
- "reasoning": Your thought process.
- "keypresses": An array of keypresses (e.g., ["<Ctrl+O>", "<Enter>", "<Ctrl+X>"]).
- "mission_complete": true or false.
- "new_scratchpad": Updated notes for the next iteration.

-------------------------------------------------------------------------------
Scratchpad:
-------------------------------------------------------------------------------
#{scratchpad}
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
Terminal State:
-------------------------------------------------------------------------------
#{terminal_state}
-------------------------------------------------------------------------------

Example Response:

response =
{
  "reasoning": "To save the file and exit the editor, use Ctrl+O, Enter, and Ctrl+X.",
  "keypresses": ["<Ctrl+O>", "<Enter>", "<Ctrl+X>"],
  "mission_complete": false,
  "new_scratchpad": "Saved the file and exited the editor."
}

response =
PROMPT
end

# --- Main Execution Loop ---
create_tmux_session(session_name, logger)

begin
  until mission_complete
    terminal_state = capture_tmux_output(session_name)
    puts "\n--- Captured Terminal State ---\n#{terminal_state}"

    prompt = build_prompt(MISSION, scratchpad, terminal_state)
    puts "\n--- Prompt Sent to LLM ---\n#{prompt}"

    response = query_llm(LLAMA_API_ENDPOINT, prompt, logger)

    p response

    # Extract fields from the response
    reasoning = response['reasoning']
    keypresses = response['keypresses'] || []
    mission_complete = response['mission_complete']
    new_scratchpad = response['new_scratchpad']

    # Debug output
 #  puts "\n--- Reasoning ---\n#{reasoning}"
 #  puts "\n--- Keypresses ---\n#{keypresses.join(', ')}"
 #  puts "\n--- Mission Complete? ---\n#{mission_complete}"
 #  puts "\n--- New Scratchpad ---\n#{new_scratchpad}"

    # Update scratchpad
    timestamp = Time.now.utc.iso8601
    scratchpad = "\n[#{timestamp}] #{new_scratchpad}"

    # Execute keypresses
    send_keys_to_tmux(session_name, keypresses) unless keypresses.empty?
    sleep(2) # Allow some time for command execution
  end
rescue Interrupt
  puts "\nInterrupted. Cleaning up..."
ensure
  cleanup_tmux_session(session_name, logger)
end
