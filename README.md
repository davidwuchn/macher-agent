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

This workflow demonstrates how to use the planner preset to analyse a repository and seamlessly hand off the implementation details to an isolated sub-agent.

Start your planning session
- Open a new buffer give it a name like *Planner*
- Activate ```gptel-mode``` (you can select a planner preset for example)

Instantiate the executor
- Run ```M-x macher-agent-add-subagent```.
- You're prompted for an agent name
- When prompted for the directory, select the specific sub-module you want the agent to work in
- This automatically injects a system directive into your active planner buffer, informing the LLM that *macher-agent: x* is available.

Delegate the task
- Prompt the planner with your objective and end with "dispatch/write the plan to x buffer" or similar
- The planner will use ```write_to_buffer``` to push the text directly into the sub agents buffer.

Execute the plan
- Switch to the *macher-agent: <sub agent>* buffer.
- Add a preset to avoid prompt collisions and away it goes. If it uses macher-agent tools they will work async in the background without locking GUI and having access to the tools as the sandbox evolves...
