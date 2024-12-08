require 'net/http'
require 'json'
require 'open3'
require 'fileutils'
require 'time'

# --- CONSTANTS ---

# LLaMA.cpp API Endpoint
LLAMA_API_URL = 'http://localhost:8080/v1/completions'

# Mission Description
MISSION = <<~MISSION
  Your mission is to execute the tasks described and take notes in an organized manner.
  You have two terminal windows available:
  1. **Workspace** - For running commands and executing code.
  2. **Notes** - For writing observations, conclusions, and key points.

  You can send any keypresses to these windows. Your goal is to achieve the mission with the fewest steps possible.
MISSION

# Context Introduction
INTRO = <<~INTRO
  You have two windows in a `tmux` session:
  - **Window 0**: Workspace where commands are executed.
  - **Window 1**: Notes where you write down important points.

  You can send keypresses and commands to these windows. Make efficient decisions to complete the mission.
INTRO

# Number of Iterations to Run
MAX_ITERATIONS = 20

# Tmux Session Name
SESSION_NAME = 'llm_mission'

# Path to Capture Output Files
WORKSPACE_CAPTURE = '/tmp/workspace_output.txt'
NOTES_CAPTURE = '/tmp/notes_output.txt'

# Log Directory Setup
LOG_DIR_BASE = 'logs'
CURRENT_RUN_LINK = 'current_run'

# --- FUNCTIONS ---

# Initialize tmux session with two windows
def setup_tmux_session
  system("tmux new-session -d -s #{SESSION_NAME} -n workspace")
  system("tmux new-window -t #{SESSION_NAME} -n notes")
  puts "[INFO] Tmux session '#{SESSION_NAME}' initialized with two windows."
end

# Create log directory for the current run
def setup_log_directory
  timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
  log_dir = File.join(LOG_DIR_BASE, "run_#{timestamp}")
  FileUtils.mkdir_p(log_dir)
  FileUtils.rm_f(CURRENT_RUN_LINK)
  FileUtils.ln_s(log_dir, CURRENT_RUN_LINK)
  puts "[INFO] Log directory created at #{log_dir}"
  log_dir
end

# Capture the content of the workspace and notes windows
def capture_tmux_windows
  system("tmux capture-pane -pt #{SESSION_NAME}:0 > #{WORKSPACE_CAPTURE}")
  system("tmux capture-pane -pt #{SESSION_NAME}:1 > #{NOTES_CAPTURE}")
end

# Read the captured content from files
def read_captured_content
  workspace_content = File.read(WORKSPACE_CAPTURE)
  notes_content = File.read(NOTES_CAPTURE)
  [workspace_content, notes_content]
end

# Send keypresses to a specific tmux window
def send_keypresses(window, commands)
  system("tmux send-keys -t #{SESSION_NAME}:#{window} \"#{commands}\" Enter")
end

# Query the LLaMA API with the mission, context, and window contents
def query_llm(mission, intro, workspace, notes, log_dir, iteration)
  prompt = <<~PROMPT
    #{mission}

    #{intro}

    --- Workspace Window Content ---
    #{workspace}

    --- Notes Window Content ---
    #{notes}

    Based on the mission, decide the next keypresses to send to each window. Format your response as:
    {"workspace": "<keypresses for workspace>", "notes": "<keypresses for notes>"}.
  PROMPT

  # Log the prompt to a file
  prompt_log_file = File.join(log_dir, "iteration_#{iteration}_prompt.txt")
  File.write(prompt_log_file, prompt)
  puts "[INFO] Prompt saved to #{prompt_log_file}"

  # Display the prompt on stdout
  system('clear')
  puts "========== PROMPT =========="
  puts prompt
  puts "============================"

  uri = URI(LLAMA_API_URL)
  headers = { 'Content-Type' => 'application/json' }
  body = {
    model: 'llama',
    prompt: prompt,
    max_tokens: 200,
    stream: true
  }

  # Send the request and handle streaming response
  request = Net::HTTP::Post.new(uri, headers)
  request.body = body.to_json

  puts "\n========== LLM OUTPUT =========="
  response_log_file = File.join(log_dir, "iteration_#{iteration}_output.txt")
  File.open(response_log_file, 'w') do |file|
    Net::HTTP.start(uri.hostname, uri.port) do |http|
      http.request(request) do |res|
        res.read_body do |chunk|
          json = JSON.parse(chunk) rescue nil
          if json && json['choices']
            text = json['choices'][0]['text']
            print text
            file.write(text)
          end
        end
      end
    end
  end
  puts "\n============================"
  puts "[INFO] LLM Output saved to #{response_log_file}"

  # Read and return the saved response
  JSON.parse(File.read(response_log_file))
rescue StandardError => e
  puts "[ERROR] LLaMA API request failed: #{e.message}"
  '{"workspace": "", "notes": ""}'
end

# Main Loop
def run_mission
  setup_tmux_session
  log_dir = setup_log_directory

  MAX_ITERATIONS.times do |iteration|
    puts "\n[INFO] Starting Iteration #{iteration + 1}..."

    # Capture current window contents
    capture_tmux_windows
    workspace_content, notes_content = read_captured_content

    # Get the LLM's decision
    llm_response = query_llm(MISSION, INTRO, workspace_content, notes_content, log_dir, iteration + 1)
    commands = llm_response.is_a?(Hash) ? llm_response : JSON.parse(llm_response)
    workspace_cmd = commands['workspace'] || ''
    notes_cmd = commands['notes'] || ''

    # Dispatch the commands to the appropriate tmux windows
    send_keypresses(0, workspace_cmd) unless workspace_cmd.empty?
    send_keypresses(1, notes_cmd) unless notes_cmd.empty?

    # Wait for commands to execute before the next iteration
    sleep(2)

    puts "[INFO] Iteration #{iteration + 1} complete."
  end

  puts "\n[INFO] Mission execution finished."
end

# --- ENTRY POINT ---
run_mission
