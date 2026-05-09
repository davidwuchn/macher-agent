
# macher-agent

https://github.com/user-attachments/assets/461e695a-1315-4975-bbfb-c3a411819e11

This is a collection of tools inspired by [gptel-agent](https://github.com/karthink/gptel-agent/) but using the ethos of [macher](https://github.com/kmontag/macher). 

This attempts to avoid working directly on live files and instead operates within the macher context. With the verification gate being the final patch that's output at the end of execution.

This also contains some helpers to make tools that work in the macher ephemeral context using `macher-agent-make-tool`, native sub-agent orchestration with `macher-agent-add-subagent`, and event-loop blocking workarounds to keep the GUI free.

## Why macher-agent?

`macher-agent` enables an agent to execute shell commands (like `cargo check` or test suites) in an isolated sandbox against its own unsaved, in-memory edits. The macher context persists by default across auto-continuations effectively providing a continuous `macher-revise` loop by default until the objective is achieved. 

The auto sync is able to determine if patches were applied, if intermediate edits have been made or if the context is still valid. You only need to use clear to intentionally remove outstanding changes from the agent context.

You can also adopt a auto-agentic CLI style approach where a planner dynamically spins up, delegates to sub-agents entirely through tool calls. Or you could use a semi-agentic workflow, manually instantiating sub-agents and dispatching instructions yourself while still benefiting from the non-blocking, sandboxed execution.

###  Emacs-native architecture mapping

* Sandboxing and isolation are handled by routing modifications through a virtual memory `macher` context, culminating in a reviewable ediff patch rather than live file mutation.
* Asynchronous background execution is achieved via non-blocking sub-agent commands, keeping your editor GUI entirely responsive whilst the agent works.
* Multi-agent orchestration for complex tasks is replicated natively by allowing a planner to dynamically spin up isolated buffers, dispatch instructions, and await synthesised responses via tool calls.
* System integration and automated testing rely on dynamic tool creation, running filesystem aware tools against in-memory edits to self-correct compilation errors before presenting a final patch.
* Contextual integrity in patches and state preservation mirror external versioning by embedding the continuous conversation directly into intermediate patches, ensuring the agent's logic remains tethered to the proposed code.
* Infinite task loops and token management are sustained using `gptel` episodic sliding memory to compress older transcripts into structured summaries, preventing context degradation whilst retaining the full human-readable history in your buffer.
* Reverting and branching can be managed manually by clearing a sub-agent's context to wipe the slate clean, or by inspecting the conversational breadcrumbs left in intermediate patches.

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

This workflow demonstrates how to use the planner preset to analyse a repository and seamlessly hand off the implementation details to an isolated sub-agent entirely through tool calls. Agents interact with files and buffers via a virtual memory context, allowing changes to be reviewed as patches before being committed.

### Orchestration

* `spawn_subagent` - Instantiates a new, isolated sub-agent buffer locked to the current project directory.
* `execute_subagent_buffer_blocking` - Triggers the sub-agent to execute its task autonomously, pausing the parent agent until the sub-agent finishes its work and generates a patch.
* `execute_subagent_buffer_nonblocking` - Triggers the sub-agent to begin executing asynchronously in the background, allowing the parent agent to immediately continue its own processing without waiting.

### Emacs Buffer Operations

* `write_to_buffer` - Proposes a change to a live Emacs buffer, creating a virtual patch for review (ie via ediff) rather than mutating the buffer immediately.

* `write_and_commit_buffer` - Directly overwrites an Emacs buffer and fast-forwards the context to synchronise the agent's awareness.

* `read_buffer` - Reads the contents of an agent buffer, prioritising proposed virtual edits if modified during the current turn, or returning the live Emacs buffer state otherwise.

* `list_agent_buffers` - Scans the current Emacs session and returns a filtered list of all active orchestrator and sub-agent buffers.

* `search_agent_buffers` - Performs a regex search across all active agent buffers, returning matching lines and their locations.

### Semi-agentic workflow

Human-in-the-loop orchestratio using interactive Emacs commands to manually manage your sub-agents.

* `M-x macher-agent-add-subagent` - Interactively prompts you for a name and a target directory, then spins up a dedicated, isolated sub-agent buffer locked to that specific workspace. Makes current agent aware of sub agents, for example allowing you to instruct it to `write_to_buffer` with plans, research etc.
* `M-x macher-agent-clear-context` - Clears the persistent memory and pending edits of the current sub-agent buffer, allowing you to start a completely fresh task without destroying the buffer itself.
* **Manual Execution** - You can manually type your instructions directly into any sub-agent buffer and trigger `gptel-send` (or `macher-implement`). The agent will still execute its tasks asynchronously in the background and generate a reviewable patch, but you remain in full control of the dispatching.

### 1. Interactive User Commands
These are the `M-x` commands designed for human-in-the-loop orchestration and workspace management.

| Command | Description |
| :--- | :--- |
| `macher-agent-add-subagent` | Interactively prompts for a name and directory, then spins up a dedicated, isolated sub-agent buffer locked to that workspace. |
| `macher-agent-add-buffer-to-scope` | Manually injects an existing Emacs buffer into the current agent's allowed access scope, granting it permission to read/edit it. |
| `macher-agent-clear-context` | Clears the persistent virtual memory and pending edits of the current agent or sub-agent buffer, allowing a fresh start. |
| `macher-agent-apply-patch` | Safely applies the current patch buffer using external diff utilities (like `git apply` or `patch`) to avoid Emacs collision errors. |
| `macher-agent-insert-patch` | Inserts the proposed patch from the current workspace directly into the chat buffer for review. |
| `macher-agent-apply-virtual-buffers` | Alternative buffer patching function to ediff-patch-buffer |

---

### 2. Agent Tools
These are the `gptel` tools exposed to the LLM to facilitate orchestration, file operations, and buffer manipulation.

| Tool Name | Description |
| :--- | :--- |
| `spawn_subagent` | Creates a new, isolated sub-agent in the current project directory and registers it to the parent agent's access scope. |
| `delegate_task_to_subagent` | Writes instructions to a sub-agent with strict submission reminders and waits for its final synthesised response. |
| `delegate_task_to_subagents` | Writes instructions to sub-agents with strict submission reminders and waits for its final synthesised response. |
| `execute_subagent_buffer_blocking` | Triggers a sub-agent to execute autonomously, pausing the parent agent until it finishes its work and generates an output. |
| `execute_subagent_buffer_nonblocking`| Triggers a sub-agent to execute asynchronously in the background, allowing the parent agent to continue processing immediately. |
| `execute_subagents_buffer_nonblocking`| Triggers sub-agents to execute asynchronously in the background, allowing the parent agent to continue processing immediately. |
| `write_to_buffer` | Proposes new content for a live Emacs buffer, creating a virtual patch for review rather than mutating it immediately. |
| `write_and_commit_buffer` | Directly overwrites an Emacs buffer and fast-forwards the context to synchronise the agent's awareness. |
| `read_buffer` | Reads a scoped buffer's contents, prioritising proposed virtual edits if modified during the current turn, or the live state otherwise. |
| `list_agent_buffers` | Returns a filtered list of all active orchestrator and sub-agent buffers within the agent's explicit allowlist. |
| `search_agent_buffers` | Performs a regex search across all allowed agent buffers, returning matching text and their line numbers. |
| `submit_task_result` | Used strictly by worker sub-agents to submit their final, synthesised answer back to the parent orchestrator. |
