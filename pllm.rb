require 'securerandom'
require 'net/http'
require 'uri'
require 'json'
require 'open3'
require 'time'
require 'logger'
require 'optparse'

# --- Constants ---
LLAMA_API_ENDPOINT = 'http://localhost:8081/v1/completions'
MISSION = 'Map locally reachable hosts and list those which run ssh server in file /tmp/ssh_hosts.'
LOG_FILE = 'pllm.log'

# --- Helper Functions ---
def create_tmux_session(session_name, logger)
  system("tmux new-session -d -s #{session_name} -n main")
  system("tmux set-option -t #{session_name} status off")
  system("tmux resize-pane -t #{session_name} -x 80 -y 40")
  logger.info("Created TMux session #{session_name} with window size 80x40")
  system("tmux send-keys -t #{session_name} 'clear' Enter")
  sleep(1) # Give time for the shell to initialize
end

def send_keys_to_tmux(session_name, keys, logger)
  # Mapping for recognized special keys
  key_mappings = {
    '<enter>' => 'Enter',
    '<tab>' => 'Tab',
    '<backspace>' => 'BSpace',
    '<space>' => ' ',  
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
    # Normalize the key for case-insensitive matching of known tokens
    normalized_key = key.downcase

    if key_mappings.key?(normalized_key)
      # It's one of the special keys
      system("tmux send-keys -t #{session_name} \"#{key_mappings[normalized_key]}\"")
      logger.info("Sending special key: #{key}")
    elsif normalized_key.match?(/^<ctrl-([a-z0-9])>$/)
      # Ctrl combination
      char = normalized_key.match(/^<ctrl-([a-z0-9])>$/)[1]
      system("tmux send-keys -t #{session_name} C-#{char}")
      logger.info("Sending Ctrl key: C-#{char}")
    elsif normalized_key.match?(/^<alt-([a-z0-9])>$/)
      # Alt/Meta combination
      char = normalized_key.match(/^<alt-([a-z0-9])>$/)[1]
      system("tmux send-keys -t #{session_name} M-#{char}")
      logger.info("Sending Alt key: M-#{char}")
    elsif normalized_key.match?(/^<shift-([a-z0-9])>$/)
      # Shift combination
      # tmux supports S- for shifted characters if needed.
      # Not all shifted keys might work as expected directly, but we follow instructions.
      char = normalized_key.match(/^<shift-([a-z0-9])>$/)[1]
      system("tmux send-keys -t #{session_name} S-#{char}")
      logger.info("Sending Shift key: S-#{char}")
    elsif key.start_with?('<') && key.end_with?('>')
      # Unknown special key format
      logger.warn("Unknown special key format: #{key}, skipping.")
      next
    else
      # Plain character(s)
      # Send them directly, character by character
      key.chars.each do |char|
        # Escape special characters for shell
        # Actually `tmux send-keys` can send chars directly; we only need to escape quotes.
        escaped_char = char.gsub(/(["`\\$'])/){|m| "\\" + m}
        system("tmux send-keys -t #{session_name} \"#{escaped_char}\"")
      end
      logger.info("Sending plain text: #{key}")
    end

    sleep(0.1)  # Small delay between key presses
  end
end

def capture_tmux_output(session_name)
  # Capture the terminal output
  stdout, stderr, status = Open3.capture3("tmux capture-pane -pt #{session_name}")
  raise "TMux capture error: #{stderr}" unless status.success?

  # Normalize the terminal output to 80x40 characters
  lines = stdout.lines.map(&:chomp)
  normalized_output = lines.map do |line|
    line.ljust(80)[0, 80]
  end
  normalized_output += Array.new(40 - normalized_output.size, ' ' * 80) if normalized_output.size < 40

  # Get cursor position
  cursor_position = get_cursor_position(session_name)

  # Add line numbers and block symbol where the cursor is
  content_lines = normalized_output.map.with_index do |line, idx|
    line_with_number = "#{idx.to_s.rjust(4)} #{line}"
    if idx == cursor_position[:y]
      line_with_number[cursor_position[:x] + 5] = '█' rescue nil
    end
    line_with_number
  end

  { 
    content: content_lines.join("\n"), 
    cursor: cursor_position 
  }
end

def get_cursor_position(session_name)
  stdout, stderr, status = Open3.capture3("tmux display-message -p -t #{session_name}:0 '\#{cursor_x},\#{cursor_y}'")
  raise "Cursor position retrieval error: #{stderr}" unless status.success?
  x, y = stdout.split(',').map(&:to_i)
  { x: x, y: y }
end

def cleanup_tmux_session(session_name, logger)
  system("tmux kill-session -t #{session_name}")
  logger.info("Killed TMux session #{session_name}")
end

def query_llm(endpoint, prompt, history, terminal_state, options, logger, &block)
  uri = URI.parse(endpoint)
  request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
  request.body = { prompt: prompt, max_tokens: 600, repeat_penalty: 1.1, top_p: 0.98, top_k: 30, stream: true, temperature: 0.7 }.to_json

  begin
    full_response = ""
    bracket_count = 0
    current_json = ""

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

                # Track brackets for JSON extraction
                content.chars.each do |char|
                  case char
                  when '{'
                    bracket_count += 1
                    current_json += char
                  when '}'
                    bracket_count -= 1
                    current_json += char
                    if bracket_count == 0 && !current_json.strip.empty?
                      block.call(current_json)
                      if options[:accumulate]
                        history_limit = 10000
                        history << "Terminal state:\n#{terminal_state[:content]}\nResponse:\n#{current_json}\n\n"
                        history = history[-history_limit..-1] if history.length > history_limit
                      end
                      return
                    end
                  else
                    current_json += char unless bracket_count == 0 && char.strip.empty?
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

    if bracket_count != 0
      logger.error("Unmatched brackets in LLM response")
    end
  rescue StandardError => e
    logger.error("Error querying LLM: #{e}")
    { 'reasoning' => 'Error querying LLM.', 'keypresses' => [], 'mission_complete' => false, 'new_scratchpad' => 'Error occurred during LLM query.', 'next_step' => 'Reattempt or manual intervention required.' }
  end
end

def build_prompt(mission, scratchpad, terminal_state, history, options)
  cursor_position = terminal_state[:cursor]
  terminal_content = terminal_state[:content]
  history_section = if options[:accumulate]
    <<~HISTORY
    ------------------------------------------------------------------------------------
    (history for context)
    ------------------------------------------------------------------------------------
    #{history}

    ------------------------------------------------------------------------------------
    (end history)
    ------------------------------------------------------------------------------------
    HISTORY
  else
    ''
  end
  
  prompt = <<~PROMPT
  #{history_section}
  You are a helpful AI system designed to suggest key presses to accomplish a mission on a console interface.

  The system has started a new session for you in a terminal emulator. You will be provided with the current terminal state, mission, and instructions to guide the user through the mission.

  Please analyze the terminal state, mission, and instructions to suggest key presses that will help the user progress towards completing the mission.

  Scratchpad was generated by you in previous iterations and it is up to you to update it with your planning, progress, and any issues encountered, as you see fit.

  Note: 
  - The terminal output has been prepended with line numbers by the system to help track position. These are not part of the actual terminal content.
  - The block symbol '█' indicates the current cursor position.

  ------------------------------------------------------------------------------------
  Instructions:
  ------------------------------------------------------------------------------------
  - If this is not the first iteration, review the scratchpad to understand the context and progress. Verify we are on the right track.
  - On each step, create a plan to guide the user through the Mission and suggest the immediate next key presses.
  - Provide key presses as an array where each element is a single keypress.
  - For normal characters, just provide the character: "a", "b", "c", "1", "2", etc.
  - For recognized special keys, use the exact angle bracket notation:
    <Enter>, <Tab>, <Backspace>, <Space>, <Escape>, <Up>, <Down>, <Left>, <Right>, <Home>, <End>, <PageUp>, <PageDown>, <Insert>, <Delete>
  - For Ctrl combinations: <Ctrl-[char]> (e.g., <Ctrl-c>)
  - For Alt/Meta combinations: <Alt-[char]> (e.g., <Alt-f>)
  - For Shift combinations: <Shift-[char]> (e.g., <Shift-a>)
  - Focus on small, manageable steps.
  - The user doesn't mind if you use non-interactive commands to speed up the process.
  - The user has no understanding of the mission and is relying on your guidance.
  - Update the scratchpad with your planning, progress, and any issues encountered. Never lose track of your progress and next steps.
  - Check if you're not stuck, clear the screen and start over if needed.
  - Avoid suggesting the same correction multiple times unless the user action changes. Move forward once an action is completed or corrected.

  - Format response in JSON:
    response =
      {
        "reasoning": "I am suggesting these key presses to start a new bash session.",
        "mission_complete": false,
        "new_scratchpad": "Verify the new bash session is started successfully.",
        "keypresses": ["<Enter>", "b", "a", "s", "h", "<Enter>"],
        "next_step": "see below"
      }

  Example sequences:
    ["l", "s", "<Enter>"]
    ["<Ctrl-c>"]
    ["e", "c", "h", "o", "<Space>", "'", "H", "e", "l", "l", "o", "'", "<Enter>"]
    ["<Alt-f>", "f", "o", "o", "<Enter>"]
    ["<Shift-a>", "A", "<Enter>"]

  ------------------------------------------------------------------------------------

  ------------------------------------------------------------------------------------
  User's Mission:
  ------------------------------------------------------------------------------------

  The user's end goal is to:

  #{mission}

  Are we on the right track? Use scratchpad to verify and plan the next steps.
  ------------------------------------------------------------------------------------

  ------------------------------------------------------------------------------------
  Scratchpad history (older entries are at the top, new entries at the bottom):
  ------------------------------------------------------------------------------------

  #{scratchpad}
  <new_scratchpad will be here>
  ------------------------------------------------------------------------------------

  The current state of the terminal follows. Analyze the content and cursor position to provide the next key presses.
  
  ------------------------------------------------------------------------------------
       Terminal Window (80x40)
       Cursor Position: (#{cursor_position[:x]}, #{cursor_position[:y]})
       -------------------------------------------------------------------------------
  #{terminal_content}
       -------------------------------------------------------------------------------

  response =
  ```json
  PROMPT
end

def valid_llm_response?(response)
  response.is_a?(Hash) &&
    response.key?('reasoning') &&
    response.key?('keypresses') &&
    response.key?('mission_complete') &&
    response.key?('new_scratchpad') &&
    response.key?('next_step') &&
    response['keypresses'].is_a?(Array)
end

# --- Main Execution ---
logger = Logger.new(LOG_FILE, 'daily')
logger.level = Logger::DEBUG

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: ruby script.rb [options]"
  opts.on("-a", "--accumulate", "Accumulate responses for subsequent prompts") do |a|
    options[:accumulate] = a
  end
end.parse!

scratchpad = ""
session_name = "pllm-#{SecureRandom.uuid}"
mission_complete = false
history = ""

begin
  create_tmux_session(session_name, logger)

  until mission_complete
    terminal_state = capture_tmux_output(session_name)
    prompt = build_prompt(MISSION, scratchpad, terminal_state, history, options)
    system("clear")
    puts prompt
    logger.info("Sending prompt to LLM")

    query_llm(LLAMA_API_ENDPOINT, prompt, history, terminal_state, options, logger) do |json_response|
      begin
        parsed_response = JSON.parse(json_response)
        if valid_llm_response?(parsed_response)
          reasoning = parsed_response['reasoning']
          keypresses = parsed_response['keypresses'] || []
          mission_complete = parsed_response['mission_complete']
          new_scratchpad = parsed_response['new_scratchpad']
          next_step = parsed_response['next_step']

          logger.info("LLM Reasoning: #{reasoning}")
          logger.info("LLM Keypresses: #{keypresses.join(', ')}")
          logger.info("Mission Complete? #{mission_complete}")

          if keypresses.empty? && !mission_complete
            logger.warn("No keypresses provided, skipping this iteration.")
            next
          end

          # Update scratchpad with cursor position
          timestamp = Time.now.utc.iso8601
          cursor_position = terminal_state[:cursor]
          scratchpad += "\n[#{timestamp}] New Scratchpad Entry\nCursor Position: (#{cursor_position[:x]}, #{cursor_position[:y]}) - #{new_scratchpad}\nKeypresses: #{keypresses.join(', ')}\nMission Complete: #{mission_complete}\nReasoning: #{reasoning}\nNext Step: #{next_step}\n\n"

          # Execute keypresses
          unless keypresses.empty?
            send_keys_to_tmux(session_name, keypresses, logger)
            sleep(2)  # Allow some time for command execution

            # Check if the terminal state has changed as expected after keypresses
            new_state = capture_tmux_output(session_name)
            logger.info("Post-Keypress Terminal State: #{new_state[:content][0..100]}...")

            # Here you could add checks for expected output
          end

          # Break the loop if mission_complete is true
          break if mission_complete
        else
          puts "Invalid LLM response format. Please check the response for errors."
          logger.error("Invalid LLM response format: #{parsed_response}")
        end
      rescue JSON::ParserError => e
        puts "Failed to parse LLM response. Please check the response for errors."
        logger.error("Failed to parse LLM response: #{e.message}")
      end
    end
  end
rescue Interrupt
  puts "\nInterrupted. Cleaning up..."
ensure
  cleanup_tmux_session(session_name, logger)
end
