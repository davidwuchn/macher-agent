# macher-agent

This is a collection of tools inspired by [gptel-agent](https://github.com/karthink/gptel-agent/) but using the ethos of [macher](https://github.com/kmontag/macher). 

This attempts to avoid working directly on live files and instead operates within the macher context. With the verification gate being the final patch that's output at the end of execution.

This also contains some helpers to make tools that work in the macher ephemeral context using ```macher-agent-make-tool```

Native sub-agent orhcestation with ```macher-agent-add-subagent```

A bit of work around the event-loop blocking to keep the GUI free -- gptel is good at this but needed some tweaks for the same experience with macher.


## Instatllation

To integrate macher-agent into your workflow, ensure that macher and gptel are already installed and loaded (and your system has rsync installed). Then setup your use-package based on the examples below


## Known Limitations

If a modified file in a subfolder shares a base filename with a file in the root directory, a warning is injected into the patch buffer advising you to apply the changes via an external utility (patch, git apply etc.) to ensure filesystem integrity.

## Example

### macher-agent-make-tool

To integrate `macher-agent` into your workflow, ensure that `macher` and `gptel` are already installed and loaded. Then, add the following `use-package` declaration to your Emacs configuration. 

This setup assumes you have [context-builder](https://github.com/igorls/context-builder) and [rtk](https://github.com/rtk-ai/rtk) available in your system path. 

```elisp
(use-package macher-agent
  :after (gptel macher)
  :config
  (add-to-list 'gptel-tools
               (macher-agent-make-tool
                :name "build_project_context"
                :description "Generate a read-only architectural map of the entire project. This returns structural context rather than compilable source code."
                :command-fn (lambda (_) "context-builder -y -f rs --signatures --ignore external --input . -o /dev/stdout </dev/null 2>&1")
                :output-filter (lambda (raw-output)
                                 (if (string-prefix-p "Execution failed" raw-output)
                                     raw-output
                                   (concat "CRITICAL DIRECTIVE: The following text is a read-only architectural map of the codebase. Do NOT write mock implementations for these signatures.\n\n" raw-output)))))

  (add-to-list 'gptel-tools
               (macher-agent-make-tool
                :name "cargo_check"
                :description "Run 'cargo check' to compile the project."
                :args nil
                :command-fn (lambda (_) "rtk cargo check </dev/null 2>&1")
                :success-fn (lambda (_) "SUCCESS: The code compiled perfectly with no errors."))
               )
  (add-to-list 'gptel-tools
               (macher-agent-make-tool
                :name "cargo_test"
                :description "Run 'cargo test' to test the project."
                :args nil
                :command-fn (lambda (_) "rtk cargo test </dev/null 2>&1")
                :success-fn (lambda (_) "SUCCESS: The tests ran perfectly with no errors."))
               ))
  ```

### Agentic workflow

This workflow demonstrates how to use a planner to seamlessly hand off the implementation details to an isolated sub-agent (or group) entirely through tool calls.

* `spawn_subagent` - Instantiate a new, macher context isolated sub-agent buffer in same workspace
* `write_to_buffer` - Dispatches the plans/instructions directly into the newly created sub-agent's buffer.
* `execute_subagent_blocking` - Triggers the sub-agent to execute its task autonomously and waiting (allows for patches to be applied or limit parallel LLM execution)
* `execute_subagent_buffer` - Fire and forget. Best when sub agents in own workspace


### Semi-agentic workflow

Human-in-the-loop orchestratio using interactive Emacs commands to manually manage your sub-agents.

* `M-x macher-agent-add-subagent` - Interactively prompts you for a name and a target directory, then spins up a dedicated, isolated sub-agent buffer locked to that specific workspace. Makes current agent aware of sub agents, for example allowing you to instruct it to `write_to_buffer` with plans, research etc.
* `M-x macher-agent-clear-context` - Clears the persistent memory and pending edits of the current sub-agent buffer, allowing you to start a completely fresh task without destroying the buffer itself.
* **Manual Execution** - You can manually type your instructions directly into any sub-agent buffer and trigger `gptel-send` (or `macher-implement`). The agent will still execute its tasks asynchronously in the background and generate a reviewable patch, but you remain in full control of the dispatching.
