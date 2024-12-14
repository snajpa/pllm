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
MISSION = '

There\'s a Linux dev machine reachable through SSH at root@172.16.106.12.

On that machine, in /root/linux directory, is a clone of vpsAdminOS Linux fork.

Start from a branch named "vpsadminos-6.12", which denotes it\'s based on 6.12 vanilla kernel.

There\'s about ~50 patches on top of some 6.12.x kernel and we need to port these on top of current linus/master (remote_name/branch_name).

The goal is to have a branch based on linus/master with all the patches from vpsadminos-6.12 branch in the end.

It\'s probably the best to start with a fresh branch based on linus/master and then cherry-pick patches from vpsadminos-6.12, but the user is not sure about the best approach nor the exact steps.

The target branch should be named "vpsadminos-6.13".

'
LOG_FILE = 'pllm.log'

# --- Helper Functions ---
def create_tmux_session(session_name, logger)
  system("tmux", "new-session", "-d", "-s", session_name, "-n", "main")
  system("tmux", "set-option", "-t", session_name, "status", "off")
  system("tmux", "resize-pane", "-t", session_name, "-x", "80", "-y", "40")
  logger.info("Created TMux session #{session_name} with window size 80x40")
  system("tmux", "send-keys", "-t", session_name, "clear", "Enter")
  sleep(1) # Give time for the shell to initialize
end

def send_keys_to_tmux(session_name, keys, logger)
  keys.each do |key|
    # Send keys to tmux exactly as provided by the LLM.
    # Using array form of system call to avoid shell parsing.
    if key == " "
      key = "Space"
    end
    system("tmux", "send-keys", "-t", session_name, "--", key)
    logger.info("Sending key: #{key}")
    sleep 0.05
    #puts "Sent key: #{key}"
    #sleep(0.5)  # Small delay between key presses
  end
end

def capture_tmux_output(session_name)
  stdout, stderr, status = Open3.capture3("tmux capture-pane -pt #{session_name}")
  raise "TMux capture error: #{stderr}" unless status.success?

  lines = stdout.lines.map(&:chomp)
  normalized_output = lines.map { |line| line.ljust(80)[0,80] }
  normalized_output += Array.new(40 - normalized_output.size, ' ' * 80) if normalized_output.size < 40

  cursor_position = get_cursor_position(session_name)

  content_lines = normalized_output.map.with_index do |line, idx|
    line_with_number = "#{idx.to_s.rjust(2)} |#{line}"
    if idx == cursor_position[:y]
      begin
        line_with_number[cursor_position[:x] + 4] = '█'
      rescue
        # In case the cursor position is out of range
      end
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
  system("tmux", "kill-session", "-t", session_name)
  logger.info("Killed TMux session #{session_name}")
end

def query_llm(endpoint, prompt, terminal_state, options, logger, &block)
  uri = URI.parse(endpoint)
  request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
  request.body = {
    prompt: prompt,
    max_tokens: 768,
    #repeat_penalty: 1.1,
    #top_p: 0.98,
    #top_k: 10,
    stream: true,
    temperature: 0.6
  }.to_json

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

def build_prompt(mission, scratchpad, terminal_state, options)
  cursor_position = terminal_state[:cursor]
  terminal_content = terminal_state[:content]

  prompt = <<~PROMPT
  You are a helpful AI system designed to suggest key presses to accomplish a mission on a console interface.

  The system has started a new session for you in a terminal emulator. You will be provided with the current terminal state, mission, and instructions to guide the user through the mission.

  Please analyze the terminal state, mission, and instructions to suggest key presses that will help the user progress towards completing the mission.

  Mission history contains new_scratchpad and next_step keys generated by you in previous iterations and it is up to you to update it with your planning, progress, and any issues encountered, as you see fit.

  Note: 
  - The terminal output has been prepended with line numbers by the system to help track position. These are not part of the actual terminal content.
  - The block symbol '█' indicates the current cursor position.

  -----------------------------------------------------------------------------------
  Instructions:
  -----------------------------------------------------------------------------------
  - On each step, create a plan and then provide the key presses needed.
  - Each element in "keypresses" array is a single keypress.

  - Normal characters: "a", "b", "c", "A", "B", "C", "1", "2", ".", " ", etc.
  - Special named keys: "Enter", "Tab", "BSpace", "Escape", "Up", "Down", "Left", "Right", "Home", "End", "PageUp", "PageDown", "Insert", "Delete"
  - Ctrl keys: Tmux uses C- notation for Ctrl keys. For example, "C-a" for Ctrl+a, "C-x" for Ctrl+x, etc.
  - Alt keys: Tmux uses M- notation for Alt keys. For example, "M-a" for Alt+a, "M-x" for Alt+x, etc.
  - Send uppercase letters directly as uppercase. No need for Shift notation.
  - If you need multiple steps, output them in a single "keypresses" array, one key per element.
  - Example sequences:
      ["l", "s", "Enter"]
      ["C-c"]
      ["e", "c", "h", "o", " ", "'", "H", "e", "l", "l", "o", "'", "Enter"]

  - Format response in valid JSON only with the following keys:
    ```json
      {
        "reasoning": "I am suggesting these key presses to start a new bash session.",
        "mission_complete": false,
        "new_scratchpad": "Verify the new bash session is started successfully.",
        "keypresses": ["Enter", "b", "a", "s", "h", "Enter"],
        "next_step": "Analyze the prompt format for future guidance."
      }
    ```
  -----------------------------------------------------------------------------------


  -----------------------------------------------------------------------------------
  Mission history (older entries are at the top, new entries at the bottom):
  -----------------------------------------------------------------------------------

  #{scratchpad}
  <new_scratchpad will be here>
  -----------------------------------------------------------------------------------

  -----------------------------------------------------------------------------------
  User's Mission:
  -----------------------------------------------------------------------------------
  The user's end goal is to:

  #{mission}

  Are we on the right track? Use scratchpad to verify and plan the next steps.
  -----------------------------------------------------------------------------------

  The current state of the terminal follows:
  
  -----------------------------------------------------------------------------------
     | Terminal window wize: (80, 40)
     | Current cursor position: (#{cursor_position[:x]}, #{cursor_position[:y]})
     --------------------------------------------------------------------------------
  #{terminal_content}
     --------------------------------------------------------------------------------
  -----------------------------------------------------------------------------------

  Please provide key presses to guide the user to the next step.

  ===================================================================================


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

begin
  create_tmux_session(session_name, logger)

  until mission_complete
    terminal_state = capture_tmux_output(session_name)
    prompt = build_prompt(MISSION, scratchpad, terminal_state, options)
    system("clear")
    puts prompt
    logger.info("Sending prompt to LLM")

    query_llm(LLAMA_API_ENDPOINT, prompt, terminal_state, options, logger) do |json_response|
      begin
        parsed_response = JSON.parse(json_response)
        if valid_llm_response?(parsed_response)
          reasoning = parsed_response['reasoning']
          keypresses = parsed_response['keypresses'] || []
          keypresses_fmt = keypresses.map { |key| "\"#{key}\"" }.join(', ')
          mission_complete = parsed_response['mission_complete']
          new_scratchpad = parsed_response['new_scratchpad']
          next_step = parsed_response['next_step']

          logger.info("LLM Reasoning: #{reasoning}")
          logger.info("LLM Keypresses: #{keypresses_fmt}")
          logger.info("Mission Complete? #{mission_complete}")

          if keypresses.empty? && !mission_complete
            logger.warn("No keypresses provided, skipping this iteration.")
            next
          end

          # Update scratchpad with cursor position
          timestamp = Time.now.utc.iso8601
          cursor_position = terminal_state[:cursor]
          scratchpad += "\n[#{timestamp}]\nCursor Position: (#{cursor_position[:x]}, #{cursor_position[:y]})\nScratchpad entry: #{new_scratchpad}\nKeypresses: #{keypresses_fmt}\nMission Complete: #{mission_complete}\nReasoning: #{reasoning}\nNext Step: #{next_step}\n\n"

          unless keypresses.empty?
            send_keys_to_tmux(session_name, keypresses, logger)
            sleep(2) # Allow some time for command execution
            new_state = capture_tmux_output(session_name)
            logger.info("Post-Keypress Terminal State: #{new_state[:content][0..100]}...")
          end

          break if mission_complete
        else
          puts "Invalid LLM response format. Please check the response for errors."
          scratchpad += "\n[#{Time.now.utc.iso8601}] System Error\nYour response format was invalid: #{parsed_response}\n\n"
          logger.error("Invalid LLM response format: #{parsed_response}")
        end
      rescue JSON::ParserError => e
        puts "Failed to parse LLM response. Please check the response for errors."
        scratchpad += "\n[#{Time.now.utc.iso8601}] System Error\nFailed to parse your response: #{e.message} - the raw response was: #{json_response}\n\n"
        logger.error("Failed to parse LLM response: #{e.message}")
      end
    end
  end
rescue Interrupt
  puts "\nInterrupted. Cleaning up..."
ensure
  cleanup_tmux_session(session_name, logger)
end
