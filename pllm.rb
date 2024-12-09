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
    '<backspace>' => 'BSpace',
    '<space>' => 'Space',
    '<escape>' => 'Escape',
    '<up>' => 'Up',
    '<down>' => 'Down',
    '<left>' => 'Left',
    '<right>' => 'Right',
    '<home>' => 'Home',
    '<end>' => 'End',
    '<pageup>' => 'PageUp',
    '<pagedown>' => 'PageDown',
    '<insert>' => 'Insert',
    '<delete>' => 'Delete'
  }

  keys.each do |key|
    key = key.downcase.strip

    if key.include?('<')
      parts = key.split('<')
      text = parts[0]
      command = "<#{parts[1]}"

      unless text.empty?
        logger.info("Sending plain text: #{text}")
        text.chars.each do |char|
          system("tmux send-keys -t #{session_name} \"#{char}\"")
        end
      end

      if key_mappings.key?(command)
        logger.info("Sending special key: #{key_mappings[command]}")
        system("tmux send-keys -t #{session_name} #{key_mappings[command]}")
      elsif match = command.match(/^<(ctrl|c)-([a-z])>$/)
        modifier, char = match[1], match[2]
        logger.info("Sending Ctrl key: C-#{char}")
        system("tmux send-keys -t #{session_name} C-#{char}")
      elsif match = command.match(/^<(alt|a|meta|m)-([a-z])>$/)
        modifier, char = match[1], match[2]
        logger.info("Sending Alt key: M-#{char}")
        system("tmux send-keys -t #{session_name} M-#{char}")
      elsif match = command.match(/^<(shift|s)-([a-z])>$/)
        modifier, char = match[1], match[2]
        logger.info("Sending Shift key: S-#{char}")
        system("tmux send-keys -t #{session_name} S-#{char}")
      else
        logger.warn("Unknown key command: #{command}")
      end
    else
      if key_mappings.key?("<#{key}>")
        logger.info("Sending special key: #{key_mappings["<#{key}>"]}")
        system("tmux send-keys -t #{session_name} #{key_mappings["<#{key}>"]}")
      else
        logger.info("Sending plain text: #{key}")
        key.chars.each do |char|
          system("tmux send-keys -t #{session_name} \"#{char}\"")
        end
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

  { content: normalized_output.join("\n"), cursor: { x: 0, y: normalized_output.size - 1 } }
end

def cleanup_tmux_session(session_name, logger)
  system("tmux kill-session -t #{session_name}")
  logger.info("Killed TMux session #{session_name}")
end

def query_llm(endpoint, prompt, logger)
  uri = URI.parse(endpoint)
  request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
  request.body = { prompt: prompt, max_tokens: 1024, stream: true }.to_json

  begin
    full_response = ""
    bracket_count = 0
    current_json = ""
    response = nil

    Net::HTTP.start(uri.hostname, uri.port) do |http|
      http.request(request) do |response|
        response.read_body do |chunk|
          begin
            chunk.strip!
            if chunk.start_with?('data: ')
              content = JSON.parse(chunk[6..-1])["content"]
              if content && !content.strip.empty?
                print content
                $stdout.flush
                full_response += content

                # Track brackets
                content.chars.each do |char|
                  case char
                  when '{'
                    bracket_count += 1
                    current_json += char
                  when '}'
                    bracket_count -= 1
                    current_json += char
                    if bracket_count == 0 && !current_json.strip.empty?
                      # We have a complete JSON response, yield it and return
                      yield current_json
                      return
                    end
                  else
                    current_json += char
                  end
                end
              end
            end
          rescue JSON::ParserError => e
            logger.error("Error parsing chunk: #{e}")
          end
        end
      end
    end

    # If we still have unmatched brackets, something went wrong
    if bracket_count != 0
      logger.error("Unmatched brackets in LLM response")
    end
  rescue StandardError => e
    logger.error("Error querying LLM: #{e}")
    { 'reasoning' => 'Error querying LLM.', 'keypresses' => [], 'mission_complete' => false, 'new_scratchpad': 'Error occurred during LLM query.' }
  end
end

# --- Prompt Building ---
def build_prompt(mission, scratchpad, terminal_state)
  cursor_position = terminal_state[:cursor]
  terminal_content = terminal_state[:content]
<<~PROMPT

You are a helpful AI system designed to suggest key presses to accomplish a mission on a console interface.

The system has started a new session for you in a terminal emulator. You will be provided with the current terminal state, mission, and instructions to guide the user through the mission.

Please analyze the terminal state, mission, and instructions to suggest key presses that will help the user progress towards completing the mission.

Scratchpad was generated by you in previous iterations and it is up to you to update it with your planning, progress, and any issues encountered, as you see fit.

-------------------------------------------------------------------------------
Current Terminal State:
-------------------------------------------------------------------------------
#{terminal_content}
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
Mission:
-------------------------------------------------------------------------------
#{mission}
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
Instructions:
-------------------------------------------------------------------------------
- On each step, create a plan to guide the user through the Mission and suggest the immediate next key presses.
- Provide key presses using symbols like <Enter>, <Tab>, <Backspace>, <Ctrl-X>, <Alt-F>, <Shift-A>, etc.
- Focus on small, manageable steps.
- Update the scratchpad with your planning, progress, and any issues encountered.
- Format response in JSON:
response =
  {
    "keypresses": ["<Enter>", "bash", "<Enter>"],
    "mission_complete": false,
    "reasoning": "I am suggesting these key presses to start a new bash session.",
    "new_scratchpad": "Should verify the bash session is started successfully, then proceed with the next steps."
  }
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
Scratchpad:
-------------------------------------------------------------------------------
#{scratchpad}
-------------------------------------------------------------------------------

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

    query_llm(LLAMA_API_ENDPOINT, prompt, logger) do |json_response|
      begin
        parsed_response = JSON.parse(json_response)
        if valid_llm_response?(parsed_response)
          reasoning = parsed_response['reasoning']
          keypresses = parsed_response['keypresses'] || []
          mission_complete = parsed_response['mission_complete']
          new_scratchpad = parsed_response['new_scratchpad']

          logger.info("LLM Reasoning: #{reasoning}")
          logger.info("LLM Keypresses: #{keypresses.join(', ')}")
          logger.info("Mission Complete? #{mission_complete}")

          if keypresses.empty? && !mission_complete
            logger.warn("No keypresses provided, skipping this iteration.")
            return
          end

          # Update scratchpad
          timestamp = Time.now.utc.iso8601
          scratchpad += "\n[#{timestamp}] #{new_scratchpad}\nKeypresses: #{keypresses.join(', ')}\nMission Complete: #{mission_complete}\n\n"

          # Execute keypresses
          unless keypresses.empty?
            send_keys_to_tmux(session_name, keypresses, logger)
            sleep(2)  # Allow some time for command execution

            # Check if the terminal state has changed as expected after keypresses
            new_state = capture_tmux_output(session_name)
            logger.info("Post-Keypress Terminal State: #{new_state[:content][0..100]}...")

            if !new_state[:content].include?("some expected text after progress")
              logger.warn("Expected progress not detected, suggesting reattempt or manual intervention.")
              # Here you might choose to either ask the LLM again or halt for manual intervention.
            end
          end

          # Break the loop if mission_complete is true
          break if mission_complete
        else
          logger.error("Invalid LLM response format: #{parsed_response}")
        end
      rescue JSON::ParserError => e
        logger.error("Failed to parse LLM response: #{e.message}")
      end
    end
  end
rescue Interrupt
  puts "\nInterrupted. Cleaning up..."
ensure
  cleanup_tmux_session(session_name, logger)
end