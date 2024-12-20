pllm
====

## Overview

This is a Ruby program that achieves user stated mission in terminal.

It does so using locally running llama.cpp at port 8081 (so start it there or change the source)

## Usage

Run the program with the following options:

- `-l`: History limit after which compaction by summarization hits.
- `-m`: Provides the user mission file to be sent to the LLM API.
- `-a`: This option is currently not implemented and does not perform any action.

## Example

```sh
ruby pllm.rb -l http://example.com/api -m "Your prompt here"