#!/usr/bin/env ruby
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

require './lib/llm'
require './lib/tmux'

# --- Constants ---
REEVAL_TIMES = 3
EDIT_TIMEOUT = 5
HISTORY_LIMIT = 5
WINDOW_X = 120
WINDOW_Y = 30
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

def build_main_prompt(mission, history, console_state, options, iteration_n)
  cursor_position = console_state[:cursor]
  console_content = console_state[:content]

  prompt = <<~PROMPT
  You are a helpful AI system designed to suggest key presses to accomplish a mission on a console interface.

  The system has started a new session for the user and you in a console emulator. You will be provided with the current console state, mission, and instructions to guide the user through the mission.

  For each iteration, you will receive the current console state, mission, and history of the user's actions. You will need to analyze the information and suggest key presses to help the user progress towards the mission.

  Instructions for achieving the user's mission:
  - You are guiding the user through an interactive console session.
  - Carefully identify the current state of the mission, plan the next steps, and suggest key presses to help the user progress.
  - At the beginning of the mission, it is a good idea to start by thinking about the overall plan and breaking it down into smaller steps, no need to issue key presses immediately.
  - It is a good idea to note how the system prompt (PS1) looks like and take a note when it changes.

  Notes about the system you're operating in: 
  - History is compacted periodically by the system every #{options[:history_limit]} entries
  - In order to preserve your progress (especially involving on any lists of things), you must place that information in new_scratchpad or next_step.
  - This also implies that you always have #{options[:history_limit]} iterations to explore a single coherent path of actions.
  - Currently you have #{if options[:history_limit] > 1 then (options[:history_limit] - (iteration_n % options[:history_limit])) else 0 end} iterations to finish your current line of thought.

  Instructions for operating the console session:
  - The console output is always prepended with line numbers by the system for your convenience. These are not part of the actual console content.
  - The console window size is #{WINDOW_X} columns by #{WINDOW_Y} rows.
  - There are no scrollbars, so the console content is limited to the visible area.
  - The console content is updated in real-time, and you can issue key presses to interact with the console.
  - The cursor position is indicated by the block symbol '█'.
  - Avoid batching multiple commands. Issue one command at a time and wait for the console to update.
  - Expect when a command can invoke an interactive editor or a pager.
  - Ensure proper navigation in interactive programs like editors, pagers, etc.
  - Always ensure you are working with the latest shell prompt, otherwise you tend to modify older content, which is bad.
  - Beware if a command invokes a pager, navigate the user through the pager to show all the relevant parts of the output, don't be satisfied with one run if there might be more important data below.
  - Asses whether the user is in a pager or an editor and act accordingly.
  - The block symbol '█' indicates the current cursor position.

  Instructions for issuing keypresses:
  - On each step, create a plan and then provide the key presses needed.
  - Normal characters: "a", "b", "c", "A", "B", "C", "1", "2", ".", " ", "\"", etc.
  - Special named keys, read carefully, use literally: "Enter", "Tab", "BSpace", "Escape", "Up", "Down", "Left", "Right", "Home", "End", "PageUp", "PageDown", "Insert", "Delete"
  - Ctrl keys: Use C- notation for Ctrl keys. For example, "C-c" for Ctrl+c, "C-r" for Ctrl+r, etc.
  - Alt keys: Use M- notation for Alt keys. For example, "M-a" for Alt+a, "M-x" for Alt+x, etc.
  - Send uppercase letters directly as uppercase. No need for Shift notation.
  - If you need multiple steps, output them in a single "keypresses" array, one key per element.
  - You are forbidden to use "C-d". If you need to exit a shell, use "C-c" to interrupt the current process and then "exit" to exit the shell.
  - If you intend there to be a space between command and/or arguments, spell it out as "Space".
  - If you need to issue a command, provide the key presses to type the command and then "Enter" to execute it.
  - No command chaining in one iteration, only one command per iteration.
  - Example sequences:
    - ["l", "s", "Enter"]
    - ["C-c"]
    - ["e", "c", "h", "o", " ", "'", "H", "e", "l", "l", "o", "'", "Enter"]

  Response format:
  - Each element in "keypresses" array is a single keypress.
  - Format response in valid JSON only, example below.
  - Example:
  ```json
  {
    "reasoning": "(ultra-brief reasoning)",
    "mission_complete": false,
    "new_scratchpad": "(something about verifying completion of previous step)",
    "keypresses": ["Enter", "e", "x", "a", "m", "p", "l", "e", "Enter"],
    "next_step": "(brief description of next step and general direction)"
  }
  ```

  -----------------------------------------------------------------------------------
  Mission history (older entries are at the top, new entries at the bottom):
  -----------------------------------------------------------------------------------

  #{history}
  <new entry with cursor position, console state, new_scratchpad, keypresses and next_step will be added here>
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
  CURRENT CONSOLE STATE FOR YOUR ANALYSIS:
  -----------------------------------------------------------------------------------
     | Console window wize: (#{WINDOW_X}, #{WINDOW_Y})
     | Current cursor position: (#{cursor_position[:x]}, #{cursor_position[:y]})
     --------------------------------------------------------------------------------
  #{console_content}
  -----------------------------------------------------------------------------------

  Your suggestions for this iteration:
  ```json
  PROMPT
end

def build_summarization_prompt(full_log, mission, console_state)
  cursor_position = console_state[:cursor]
  console_content = console_state[:content]

  <<~SUMMARY_PROMPT
  You are tasked with summarizing a log for a LLM agent called 'pllm'. The agent's goal is to help the user accomplish a mission by providing keypress suggestions into user's console.

  The log contains detailed information about the interactions between the user and the AI system during the mission.

  Your output should serve as one summarizing entry in the Full log for the next iteration of the 'pllm' tool run.

  Extract the overall plan, substeps of the plan, steps already completed.

  Make sure to bring over solutions to any problems/errors encountered.

  Also bring over any previous summaries of older entries in the history.

  If there are any data relevant to the mission, make sure to always bring them over to the new summary too.

  Pay close attention to any repetitive behavior which doesn't seem to be making progress. Deduce the reason and suggest a solution.
  
  Provide a condensed summary of the current status based on log below.

  ------------------------------------------------------------------------------------
  Full Log:
  ------------------------------------------------------------------------------------
  #{full_log}
  ------------------------------------------------------------------------------------


  -----------------------------------------------------------------------------------
  Current console state after the last iteration:
  -----------------------------------------------------------------------------------
     | Console window wize: (#{WINDOW_X}, #{WINDOW_Y})
     | Current cursor position: (#{cursor_position[:x]}, #{cursor_position[:y]})
     --------------------------------------------------------------------------------
  #{console_content}
  -----------------------------------------------------------------------------------

  Report format instructions:
  - use only very brief bullet points, not full paragraphs, condense the points as much as possible.
  - be sure to use a new line after each bullet point.
  - produce the summarized condensed version of this history right after "Summary:".
  - when you're done with the Summary, end the report with "END_SUMMARY" and we're done.
  - you are limited to 390 characters, so be concise.

  REPORT
  ======

  Summary:
  SUMMARY_PROMPT
end

def build_eval_prompt(response, mission, console_state)
  cursor_position = console_state[:cursor]
  console_content = console_state[:content]

  prompt = \
  <<~EVAL_PROMPT
  You are tasked with evaluating a response from the system called 'pllm'. The system's goal is to help the user accomplish a mission by providing keypress suggestions into user's console.

  The user's mission:
  --
  #{mission}
  --

  Pllm has provided suggestions to our user. Your task is to evaluate the suggestions based on the current console state and the user's mission.

  Current console window size: (#{WINDOW_X}, #{WINDOW_Y})
  Current cursor position: (#{cursor_position[:x]}, #{cursor_position[:y]})
  Current console state:
  #{console_content}

  The response from pllm:
  Reasoning: #{response['reasoning']}
  Keypresses array: #{response['keypresses']}
  Mission complete: #{response['mission_complete']}
  New scratchpad: #{response['new_scratchpad']}
  Next step: #{response['next_step']}

  Will the suggested keypresses really deliver what was intended or could there be a mistake? For example, when the user is supposed to press Enter, you can't suggest pressing E, then n, then t, then e, then r. That's not the same as pressing Enter.

  Try to meditate on each individual press and its effect on the console state. Is the reasoning behind every individual key press sound?

  Isn't there any ommision in the keypresses? Is there any keypress that is not necessary?

  Be very careful and precise in your evaluation. The user's mission depends on it. But be quick, the user is waiting for your evaluation.

  Your output will be cut off after 390 characters, so be concise.

  After you're done, end with "END_EVALUATION".

  EVALUATION:
  EVAL_PROMPT
end

def build_select_prompt(options, responses, mission, keypresses_history, console_state, previous_next_step)
  cursor_position = console_state[:cursor]
  console_content = console_state[:content]

  prompt = \
  <<~SELECT_PROMPT
  You are tasked with selecting the best response from the LLM agent called 'pllm'. The agent's goal is to help the user accomplish a mission by providing keypress suggestions into user's console.

  The agent has provided multiple responses to a single prompt. Your task is to select the best response based on the context of the mission and the user's progress.

  It is possible that the agent made mistakes or provided incorrect suggestions.

  Analyze the responses and select the one that best aligns with the mission and the user's progress.

  Instructions for operating the console session:
  - The console output is always prepended with line numbers by the system for your convenience. These are not part of the actual console content.
  - The console window size is #{WINDOW_X} columns by #{WINDOW_Y} rows.
  - There are no scrollbars, so the console content is limited to the visible area.
  - The console content is updated in real-time, and you can issue key presses to interact with the console.
  - The cursor position is indicated by the block symbol '█'.
  - Avoid batching multiple commands. Issue one command at a time and wait for the console to update.
  - Expect when a command can invoke an interactive editor or a pager.
  - Ensure proper navigation in interactive programs like editors, pagers, etc.
  - Beware if a command invokes a pager, navigate the user through the pager to show all the relevant parts of the output, don't be satisfied with one run if there might be more important data below.
  - Asses whether the user is in a pager or an editor and act accordingly.
  - The block symbol '█' indicates the current cursor position.

  Instructions for issuing keypresses:
  - Normal characters: "a", "b", "c", "A", "B", "C", "1", "2", ".", " ", "\"", etc.
  - Special named keys, read carefully, use literally: "Enter", "Tab", "BSpace", "Escape", "Up", "Down", "Left", "Right", "Home", "End", "PageUp", "PageDown", "Insert", "Delete"
  - Ctrl keys: Use C- notation for Ctrl keys. For example, "C-c" for Ctrl+c, "C-r" for Ctrl+r, etc.
  - Alt keys: Use M- notation for Alt keys. For example, "M-a" for Alt+a, "M-x" for Alt+x, etc.
  - Send uppercase letters directly as uppercase. No need for Shift notation.
  - If you need multiple steps, output them in a single "keypresses" array, one key per element.
  - You are forbidden to use "C-d". If you need to exit a shell, use "C-c" to interrupt the current process and then "exit" to exit the shell.
  - If you intend there to be a space between command and/or arguments, spell it out as "Space".
  - If you need to issue a command, provide the key presses to type the command and then "Enter" to execute it.
  - No command chaining in one iteration, only one command per iteration.
  - Example sequences:
    - ["l", "s", "Enter"]
    - ["C-c"]
    - ["e", "c", "h", "o", " ", "'", "H", "e", "l", "l", "o", "'", "Enter"]

  User's Mission:

  The user's end goal is to:
  --
  #{mission}
  --

  CURRENT CONSOLE STATE FOR YOUR ANALYSIS:
     | Console window wize: (#{WINDOW_X}, #{WINDOW_Y})
     | Current cursor position: (#{cursor_position[:x]}, #{cursor_position[:y]})
  #{console_content}


  Please select the best suitable response from these, reply with the number of the response.

  SELECT_PROMPT

  responses.each_with_index do |response, index|
    prompt += "Response ##{index + 1}\n"
    prompt += "Response #{index + 1} keypresses: #{response['keypresses']}\n"
    prompt += "Response #{index + 1} reasoning: #{response['reasoning']}\n"
    prompt += "Response #{index + 1} evaluation from an external critic: #{response['critic_evaluation']}\n" if options[:critic]
    prompt += "\n"
  end

  prompt += <<~SELECT_PROMPT

  Please provide the number of the best response given the context of the mission and the current state of the console.

  SELECT_PROMPT
  if previous_next_step != ""
    prompt += <<~SELECT_PROMPT
    To help you make a better decision, here's what pllm was planning in this step:

    "#{previous_next_step}".
    SELECT_PROMPT
  end
  prompt += <<~SELECT_PROMPT

  So, given all this information, choose the best response number and provide it as a single number.

  The best response number is:
  SELECT_PROMPT

  prompt
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

options = {
  edit: false,
  timeout: EDIT_TIMEOUT,
  history_limit: HISTORY_LIMIT,
  mission: DEFAULT_MISSION,
  reeval_times: REEVAL_TIMES,
  critic: false,
  help: false
}

help_text = ""
OptionParser.new do |opts|
  opts.banner = "Usage: pllm.rb [options]"
  opts.on("-e", "--edit[=SECONDS]", Integer, "Allow editing of LLM response before use, with optional timeout in seconds (default 5)") do |e|
    options[:edit] = true
    options[:timeout] = e || EDIT_TIMEOUT
  end
  opts.on("-l", "--history-limit=LIMIT", Integer, "Limit the number of entries in the scratchpad history (default 10)") do |l|
    options[:history_limit] = l
  end
  opts.on("-m", "--mission=MISSION_FILE", "Load mission from a file") do |m|
    mission = File.read(m)
    options[:mission] = mission
  end
  opts.on("-r", "--reeval-times=TIMES", Integer, "Number of times to reevaluate a response (default 3)") do |r|
    options[:reeval_times] = r
  end
  opts.on("-c", "--critic", "Enable critic evaluation of responses") do |c|
    options[:critic] = c
  end
  opts.on("-h", "--help", "Prints this help") do
    options[:help] = true
  end
  help_text = opts.to_s
end.parse!

if options[:help]
  puts help_text
  exit
end

uuid = SecureRandom.uuid
session_name = "pllm-#{uuid[0,8]}"
summaries = []
history = ""
history_length = 0
iteration = 0
mission_complete = false
parsed_responses = []
evaluated_responses = []
keypresses_history = []
previous_next_step = ""

logger.formatter = proc do |severity, datetime, progname, msg|
  "[#{session_name}] #{datetime} - #{severity}: #{msg}\n"
end

llm = LLM.new(logger,
              LLAMA_API_ENDPOINT, options, ENV['EDITOR'],
              { n_predict: 384, temperature: 0.95 })
tmux = Tmux.new(session_name, WINDOW_X, WINDOW_Y)

begin
  logger.info("")
  logger.info("Starting PLM session: #{session_name}")

  until mission_complete
    parsed_responses = []
    evaluated_responses = []
    selected_response = nil
    iteration += 1
    console_state = tmux.capture_output
    prompt = build_main_prompt(options[:mission], history, console_state, options, iteration)
    system("clear")
    logger.info("Running iteration #{iteration}")
    puts console_state[:content]

    options[:reeval_times].times do |i|
      parsed_response = nil
      evaluated_response = nil
      puts "\nQuerying LLM to get the next suggestions... (#{i+1}/#{options[:reeval_times]})"
      llm.query(prompt, {}) do |json_response|
        begin
          parsed_response = JSON.parse(json_response)
          if valid_llm_response?(parsed_response)
            logger.info("\n#{prompt}\n{#{json_response}}")
            parsed_responses << parsed_response
          end
        rescue JSON::ParserError => e
          err = "Failed to parse LLM response: #{e.message}. Please check the response for errors." 
          puts err
          logger.error(err)
        end 
      end
      next if parsed_response.nil?
      if options[:critic] == false
        evaluated_responses << parsed_response
        next
      end
      next if options[:reeval_times] == 1
      puts
      eval_prompt = build_eval_prompt(parsed_response, options[:mission], console_state)
      puts
      #puts eval_prompt
      evaluated_response = llm.query(eval_prompt, { n_predict: 128, temperature: 0.9}, "END_EVALUATION")
      puts
      evaluated_response = evaluated_response.strip
      evaluated_responses << parsed_response.merge({ 'critic_evaluation' => evaluated_response })
    end

    unless options[:reeval_times] == 1
      select_prompt = build_select_prompt(options, evaluated_responses, options[:mision], keypresses_history, console_state, previous_next_step)
      #puts select_prompt
      while selected_response.nil?
        print "\nSelect the best response: "
        selection = llm.query(select_prompt, { n_predict: 2, temperature: 0.3 }, "END_SELECT")
        puts
        selection = selection.match(/\d+/).to_s
        if selection.to_i > 0 && selection.to_i <= evaluated_responses.length
          selected_response = evaluated_responses[selection.to_i - 1]
        end
      end
    else
      selected_response = parsed_responses[0]
    end

    reasoning = selected_response['reasoning']
    keypresses = selected_response['keypresses'] || []
    keypresses_fmt = keypresses.map { |key| "\"#{key}\"" }.join(', ')
    mission_complete = selected_response['mission_complete']
    new_scratchpad = selected_response['new_scratchpad']
    next_step = selected_response['next_step']
    previous_next_step = next_step
    # Update scratchpad with cursor position
    timestamp = Time.now.utc.iso8601
    cursor_position = console_state[:cursor]
    history += "\n"
    history += "[#{timestamp}]\n"
    history += "Cursor Position: (#{cursor_position[:x]}, #{cursor_position[:y]})\n"
    history += "Console State:\n"
    history += "#{console_state[:content]}\n"
    history += "Scratchpad entry: #{new_scratchpad}\n"
    history += "Keypresses: #{keypresses_fmt}\n"
    history += "Next Step: #{next_step}\n"
    history += "Evaluation of this step by an external critic: #{selected_response['critic_evaluation']}\n" if options[:critic]
    history_length += 1

    unless keypresses.empty?
      tmux.send_keys(keypresses)
      keypresses_history << keypresses
    end

    sleep 2 # Give time for the shell to process the key presses

    new_state = tmux.capture_output
    logger.info("Post-Keypress Console State:\n#{new_state[:content]}")

    # Update history length and condense if needed
    if history_length >= options[:history_limit]
      logger.info("Summarizing history due to history limit")
      summarization_prompt = build_summarization_prompt(history, options[:mission], new_state)
      #puts summarization_prompt
      puts
      summary = llm.query(summarization_prompt, { n_predict: 390, temperature: 0.7 }, "END_SUMMARY")
      summaries << summary
      puts
      summaries.each do |s|
        history += "\nAn older summary:\n#{s}\n\n"
      end
      history_length = 0

      logger.info("Summarized history:\n#{history}")
    end

    break if mission_complete
  end
rescue Interrupt
  puts "\nInterrupted. Cleaning up..."
ensure
  tmux.cleanup
end
