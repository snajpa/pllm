require 'securerandom'
require 'net/http'
require 'uri'
require 'json'
require 'open3'
require 'time'
require 'logger'
require 'optparse'
require 'timeout'
require 'tempfile'

# --- Constants ---
WINDOW_X = 80
WINDOW_Y = 24
LLAMA_API_ENDPOINT = 'http://localhost:8081/v1/completions'
DEFAULT_MISSION = '

There\'s a Linux dev machine reachable through SSH at snajpa@172.16.106.12.

On that machine, in /home/snajpa/linux/ directory, is a clone of vpsAdminOS Linux fork.

Start from a branch named "vpsadminos-6.12", which denotes it\'s based on 6.12 vanilla kernel.

There\'s about ~50 patches on top of some 6.12.x kernel and we need to port these on top of current linus/master (remote_name/branch_name).

The goal is to have a branch based on linus/master with all the patches from vpsadminos-6.12 branch in the end.

It\'s probably the best to start with a fresh branch based on linus/master and then cherry-pick patches from vpsadminos-6.12, but the user is not sure about the best approach nor the exact steps.

The target branch should be named "vpsadminos-6.13".

Pro-tips:
- You can use "git log --oneline" and Space to scroll through the log quicker.
- The PS1 has been enhanced to indicate current git branch and status.
'
LOG_FILE = 'pllm.log'

# --- Helper Functions ---
def create_tmux_session(session_name, logger)
  system("tmux", "new-session", "-d", "-s", session_name, "-n", "main")
  system("tmux", "set-option", "-t", session_name, "status", "off")
  system("tmux", "resize-pane", "-t", session_name, "-x", "#{WINDOW_X}", "-y", "#{WINDOW_Y}")
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
    sleep 0.05
    #puts "Sent key: #{key}"
    #sleep(0.5)  # Small delay between key presses
  end
end

def capture_tmux_output(session_name)
  stdout, stderr, status = Open3.capture3("tmux capture-pane -pt #{session_name}")
  raise "TMux capture error: #{stderr}" unless status.success?

  lines = stdout.lines.map(&:chomp)
  normalized_output = lines.map { |line| line.ljust(WINDOW_X)[0,WINDOW_X] }
  normalized_output += Array.new(WINDOW_Y - normalized_output.size, ' ' * WINDOW_X) if normalized_output.size < WINDOW_Y

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
end

def edit_response_with_timeout(json_response, timeout)
  editor = ENV['EDITOR']
  raise 'EDITOR environment variable not set' unless editor
  puts "\nPress any key to open the editor for response editing..."

  IO.select([$stdin], nil, nil, timeout) do
    c = $stdin.getc
    if c
      temp_file = Tempfile.new('llm_response')
      temp_file.write(JSON.pretty_generate(JSON.parse(json_response), array_nl: '', indent: ''))
      temp_file.close
      
      puts "\nOpening editor for response editing..."
      status = system("#{editor} #{temp_file.path}")

      if !status
        puts "Editor exited with an error. Using original response."
        return json_response
      end

      if File.exist?(temp_file.path) && File.size(temp_file.path) > 0
        edited_content = File.read(temp_file.path)
        begin
          JSON.parse(edited_content)
          return edited_content
        rescue JSON::ParserError => e
          puts "Warning: The edited response is not valid JSON. Using original response."
          return json_response
        ensure
          temp_file.unlink
        end
      else
        puts "File not found. Using original response."
        return json_response
      end
    end
  end
  json_response
end

def query_llm(endpoint, prompt, terminal_state, options, logger, &block)
  uri = URI.parse(endpoint)
  request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
  request.body = {
    prompt: prompt,
    max_tokens: 384,
    repeat_penalty: 1.1,
    repeat_last_n: 128,
    #top_p: 0.95,
    #top_k: 20,
    stream: true,
    temperature: 0.3
  }.to_json

  json_found = false
  full_response = ""

  begin
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
                content.each_char do |char|
                  case char
                  when '{'
                    bracket_count += 1
                    current_json += char
                  when '}'
                    bracket_count -= 1
                    current_json += char
                    if bracket_count == 0 && !current_json.strip.empty?
                      # Found a complete JSON
                      json_found = true
                      if options[:edit]
                        edited_json = edit_response_with_timeout(current_json, options[:timeout])
                        block.call(edited_json)
                      else
                        block.call(current_json)
                      end
                      return
                    end
                  else
                    current_json += char unless (bracket_count == 0 && char.strip.empty?)
                  end
                end
              end
            end
          rescue JSON::ParserError => e
            logger.error("Error parsing chunk: #{e}")
            return full_response
          end
        end
      end
    end

    # If we reach here, no complete JSON was found
    if !json_found
      # Optionally edit the full_response before returning
      if options[:edit]
        edited = edit_response_with_timeout(full_response, options[:timeout])
        return edited
      else
        return full_response
      end
    end

  rescue StandardError => e
    logger.error("Error: #{e}")
    # Return whatever was accumulated so far
    if options[:edit]
      edited = edit_response_with_timeout(full_response, options[:timeout])
      return edited
    else
      return full_response
    end
  end
end

def build_prompt(mission, history, terminal_state, options, iteration_n)
  cursor_position = terminal_state[:cursor]
  terminal_content = terminal_state[:content]

  prompt = <<~PROMPT
  You are a helpful AI system designed to suggest key presses to accomplish a mission on a console interface.

  The system has started a new session for you in a terminal emulator. You will be provided with the current terminal state, mission, and instructions to guide the user through the mission.

  Please analyze the terminal state, mission, and instructions to suggest key presses that will help the user progress towards completing the mission.

  Mission history contains new_scratchpad and next_step keys generated by you in previous iterations and it is up to you to update it with your planning, progress, and any issues encountered, as you see fit.

  Note: 
  - History is compacted periodically by the system every #{options[:history_limit]} entries
  - In order to preserve your progress (especially involving on any lists of things), you must place that information in new_scratchpad or next_step.
  - This also implies that you always have #{options[:history_limit]} iterations to explore a single coherent path of actions.
  - Currently you have #{if options[:history_limit] > 1 then (options[:history_limit] - (iteration_n % options[:history_limit])) else 0 end} iterations to finish your current line of thought.
  - Your output will be cut after 384 tokens for each iteration.

  Instructions for operating the terminal session:
  - You are guiding the user through an interactive terminal session. Carefully identify the current state and provide key presses to progress accordingly.
  - The terminal output is always prepended with line numbers by the system for your convenience. These are not part of the actual terminal content.
  - The terminal window size is #{WINDOW_X} columns by #{WINDOW_Y} rows.
  - The cursor position is indicated by the block symbol '█'.
  - Avoid batching multiple commands, especially when a command can invoke an interactive editor or a pager.
  - Ensure proper navigation in interactive programs like editors, pagers, etc.
  - After program completes, shell returns back the PS1 prompt. Do not get confused by old history in the console.
  - If an output of a command calls a pager, navigate the user through the pager to show all the relevant parts of the output, don't be satisfied with one run if there might be more important data below.
  - The block symbol '█' indicates the current cursor position.

  Instructions for issuing keypresses:
  - On each step, create a plan and then provide the key presses needed.
  - Each element in "keypresses" array is a single keypress.
  - Format response in valid JSON only, example below.

  - Normal characters: "a", "b", "c", "A", "B", "C", "1", "2", ".", " ", etc.
  - Special named keys: "Enter", "Tab", "BSpace", "Escape", "Up", "Down", "Left", "Right", "Home", "End", "PageUp", "PageDown", "Insert", "Delete"
  - Ctrl keys: Use C- notation for Ctrl keys. For example, "C-c" for Ctrl+c, "C-r" for Ctrl+r, etc.
  - Alt keys: Use M- notation for Alt keys. For example, "M-a" for Alt+a, "M-x" for Alt+x, etc.
  - Send uppercase letters directly as uppercase. No need for Shift notation.
  - If you need multiple steps, output them in a single "keypresses" array, one key per element.
  - Example sequences:
      ["l", "s", "Enter"]
      ["C-c"]
      ["e", "c", "h", "o", " ", "'", "H", "e", "l", "l", "o", "'", "Enter"]
  - Example response format:
  ```json
  {"reasoning":"(ultra-brief reasoning)","mission_complete":false,"new_scratchpad":"(something about verifying completion of previous step)","keypresses":["Enter","e","x","a","m","p","l","e","Enter"],"next_step":"(brief description of next step and general direction)"}
  ```

  -----------------------------------------------------------------------------------
  Mission history (older entries are at the top, new entries at the bottom):
  -----------------------------------------------------------------------------------

  #{history}
  <new entry with cursor position, terminal state, new_scratchpad, keypresses and next_step will be added here>
  -----------------------------------------------------------------------------------

  -----------------------------------------------------------------------------------
  User's Mission:
  -----------------------------------------------------------------------------------
  The user's end goal is to:
  --
  #{mission}
  --
  Are we on the right track? Use scratchpad_new and next_step to verify and plan the next steps.  
  -----------------------------------------------------------------------------------

  -----------------------------------------------------------------------------------
  CURRENT TERMINAL STATE FOR YOUR ANALYSIS:
  -----------------------------------------------------------------------------------
     | Terminal window wize: (#{WINDOW_X}, #{WINDOW_Y})
     | Current cursor position: (#{cursor_position[:x]}, #{cursor_position[:y]})
     --------------------------------------------------------------------------------
  #{terminal_content}
  -----------------------------------------------------------------------------------

  Your response based on the current terminal state, mission, and mission history:
  ```json
  PROMPT
end

def build_summarization_prompt(full_log, mission, terminal_state)
  cursor_position = terminal_state[:cursor]
  terminal_content = terminal_state[:content]

  <<~SUMMARY_PROMPT
  You are tasked with summarizing a log of a tool called 'pllm' which helps the user accomplish a mission by providing keypress suggestions into user's terminal.

  The log contains detailed information about the interactions between the user and the AI system during the mission.

  Your output should serve as one summarizing entry in the Full log for the next iteration of the 'pllm' tool run.

  Extract the overall plan, substeps of the plan, steps already completed.

  Make sure to bring over solutions to any problems/errors encountered.

  Also bring over any previous summaries of older entries in the history.

  If there are any data relevant to the mission, make sure to always bring them over to the new summary too.

  Pay close attention to any repetitive behavior which doesn't seem to be making progress. Deduce the reason and suggest a solution.
  
  Please provide a condensed summary of the current status based on log below.

  Work in reverse chronological order, starting from the most recent entry. Your output will be cut after 384 tokens.

  ------------------------------------------------------------------------------------
  Full Log:
  ------------------------------------------------------------------------------------
  #{full_log}
  ------------------------------------------------------------------------------------
  
  -----------------------------------------------------------------------------------
  Current terminal state after the last iteration:
  -----------------------------------------------------------------------------------
     | Terminal window wize: (#{WINDOW_X}, #{WINDOW_Y})
     | Current cursor position: (#{cursor_position[:x]}, #{cursor_position[:y]})
     --------------------------------------------------------------------------------
  #{terminal_content}
  -----------------------------------------------------------------------------------

  Respond only with bullet points, not full sentences. Make sure to use a new line after each bullet point.

  Produce the summarized condensed version right after summary =. Once you're done with summary =, we're done.

  REPORT
  ======

  summary =
  SUMMARY_PROMPT
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

options = {:accumulate => false, :edit => false, :timeout => 5, :history_limit => 15, :mission => DEFAULT_MISSION}
OptionParser.new do |opts|
  opts.banner = "Usage: ruby script.rb [options]"
  opts.on("-a", "--accumulate", "Accumulate responses for subsequent prompts") do |a|
    options[:accumulate] = a
  end
  opts.on("-e", "--edit[=SECONDS]", Integer, "Allow editing of LLM response before use, with optional timeout in seconds (default 5)") do |e|
    options[:edit] = true
    options[:timeout] = e || 5
  end
  opts.on("-l", "--history-limit=LIMIT", Integer, "Limit the number of entries in the scratchpad history (default 10)") do |l|
    options[:history_limit] = l || 15
  end
  opts.on("-m", "--mission=options[:mission]_FILE", "Load mission from a file") do |m|
    mission = File.read(m)
    options[:mission] = mission
  end
end.parse!

uuid = SecureRandom.uuid
session_name = "pllm-#{uuid[0,8]}"
history = ""
history_length = 0
iteration = 0
mission_complete = false

logger.formatter = proc do |severity, datetime, progname, msg|
  "[#{session_name}] #{datetime} - #{severity}: #{msg}\n"
end

begin
  logger.info("")
  logger.info("Starting PLM session: #{session_name}")
  create_tmux_session(session_name, logger)

  until mission_complete
    iteration += 1
    terminal_state = capture_tmux_output(session_name)
    prompt = build_prompt(options[:mission], history, terminal_state, options, iteration)
    system("clear")
    logger.info("Running iteration #{iteration}")
    puts prompt

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

          logger.info("\n#{prompt}\n{#{json_response}}")

          # Update scratchpad with cursor position
          timestamp = Time.now.utc.iso8601
          cursor_position = terminal_state[:cursor]
          history += "\n[#{timestamp}]\nCursor Position: (#{cursor_position[:x]}, #{cursor_position[:y]})\nTerminal State:\n#{terminal_state[:content]}\nScratchpad entry: #{new_scratchpad}\nKeypresses: #{keypresses_fmt}\nNext Step: #{next_step}\n\n"
          history_length += 1

          unless keypresses.empty?
            send_keys_to_tmux(session_name, keypresses, logger)
          end

          sleep 2 # Give time for the shell to process the key presses

          new_state = capture_tmux_output(session_name)
          logger.info("Post-Keypress Terminal State:\n#{new_state[:content]}")

          # Update history length and condense if needed
          if history_length >= options[:history_limit]
            logger.info("Summarizing history due to history limit")
            summarization_prompt = build_summarization_prompt(history, options[:mission], new_state)
            puts summarization_prompt
            summary = query_llm(LLAMA_API_ENDPOINT, summarization_prompt, terminal_state, options, logger)
            history = "\nSummary of older entries:\n#{summary}\n\n"
            history_length = 0

            logger.info("Summarized history:\n#{history}")
          end

          break if mission_complete
        else
          puts "Invalid LLM response format. Please check the response for errors."
          history += "\n[#{Time.now.utc.iso8601}] System Error\nYour response format was invalid: #{parsed_response}\n\n"
          logger.error("Invalid LLM response format: #{parsed_response}")
        end
      rescue JSON::ParserError => e
        puts "Failed to parse LLM response. Please check the response for errors."
        history += "\n[#{Time.now.utc.iso8601}] System Error\nFailed to parse your response: #{e.message} - the raw response was: #{json_response}\n\n"
        logger.error("Failed to parse LLM response: #{e.message}")
      end
    end
  end
rescue Interrupt
  puts "\nInterrupted. Cleaning up..."
ensure
  cleanup_tmux_session(session_name, logger)
end
