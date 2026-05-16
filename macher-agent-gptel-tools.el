;;; macher-agent-gptel-tools.el --- Pure gptel orchestration tools -*- lexical-binding: t; -*-

(require 'macher)

;; --- Configuration & UI Hooks ---

(defcustom macher-agent-tool-timeout-attempts 1200
  "Maximum number of 0.5s polling attempts before a sub-agent times out."
  :type 'integer
  :group 'macher-agent)

(defcustom macher-agent-display-subagent-fn nil
  "Function to call with a BUFFER to display it while running.
If nil, the buffer executes silently in the background."
  :type '(choice (const :tag "Silent Background Execution" nil)
                 function)
  :group 'macher-agent)

(defcustom macher-agent-hide-subagent-fn nil
  "Function to call with a BUFFER to hide it once finished."
  :type '(choice (const :tag "Do Nothing" nil)
                 function)
  :group 'macher-agent)

(defun macher-agent--show-ui (buf)
  "Internal wrapper to safely trigger the display function."
  (when macher-agent-display-subagent-fn
    (funcall macher-agent-display-subagent-fn buf)))

(defun macher-agent--hide-ui (buf)
  "Internal wrapper to safely trigger the hide function."
  (when macher-agent-hide-subagent-fn
    (funcall macher-agent-hide-subagent-fn buf)))

;; --- Cloaking Mechanism ---

(defun macher-agent--insert-hidden (text)
  "Insert TEXT visually hidden via a display overlay, but fully readable by gptel.
This overrides font-lock and prevents markdown-mode from revealing the text."
  (let* ((start (point))
         (_ (insert text))
         (ov (make-overlay start (point))))
    (overlay-put ov 'display "")
    (overlay-put ov 'insert-behind-hooks '(ignore))))

;; --- Wait Loops ---

(defun macher-agent--wait-and-return (buffers callback &optional attempts old-fsms)
  "Wait for 1-to-many sub-agents to populate their final result variables using FSM termination."
  (let ((results nil)
        (failed-buffers nil)
        (pending-count (length buffers))
        (attempts (or attempts 0)))

    (cl-labels
        ;; 1. Check if all tasks have resolved and trigger the final callback
        ((check-done ()
           (when (= pending-count 0)
             (if failed-buffers
                 (funcall callback (string-join failed-buffers "\n"))
               (dolist (b buffers)
                 (with-current-buffer b (setq-local macher-agent--final-result nil))
                 (macher-agent--hide-ui b))
               (let ((final-output
                      (mapconcat (lambda (r) (format "=== Response from %s ===\n%s" (car r) (cdr r)))
                                 (nreverse results)
                                 "\n\n")))
                 (funcall callback (format "SUCCESS. All sub-agents completed. Outputs:\n\n%s" final-output))))))

         ;; 2. State Mutator: Record an error and check if we are done
         (mark-error (err-msg)
           (push err-msg failed-buffers)
           (cl-decf pending-count)
           (check-done))

         ;; 3. State Mutator: Record a success and check if we are done
         (mark-success (buf-name res)
           (push (cons buf-name res) results)
           (cl-decf pending-count)
           (check-done))

         ;; 4. Check if an agent spawned a new FSM to continue its work
         (handle-continuation (buf fsm)
           (let ((new-fsm (buffer-local-value 'macher--fsm-latest buf)))
             (if (and new-fsm (not (eq new-fsm fsm)))
                 (progn
                   ;; CRITICAL FIX: Forward the context to the new FSM so the diff isn't lost
                   (let ((ctx (macher-agent--fsm-get-context fsm)))
                     (when ctx (macher-agent--fsm-put-context new-fsm ctx)))
                   
                   ;; Wait for the continuation to finish
                   (macher-agent--wait-and-return
                    (list buf)
                    (lambda (msg)
                      (if (string-match-p "^SUCCESS" msg)
                          (let ((clean-result (replace-regexp-in-string "^SUCCESS.*Outputs:\n\n=== Response from .* ===\n" "" msg)))
                            (mark-success (buffer-name buf) clean-result))
                        (mark-error (format "ERROR: %s" msg))))
                    0 (list (cons buf fsm))))
               (mark-error (format "ERROR: Buffer '%s' stopped silently." (buffer-name buf))))))

         ;; 5. Handle an FSM reaching its termination state
         (handle-termination (buf fsm _terminated-fsm)
           (if (not (buffer-live-p buf))
               (mark-error (format "ERROR: Buffer '%s' was killed." (buffer-name buf)))
             (let ((res (buffer-local-value 'macher-agent--final-result buf)))
               (if res
                   (mark-success (buffer-name buf) res)
                 (run-at-time 0.5 nil #'handle-continuation buf fsm)))))

         ;; 6. Validate that all buffers have initialized their FSMs
         (all-started-p ()
           (cl-loop for buf in buffers
                    for fsm = (buffer-local-value 'macher--fsm-latest buf)
                    for old-fsm = (cdr (assq buf old-fsms))
                    always (and fsm (not (eq fsm old-fsm))))))

      ;; --- Main Execution Flow ---
      (if (and (not (all-started-p)) (< attempts macher-agent-tool-timeout-attempts))
          (run-at-time 0.1 nil #'macher-agent--wait-and-return buffers callback (1+ attempts) old-fsms)
        
        ;; Once started (or timed out), process each buffer
        (dolist (buf buffers)
          (let* ((fsm (buffer-local-value 'macher--fsm-latest buf))
                 (old-fsm (cdr (assq buf old-fsms))))
            (if (or (not fsm) (eq fsm old-fsm))
                (mark-error (format "ERROR: Buffer '%s' failed to start." (buffer-name buf)))
              (macher--add-termination-handler
               fsm
               (lambda (term-fsm) (handle-termination buf fsm term-fsm))))))))))

(defun macher-agent--set-system-message (msg)
  "Adapter function to safely set the gptel system message without hardcoding internals."
  (setq-local gptel--system-message msg))

;; --- Tools ---

(defun macher-agent--format-error (err)
  "Standardise the error message string for the LLM."
  (let ((msg (error-message-string err)))
    (if (string-match-p "^\\(ERROR\\|SECURITY ERROR\\):" msg)
        msg
      (format "ERROR: %s" msg))))

(defun macher-agent--parse-tasks-array (tasks callback)
  "Parse TASKS into a valid vector, executing CALLBACK on error."
  (unless (vectorp tasks)
    (if (stringp tasks)
        (condition-case nil
            (setq tasks (json-parse-string tasks :array-type 'vector :object-type 'plist))
          (error (funcall callback "ERROR: 'tasks' parameter was not a valid JSON array.")
                 (setq tasks nil)))
      (funcall callback "ERROR: 'tasks' parameter must be an array of objects.")
      (setq tasks nil)))
  tasks)

(defun macher-agent--prepare-subagent-instructions (buf instructions)
  "Insert INSTRUCTIONS into BUF with cloaked system reminders."
  (with-current-buffer buf
    (goto-char (point-max))
    (when (not (string-empty-p instructions))
      (macher-agent--insert-hidden "\n\n=== DELEGATED TASK ===\n")
      (insert (substring-no-properties instructions)))
    (macher-agent--insert-hidden "\n\n@macher-agent-worker\n=== SYSTEM REMINDER ===\nYou MUST use the `submit_task_result` tool to return your answer. Do not just type it as plain text.\n")))

(defun macher-agent--dispatch-async (buf)
  "Trigger gptel-send in BUF and show UI."
  (with-current-buffer buf
    (macher-agent--show-ui buf)
    (gptel-send)))

(defvar macher-agent-spawn-subagent-tool
  (gptel-make-tool
   :name "spawn_subagent"
   :description "Create a new, isolated sub-agent in the current project directory. Use this to spin up a worker for a specific task."
   :category "macher-agent-orchestrate"
   :args (list '(:name "name" :type string :description "The name of the new sub-agent."))
   :function (lambda (context name)
               (condition-case err
                   (let ((buf-name (format "*macher-agent: %s*" name)))
                     (macher-agent-add-subagent name default-directory t context)
                     (when context
                       (let* ((contents (macher-context-contents context))
                              (entry (assoc buf-name contents)))
                         (unless entry
                           (let ((orig (with-current-buffer buf-name
                                         (buffer-substring-no-properties (point-min) (point-max)))))
                             (setf (macher-context-contents context)
                                   (cons (cons buf-name (cons orig nil)) contents))))))
                     (format "SUCCESS: Sub-agent created. The EXACT buffer name to use is '%s'." buf-name))
                 (error (macher-agent--format-error err))))))

(defvar macher-agent-delegate-multiple-tool
  (gptel-make-tool
   :name "delegate_tasks_to_subagents"
   :description "Write instructions to 1-to-many sub-agents concurrently and wait for all their final responses. Used to fan-out work."
   :category "macher-agent-orchestrate"
   :async t
   :args (list '(:name "tasks" :type array 
                       :description "An array of task objects."
                       :items (:type object 
                                     :properties (:buffer_name (:type string) 
                                                               :instructions (:type string)) 
                                     :required ["buffer_name" "instructions"])))
   :function (lambda (context callback tasks)
               (let ((parsed-tasks (macher-agent--parse-tasks-array tasks callback)))
                 (when parsed-tasks
                   (condition-case err
                       (let ((target-pairs nil)
                             (target-buffers nil)
                             (old-fsms nil))
                         
                         (cl-loop for task across parsed-tasks do
                                  (let* ((buffer-name (plist-get task :buffer_name))
                                         (instructions (plist-get task :instructions))
                                         (actual-name (macher-agent--resolve-buffer-name buffer-name)))
                                    (macher-agent--ensure-access context actual-name)
                                    (let ((buf (get-buffer actual-name)))
                                      (unless (buffer-live-p buf)
                                        (error "ERROR: Buffer '%s' does not exist." actual-name))
                                      (push (cons buf instructions) target-pairs))))
                         
                         (dolist (task-pair (nreverse target-pairs))
                           (let ((buf (car task-pair))
                                 (instructions (cdr task-pair)))
                             (push buf target-buffers)
                             (push (cons buf (buffer-local-value 'macher--fsm-latest buf)) old-fsms)
                             (macher-agent--prepare-subagent-instructions buf instructions)
                             (macher-agent--dispatch-async buf)))
                         
                         (macher-agent--wait-and-return (nreverse target-buffers) callback 0 old-fsms))
                     (error (funcall callback (macher-agent--format-error err)))))))))

(defvar macher-agent-execute-subagents-tool
  (gptel-make-tool
   :name "execute_subagents"
   :description "Trigger 1-to-many sub-agents to begin processing. Does NOT provide new instructions. Supports an optional blocking flag to wait for their final output."
   :category "macher-agent-orchestrate"
   :async t
   :args (list '(:name "buffer_names" :type array 
                       :description "List of buffer names to trigger."
                       :items (:type string))
               '(:name "blocking" :type boolean :optional t
                       :description "If true, pause the parent agent and wait for all triggered agents to complete. If false (default), run asynchronously in the background."))
   :function (lambda (context callback buffer_names &optional blocking)
               (unless (vectorp buffer_names)
                 (if (stringp buffer_names)
                     (condition-case nil
                         (setq buffer_names (json-parse-string buffer_names :array-type 'vector))
                       (error (funcall callback "ERROR: 'buffer_names' parameter must be an array of strings.")
                              (setq buffer_names nil)))
                   (funcall callback "ERROR: 'buffer_names' parameter must be an array of strings.")
                   (setq buffer_names nil)))
               
               (when buffer_names
                 (condition-case err
                     (let ((target-buffers nil)
                           (old-fsms nil))
                       
                       (cl-loop for buffer_name across buffer_names do
                                (let ((actual-name (macher-agent--resolve-buffer-name buffer_name)))
                                  (macher-agent--ensure-access context actual-name)
                                  (let ((buf (get-buffer actual-name)))
                                    (unless (buffer-live-p buf)
                                      (error "ERROR: Buffer '%s' does not exist." actual-name))
                                    (push buf target-buffers)
                                    (push (cons buf (buffer-local-value 'macher--fsm-latest buf)) old-fsms))))
                       
                       (dolist (buf target-buffers)
                         (macher-agent--prepare-subagent-instructions buf "")
                         (macher-agent--dispatch-async buf))
                       
                       (if (and blocking (not (eq blocking :json-false)))
                           (macher-agent--wait-and-return (nreverse target-buffers) callback 0 old-fsms)
                         (funcall callback (format "SUCCESS: Triggered %d sub-agents asynchronously." (length target-buffers)))))
                   (error (funcall callback (macher-agent--format-error err))))))))

(defvar macher-agent-write-buffer-tool
  (gptel-make-tool
   :name "write_buffer_in_workspace"
   :description "Propose new content for a live Emacs buffer. This creates a virtual patch that will be presented for review rather than mutating the buffer immediately."
   :category "macher-agent"
   :args (list '(:name "buffer_name" :type string :description "The name of the target buffer")
               '(:name "content" :type string :description "The proposed new content for the buffer"))
   :function (lambda (context buffer_name content)
               (condition-case err
                   (let ((actual-name (macher-agent--resolve-buffer-name buffer_name)))
                     (unless (get-buffer actual-name)
                       (get-buffer-create actual-name))
                     (macher-agent--update-context-file context actual-name content)
                     (format "SUCCESS: Virtual edit recorded for buffer '%s'. A patch will be generated at the end of the turn." actual-name))
                 (error (macher-agent--format-error err))))))

(defvar macher-agent-commit-buffer-tool
  (gptel-make-tool
   :name "write_and_commit_buffer_in_workspace"
   :description "Directly overwrite an Emacs buffer and synchronise the agent's memory immediately, bypassing the patch review step."
   :category "macher-agent-commit"
   :args (list '(:name "buffer_name" :type string)
               '(:name "content" :type string))
   :function (lambda (context buffer_name content)
               (condition-case err
                   (let ((actual-name (macher-agent--resolve-buffer-name buffer_name)))
                     (macher-agent--ensure-access context actual-name)
                     (let ((target-buffer (get-buffer-create actual-name)))
                       (with-current-buffer target-buffer
                         (erase-buffer)
                         (insert content))
                       (when context
                         (macher-agent--update-context-file context actual-name content)
                         (macher-agent--auto-sync-context context))
                       (format "SUCCESS: Buffer '%s' has been directly overwritten and synchronised." actual-name)))
                 (error (macher-agent--format-error err))))))

(defvar macher-agent-list-buffers-tool
  (gptel-make-tool
   :name "list_buffers_in_workspace"
   :description "List all buffers you currently have explicit access to. You cannot access buffers outside this list."
   :category "macher-agent-ro"
   :function (lambda (context)
               (let ((active-buffers nil))
                 (when context
                   (dolist (entry (macher-context-contents context))
                     (let ((buf-name (car entry)))
                       (when (get-buffer buf-name)
                         (push buf-name active-buffers)))))
                 (if active-buffers
                     (mapconcat #'identity (nreverse active-buffers) "\n")
                   "No buffers are currently in your scope.")))))

(defvar macher-agent-search-buffers-tool
  (gptel-make-tool
   :name "search_buffers_in_workspace"
   :description "Search for a regular expression pattern across the buffers in your restricted scope."
   :category "macher-agent-ro"
   :args (list '(:name "pattern" :type string :description "The Emacs regex pattern to search for"))
   :function (lambda (context pattern)
               (condition-case err
                   (let ((results nil))
                     (when context
                       (dolist (entry (macher-context-contents context))
                         (let* ((buf-name (car entry))
                                (buf (get-buffer buf-name)))
                           (when buf
                             (with-current-buffer buf
                               (save-excursion
                                 (goto-char (point-min))
                                 (while (re-search-forward pattern nil t)
                                   (let* ((line (line-number-at-pos))
                                          (content (string-trim (thing-at-point 'line t))))
                                     (push (format "%s:%d: %s" buf-name line content) results)))))))))
                     (if results
                         (mapconcat #'identity (nreverse results) "\n")
                       (format "No matches found for '%s' in your scoped buffers." pattern)))
                 (error (macher-agent--format-error err))))))

(defvar macher-agent-read-buffer-tool
  (gptel-make-tool
   :name "read_buffer_in_workspace"
   :description "Read the contents of a scoped buffer (ie a buffer in your allowed list)."
   :category "macher-agent-ro"
   :args (list '(:name "buffer_name" :type string :description "The name of the buffer to read")
               '(:name "offset" :type number :optional t :description "Line number to start reading from (1-based)")
               '(:name "limit" :type number :optional t :description "Number of lines to read")
               '(:name "show_line_numbers" :type boolean :optional t :description "Include line numbers in output"))
   :function (lambda (context buffer_name &optional offset limit show_line_numbers)
               (condition-case err
                   (let* ((actual-name (macher-agent--resolve-buffer-name buffer_name))
                          (content (macher-agent--read-context-file context actual-name))
                          (parsed-offset (when offset (round offset)))
                          (parsed-limit (when limit (round limit))))
                     (macher--read-string content parsed-offset parsed-limit show_line_numbers))
                 (error (macher-agent--format-error err))))))

(defvar macher-agent-multi-edit-buffer-tool
  (gptel-make-tool
   :name "multi_edit_buffer_in_workspace"
   :description "Apply 1-to-many replacements to one scoped buffer in your workspace sequentially. All edits use exact text matching (whitespace, newlines, indentation). Use actual content - NO line numbers.\n\nEdits apply in array order. If ANY edit fails, ALL changes are rolled back."
   :category "macher-agent"
   :args (list '(:name "buffer_name" :type string :description "The name of the target buffer")
               '(:name "edits" :type array :description "Array of edit operations to apply in sequence"
                       :items (:type object
                                     :properties (:old_text (:type string :description "Exact text to find and replace.")
                                                            :new_text (:type string :description "Text to replace the old_text with")
                                                            :replace_all (:type boolean :description "If true, replace all occurrences."))
                                     :required ["old_text" "new_text"])))
   :function (lambda (context buffer_name edits)
               (condition-case err
                   (let* ((actual-name (macher-agent--resolve-buffer-name buffer_name))
                          (content (macher-agent--read-context-file context actual-name)))
                     (unless (vectorp edits)
                       (if (stringp edits)
                           (setq edits (json-parse-string edits :array-type 'vector :object-type 'plist))
                         (error "The 'edits' parameter must be an array of objects")))
                     (cl-loop for edit across edits do
                              (let* ((old-text (plist-get edit :old_text))
                                     (new-text (plist-get edit :new_text))
                                     (replace-all (plist-get edit :replace_all))
                                     (replace-all-bool (and replace-all (not (eq replace-all :json-false)))))
                                (unless (and old-text new-text)
                                  (error "Each edit must contain old_text and new_text properties"))
                                (setq content (macher--edit-string content old-text new_text replace-all-bool))))
                     (macher-agent--update-context-file context actual-name content)
                     (format "SUCCESS: Virtual multi-edit recorded for buffer '%s'. A patch will be generated at the end of the turn." actual-name))
                 (error (macher-agent--format-error err))))))

(defvar-local macher-agent--final-result nil
  "Stores the clean, synthesised final answer from the sub-agent.")

(defvar macher-agent-submit-result-tool
  (gptel-make-tool
   :name "submit_task_result"
   :description "Submit your final, completed answer back to the parent agent. Call this ONLY when your task is completely finished."
   :category "macher-agent-worker"
   :args (list '(:name "final_answer" :type string :description "The comprehensive final response to the requested task."))
   :function (lambda (context final_answer)
               (setq-local macher-agent--final-result final_answer)
               "SUCCESS: Result submitted successfully. You have completed your task.")))

;; --- Presets ---

(defconst macher-agent-base-read-tools
  '("read_file_in_workspace" 
    "list_directory_in_workspace" 
    "search_in_workspace")
  "Base filesystem reading tools provided by macher.el.")

(defconst macher-agent-ro-tools
  '("read_buffer_in_workspace"
    "list_buffers_in_workspace"
    "search_buffers_in_workspace")
  "Read-only tools for inspecting Emacs buffers.")

(defconst macher-agent-edit-tools
  '("multi_edit_buffer_in_workspace"
    "write_buffer_in_workspace")
  "Destructive tools for modifying Emacs buffers.")

(defconst macher-agent-orchestrate-tools
  '("spawn_subagent"
    "delegate_tasks_to_subagents"
    "execute_subagents"
    "write_and_commit_buffer_in_workspace")
  "Tools for managing and communicating with sub-agents.")

(with-eval-after-load 'macher
  
  ;; 1. The Planner Preset
  (gptel-make-preset "macher-agent-plan"
    :description "Project planning, architectural analysis, and sub-agent orchestration"
    ;; Planners get eyes (ro/base) and management powers (orchestrate), but no hands
    :tools (append macher-agent-base-read-tools
                   macher-agent-ro-tools
                   macher-agent-orchestrate-tools))

  ;; 2. The Worker Preset
  (gptel-make-preset "macher-agent-worker"
    :description "Sub-agent worker preset with strict tool-submission rules."
    :system "You are an autonomous sub-agent working on a delegated task within an Emacs environment.

CRITICAL DIRECTIVE: 
You MUST use the `submit_task_result` tool to deliver your final answer back to the orchestrator if asked to. 
Do NOT output your final answer as conversational plain text.
If you need to explore the codebase, use your read/search tools. 
The very last action you take must be invoking `submit_task_result`."
    ;; Workers get eyes (ro/base) and hands (edit), plus their specific submission tool
    :tools (append macher-agent-base-read-tools
                   macher-agent-ro-tools
                   macher-agent-edit-tools
                   '("submit_task_result"))))

(provide 'macher-agent-gptel-tools)
;;; macher-agent-gptel-tools.el ends here
