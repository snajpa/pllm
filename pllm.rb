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

def send_keys_to_tmux(session_name, keys, logger)
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

  keys.each do |key|
    key.strip!

    if key =~ /^<ctrl\+([a-z])>$/i
      logger.info("Sending Ctrl key: C-#{$1.downcase}")
      system("tmux send-keys -t #{session_name} C-#{$1.downcase}")
    elsif key =~ /^<alt\+([a-z])>$/i
      logger.info("Sending Alt key: M-#{$1.downcase}")
      system("tmux send-keys -t #{session_name} M-#{$1.downcase}")
    elsif key_mappings.key?(key.downcase)
      logger.info("Sending special key: #{key_mappings[key.downcase]}")
      system("tmux send-keys -t #{session_name} #{key_mappings[key.downcase]}")
    else
      # Send plain text character by character
      logger.info("Sending plain text: #{key}")
      key.chars.each do |char|
        system("tmux send-keys -t #{session_name} \"#{char}\"")
      end
    end

    sleep(0.1)  # Small delay between key presses
  end
end

def capture_tmux_output(session_name)
  # Capture the terminal output
  stdout, stderr, status = Open3.capture3("tmux capture-pane -pt #{session_name}")
  raise "TMux capture error: #{stderr}" unless status.success?

  # Normalize the terminal output to 80x40 characters
  normalized_output = stdout.lines.map { |line| line.chomp.ljust(80)[0, 80] }
  normalized_output += Array.new(40 - normalized_output.size, ' ' * 80) if normalized_output.size < 40

  { content: normalized_output.join("\n") }
end


def cleanup_tmux_session(session_name, logger)
  system("tmux kill-session -t #{session_name}")
  logger.info("Killed TMux session #{session_name}")
end

def query_llm(endpoint, prompt, logger)
  uri = URI.parse(endpoint)
  request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
  request.body = { prompt: prompt, max_tokens: 768, stream: true }.to_json

  begin
    full_response = ""

    Net::HTTP.start(uri.hostname, uri.port) do |http|
      http.request(request) do |response|
        response.read_body do |chunk|
          begin
            # Handle the "data: " prefix if present
            chunk.strip!
            next unless chunk.start_with?('data: ')

            # Remove the "data: " prefix and parse the outer JSON
            outer_json = JSON.parse(chunk[6..-1])

            # Extract the 'content' field from the outer JSON
            content = outer_json["content"]

            if content && !content.strip.empty?
              # Print the content field
              print content
              $stdout.flush

              full_response += content
            end
          rescue JSON::ParserError => e
            logger.error("Error parsing chunk: #{e}")
          end
        end
      end
    end

    # Parse the full accumulated response as JSON
    parsed_inner_json = JSON.parse(full_response.strip)
    return parsed_inner_json
  rescue StandardError => e
    logger.error("Error querying LLM: #{e}")
    { 'reasoning' => 'Error querying LLM.', 'keypresses' => [], 'mission_complete' => false, 'new_scratchpad' => 'Error occurred during LLM query.' }
  end
end



# --- Prompt Building ---
def build_prompt(mission, scratchpad, terminal_state)
  cursor_position = terminal_state[:cursor]
  terminal_content = terminal_state[:content]
<<~PROMPT
You are a helpful AI system designed to suggest key presses to accomplish a mission.

You are being run iteratively to help a user achieve a specific task.

On a single iteration, you are expected to make modest progress towards the mission.

You have access to the current terminal state, the mission, and a scratchpad for notes.

Scratchpad should serve as a place for your planning, reasoning, and tracking progress.

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

Format your response in JSON

Helpful tips:
- Don't get ahead of yourself. Take it only a few steps at a time.
- If you need to see the terminal state again, just refresh it.
- Always thoroughly evaluate whether the mission is progressing as expected.
- If you haven't already, map out a plan before executing keypresses.

-------------------------------------------------------------------------------
Scratchpad:
-------------------------------------------------------------------------------
#{scratchpad}
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
Current Terminal State For Your Analysis:
-------------------------------------------------------------------------------
#{terminal_content}
-------------------------------------------------------------------------------

===============================================================================

Example Response:

response =
{
  "reasoning": "To create a new file, I need to open the editor, start inserting content...",
  "keypresses": ["<Enter>", "v", "i", "m", "<Enter>", "i"],
  "mission_complete": false,
  "new_scratchpad": "Saved the file and exited the editor."
}







Your response:

response =
PROMPT
end

def valid_llm_response?(response)
  response.is_a?(Hash) &&
    response.key?('reasoning') &&
    response.key?('keypresses') &&
    response.key?('mission_complete') &&
    response.key?('new_scratchpad') &&
    response['keypresses'].is_a?(Array)
end

begin
  create_tmux_session(session_name, logger)

  until mission_complete
    terminal_state = capture_tmux_output(session_name)
    prompt = build_prompt(MISSION, scratchpad, terminal_state)
    puts prompt
    logger.info("Sending prompt to LLM")
    response = query_llm(LLAMA_API_ENDPOINT, prompt, logger)

    begin      
      unless valid_llm_response?(response)
        logger.error("Invalid LLM response format: #{response}")
        next
      end

      # Extract fields from the response
      reasoning = response['reasoning']
      keypresses = response['keypresses'] || []
      mission_complete = response['mission_complete']
      new_scratchpad = response['new_scratchpad']

      logger.info("LLM Reasoning: #{reasoning}")
      logger.info("LLM Keypresses: #{keypresses.join(', ')}")
      logger.info("Mission Complete? #{mission_complete}")

      if keypresses.empty? && !mission_complete
        logger.warn("No keypresses provided, requesting new response from LLM.")
        next
      end

      # Update scratchpad
      timestamp = Time.now.utc.iso8601
      scratchpad += "\n[#{timestamp}] #{new_scratchpad}\nKeypresses: #{keypresses.join(', ')}\nMission Complete: #{mission_complete}\n\n"

      # Execute keypresses
      send_keys_to_tmux(session_name, keypresses, logger) unless keypresses.empty?
      sleep(2)  # Allow some time for command execution

    rescue JSON::ParserError => e
      logger.error("Failed to parse LLM response: #{e.message}")
      next
    end
  end
rescue Interrupt
  puts "\nInterrupted. Cleaning up..."
ensure
  cleanup_tmux_session(session_name, logger)
end
