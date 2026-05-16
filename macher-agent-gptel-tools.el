;;; macher-agent-gptel-tools.el --- Pure gptel orchestration tools -*- lexical-binding: t; -*-

(require 'macher)
(require 's)
(require 'json)
(require 'cl-lib)

;; --- Configuration & UI Hooks ---

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

;; --- Pure Event-Driven Orchestration ---

(defun macher-agent--execute-parallel (buffers callback)
  "Execute multiple sub-agents concurrently using event-driven callbacks."
  (let ((pending-count (length buffers))
        (results nil)
        (errors nil)
        (master-ctx (macher-agent-current-context)))
    (cl-labels
        ((check-done ()
           (when (= pending-count 0)
             (if errors
                 (funcall callback (list :status 'error :error (string-join errors "\n")))
               ;; Map over results and merge shadow contexts back
               (let ((final-output
                      (mapconcat (lambda (r) 
                                   (let ((buf-name (car r))
                                         (res (cdr r)))
                                     ;; Merge back the shadow context if it exists
                                     (when-let ((buf (get-buffer buf-name))
                                                (shadow-ctx (buffer-local-value 'macher-agent--persistent-context buf)))
                                       (macher-agent--merge-contexts master-ctx shadow-ctx))
                                     (format "=== Response from %s ===\n%s" buf-name res)))
                                 (nreverse results) "\n\n")))
                 (funcall callback (list :status 'success :data (format "All sub-agents completed. Outputs:\n\n%s" final-output))))))))
      (dolist (buf buffers)
        ;; Clone context and assign buffer-locally
        (let ((shadow-ctx (macher-agent--clone-context master-ctx)))
          (with-current-buffer buf
            (setq-local macher-agent--persistent-context shadow-ctx)))
        
        (macher-agent--dispatch-and-wait
         buf
         (lambda (result)
           (if (eq (plist-get result :status) 'success)
               (push (cons (buffer-name buf) (plist-get result :data)) results)
             (push (plist-get result :error) errors))
           (cl-decf pending-count)
           (check-done)))))))

(defun macher-agent--dispatch-and-wait (buf callback)
  "Trigger gptel-send and handle response via native lifecycle hooks.
Restores FSM binding so the macher patch engine can read the virtual edits."
  (with-current-buffer buf
    (macher-agent--show-ui buf)
    (let ((response-hook nil)
          (transform-hook nil))
      
      ;; 1. Catch the FSM upon creation to bind our context (CRITICAL FOR PATCH UI)
      (setq transform-hook
            (lambda (async-fn fsm)
              (remove-hook 'gptel-prompt-transform-functions transform-hook :local)
              (setq-local macher--fsm-latest fsm)
              ;; Bind the virtual memory so the patch UI can read what was written
              (macher-agent--fsm-put-context fsm (macher-agent-current-context))
              (funcall async-fn)))
      (add-hook 'gptel-prompt-transform-functions transform-hook nil t)
      
      ;; 2. Handle completion naturally
      (setq response-hook
            (lambda (response info)
              (remove-hook 'gptel-post-response-functions response-hook :local)
              (let ((res (buffer-local-value 'macher-agent--final-result buf)))
                (if res
                    (progn
                      (macher-agent--hide-ui buf)
                      (funcall callback (list :status 'success :data res)))
                  (funcall callback (list :status 'error :error (format "ERROR: Buffer '%s' stopped silently without calling submit_task_result." (buffer-name buf))))))))
      (add-hook 'gptel-post-response-functions response-hook nil t)
      
      (gptel-send))))

(defun macher-agent--set-system-message (msg)
  "Adapter function to safely set the gptel system message without hardcoding internals."
  (setq-local gptel--system-message msg))

;; --- Tools ---

(cl-defmacro macher-agent-define-tool (name-symbol (description category &key args async) lambda-args &rest body)
  "Define a gptel tool with standardised JSON parsing, error handling, and native signature."
  (let* ((name-str (replace-regexp-in-string "^macher-agent-\\|-tool$" "" (symbol-name name-symbol)))
         (name (replace-regexp-in-string "-" "_" name-str))
         (all-lambda-args (if async (cons 'gptel-callback lambda-args) lambda-args))
         (docstring (format "Gptel tool wrapper for %s." name))
         (clean-args (cl-remove-if (lambda (sym) (string-prefix-p "&" (symbol-name sym))) lambda-args)))
    `(defvar ,name-symbol
       (gptel-make-tool
        :name ,name
        :description ,description
        :category ,(concat "macher-agent-" category)
        :args ,args
        :async ,async
        :function
        (lambda ,all-lambda-args
          ,docstring
          (let ((context (macher-agent-current-context)))
            (let ((parsed-args
                   (mapcar (lambda (arg)
                             (if (and (stringp arg)
                                      (or (string-prefix-p "[" (string-trim arg))
                                          (string-prefix-p "{" (string-trim arg))))
                                 (condition-case nil
                                     (json-parse-string arg :array-type 'vector :object-type 'plist)
                                   (error arg))
                               arg))
                           (list ,@clean-args))))

              ;; Middleware: Security check for buffer arguments after JSON parsing
              (let ((arg-alist (cl-mapcar #'cons ',clean-args parsed-args)))
                (unless (eq ',name-symbol 'macher-agent-write-buffer-in-workspace-tool)
                  (dolist (arg-name '("buffer_name" "buffer_names"))
                    (let* ((arg-sym (intern arg-name))
                           (val (cdr (assq arg-sym arg-alist))))
                      (when val
                        (if (or (listp val) (vectorp val))
                            (cl-loop for item being the elements of val do
                                     (macher-agent--ensure-access context item))
                          (macher-agent--ensure-access context val)))))))

              ,(if async
                   `(let ((callback (lambda (plist-result)
                                      (let ((final-str (if (eq (plist-get plist-result :status) 'success)
                                                           (plist-get plist-result :data)
                                                         (plist-get plist-result :error))))
                                        (funcall gptel-callback final-str)))))
                      (condition-case err
                          (apply (lambda ,lambda-args ,@body) parsed-args)
                        (error
                         (funcall callback (list :status 'error :error (macher-agent--format-error err))))))

                 `(let ((result
                         (condition-case err
                             (list :status 'success :data (apply (lambda ,lambda-args ,@body) parsed-args))
                           (error
                            (list :status 'error :error (macher-agent--format-error err))))))
                    (if (eq (plist-get result :status) 'success)
                        (plist-get result :data)
                      (plist-get result :error)))))))))))

(defun macher-agent--format-error (err)
  "Standardise the error message string for the LLM."
  (let ((msg (error-message-string err)))
    (if (string-match-p "^\\(ERROR\\|SECURITY ERROR\\):" msg)
        msg
      (format "ERROR: %s" msg))))

(defun macher-agent--prepare-subagent-instructions (buf instructions)
  "Insert INSTRUCTIONS into BUF with cloaked system reminders."
  (with-current-buffer buf
    (goto-char (point-max))
    (when (not (string-empty-p instructions))
      (macher-agent--insert-hidden "\n\n=== DELEGATED TASK ===\n")
      (insert (substring-no-properties instructions)))
    (macher-agent--insert-hidden "\n\n@macher-agent-worker\n=== SYSTEM REMINDER ===\nYou MUST use the `submit_task_result` tool to return your answer. Do not just type it as plain text.\n")))

(macher-agent-define-tool macher-agent-spawn-subagent-tool
                          ("Spawn a new sub-agent buffer to handle delegated work." "orchestrate" 
                           :args '((:name "name" :type string)))
                          (name)
                          (let* ((ctx (macher-agent-current-context))
                                 (dir default-directory)
                                 (buf (macher-agent-add-subagent name dir nil ctx)))
                            
                            (when ctx
                              (macher-agent--add-buffer-to-scope-headless (buffer-name buf) ctx))
                            
                            (format "SUCCESS: Sub-agent created. The EXACT buffer name to use is '%s'." (buffer-name buf))))

(macher-agent-define-tool macher-agent-delegate-tasks-to-subagents-tool
                          ("Delegate tasks to multiple sub-agents asynchronously." "orchestrate"
                           :args '((:name "tasks" :type array :description "An array of task objects to delegate to sub-agents."
                                          :items (:type object
                                                        :properties (:buffer_name (:type string :description "The exact name of the target sub-agent buffer.")
                                                                                  :instructions (:type string :description "The task instructions for this sub-agent to execute."))
                                                        :required ["buffer_name" "instructions"]))) 
                           :async t)
                          (tasks)
                          (let ((ctx (macher-agent-current-context))
                                (buffers nil))
                            
                            (cl-loop for task across tasks
                                     for buf-name = (plist-get task :buffer_name)
                                     for instructions = (plist-get task :instructions)
                                     for buf = (get-buffer buf-name)
                                     do (if (buffer-live-p buf)
                                            (progn
                                              (push buf buffers)
                                              (macher-agent--prepare-subagent-instructions buf instructions))
                                          (error "Sub-agent buffer '%s' not found. You must spawn it first." buf-name)))
                            
                            (macher-agent--execute-parallel (nreverse buffers) callback)))

(macher-agent-define-tool macher-agent-execute-subagents-tool
                          ("Trigger 1-to-many sub-agents to begin processing. Does NOT provide new instructions. Supports an optional blocking flag to wait for their final output."
                           "orchestrate"
                           :async t
                           :args '((:name "buffer_names" :type array
                                          :description "List of buffer names to trigger."
                                          :items (:type string))
                                   (:name "blocking" :type boolean :optional t
                                          :description "If true, pause the parent agent and wait for all triggered agents to complete. If false (default), run asynchronously in the background.")))
                          (buffer_names &optional blocking)
                          (unless (vectorp buffer_names) (error "ERROR: 'buffer_names' parameter must be an array of strings."))
                          (let ((target-buffers nil))
                            (cl-loop for buffer_name across buffer_names do
                                     (let ((actual-name (macher-agent--resolve-buffer-name buffer_name)))
                                       (let ((buf (get-buffer actual-name)))
                                         (unless (buffer-live-p buf)
                                           (error "ERROR: Buffer '%s' does not exist." actual-name))
                                         (push buf target-buffers))))

                            (dolist (buf target-buffers)
                              (macher-agent--prepare-subagent-instructions buf ""))

                            (if (and blocking (not (eq blocking :json-false)))
                                (macher-agent--execute-parallel (nreverse target-buffers) callback)
                              (progn
                                (dolist (buf target-buffers)
                                  (with-current-buffer buf
                                    (macher-agent--show-ui buf)
                                    (gptel-send)))
                                (funcall callback (list :status 'success :data (format "Triggered %d sub-agents asynchronously." (length target-buffers))))))))

(macher-agent-define-tool macher-agent-write-buffer-in-workspace-tool
                          ("Propose new content for a live Emacs buffer. This creates a virtual patch that will be presented for review rather than mutating the buffer immediately."
                           ""
                           :args '((:name "buffer_name" :type string :description "The name of the target buffer")
                                   (:name "content" :type string :description "The proposed new content for the buffer")))
                          (buffer_name content)
                          
                          (message "DEBUG [write-tool]: Invoked with raw buffer_name: '%s'" buffer_name)
                          
                          (let* ((actual-name (macher-agent--resolve-buffer-name buffer_name)))
                            (message "DEBUG [write-tool]: Resolved actual-name to: '%s'" actual-name)
                            
                            (let ((buf (get-buffer actual-name)))
                              (if buf
                                  (message "DEBUG [write-tool]: Target buffer '%s' already exists in Emacs memory." actual-name)
                                (message "DEBUG [write-tool]: Target buffer '%s' missing. Calling get-buffer-create..." actual-name)
                                (get-buffer-create actual-name)))
                            
                            (message "DEBUG [write-tool]: Proceeding to update virtual context...")
                            (macher-agent--update-context-file (macher-agent-current-context) actual-name content)
                            (message "DEBUG [write-tool]: Context update complete.")
                            
                            (format "SUCCESS: Virtual edit recorded for buffer '%s'. A patch will be generated at the end of the turn." actual-name)))

(macher-agent-define-tool macher-agent-list-buffers-in-workspace-tool
                          ("List all buffers you currently have explicit access to. You cannot access buffers outside this list."
                           "ro")
                          ()
                          (let* ((context (macher-agent-current-context))
                                 (workspace (when context (macher-context-workspace context)))
                                 (root-dir (when workspace (macher--workspace-root workspace)))
                                 (active-buffers nil))
                            (when context
                              (dolist (entry (macher-context-contents context))
                                (let* ((buf-name (car entry))
                                       (classification (macher-agent-context-classify-entry buf-name root-dir)))
                                  ;; Include both pure buffers and external files
                                  (when (memq classification '(buffer external))
                                    (push buf-name active-buffers)))))
                            (if active-buffers
                                (mapconcat #'identity (nreverse active-buffers) "\n")
                              "No buffers are currently in your scope.")))

(macher-agent-define-tool macher-agent-search-buffers-in-workspace-tool
                          ("Search for a regular expression pattern across the buffers in your restricted scope."
                           "ro"
                           :args '((:name "pattern" :type string :description "The Emacs regex pattern to search for")))
                          (pattern)
                          (let* ((context (macher-agent-current-context))
                                 (workspace (when context (macher-context-workspace context)))
                                 (root-dir (when workspace (macher--workspace-root workspace)))
                                 (results nil))
                            (when context
                              (dolist (entry (macher-context-contents context))
                                (let* ((buf-name (car entry))
                                       (classification (macher-agent-context-classify-entry buf-name root-dir)))
                                  ;; Include both pure buffers and external files
                                  (when (memq classification '(buffer external))
                                    ;; Read from virtual memory if present, fallback to live content
                                    (let ((content (or (cddr entry)
                                                       (macher-agent--get-buffer-content buf-name))))
                                      (when content
                                        (with-temp-buffer
                                          (insert content)
                                          (goto-char (point-min))
                                          (while (re-search-forward pattern nil t)
                                            (let* ((line (line-number-at-pos))
                                                   (match-content (string-trim (thing-at-point 'line t))))
                                              (push (format "%s:%d: %s" buf-name line match-content) results))))))))))
                            (if results
                                (mapconcat #'identity (nreverse results) "\n")
                              (format "No matches found for '%s' in your scoped buffers." pattern))))

(macher-agent-define-tool macher-agent-read-buffer-in-workspace-tool
                          ("Read the contents of a scoped buffer (ie a buffer in your allowed list)."
                           "ro"
                           :args '((:name "buffer_name" :type string :description "The name of the buffer to read")
                                   (:name "offset" :type number :optional t :description "Line number to start reading from (1-based)")
                                   (:name "limit" :type number :optional t :description "Number of lines to read")
                                   (:name "show_line_numbers" :type boolean :optional t :description "Include line numbers in output")))
                          (buffer_name &optional offset limit show_line_numbers)
                          (let* ((context (macher-agent-current-context))
                                 (actual-name (macher-agent--resolve-buffer-name buffer_name))
                                 (content (macher-agent--read-context-file context actual-name))
                                 (parsed-offset (when offset (round offset)))
                                 (parsed-limit (when limit (round limit))))
                            (macher--read-string content parsed-offset parsed-limit show_line_numbers)))

(macher-agent-define-tool macher-agent-multi-edit-buffer-in-workspace-tool
                          ("Apply 1-to-many replacements to one scoped buffer in your workspace sequentially. All edits use exact text matching (whitespace, newlines, indentation). Use actual content - NO line numbers.\n\nEdits apply in array order. If ANY edit fails, ALL changes are rolled back."
                           ""
                           :args '((:name "buffer_name" :type string :description "The name of the target buffer")
                                   (:name "edits" :type array :description "Array of edit operations to apply in sequence"
                                          :items (:type object
                                                        :properties (:old_text (:type string :description "Exact text to find and replace.")
                                                                               :new_text (:type string :description "Text to replace the old_text with")
                                                                               :replace_all (:type boolean :description "If true, replace all occurrences."))
                                                        :required ["old_text" "new_text"]))))
                          (buffer_name edits)
                          (let* ((context (macher-agent-current-context))
                                 (actual-name (macher-agent--resolve-buffer-name buffer_name))
                                 (content (macher-agent--read-context-file context actual-name)))
                            (unless (vectorp edits)
                              (error "The 'edits' parameter must be an array of objects"))
                            (cl-loop for edit across edits do
                                     (let* ((old-text (plist-get edit :old_text))
                                            (new-text (plist-get edit :new_text))
                                            (replace-all (plist-get edit :replace_all))
                                            (replace-all-bool (and replace-all (not (eq replace-all :json-false)))))
                                       (unless (and old-text new-text)
                                         (error "Each edit must contain old_text and new_text properties"))
                                       (setq content (macher--edit-string content old-text new-text replace-all-bool))))
                            (macher-agent--update-context-file context actual-name content)
                            (format "SUCCESS: Virtual multi-edit recorded for buffer '%s'. A patch will be generated at the end of the turn." actual-name)))

(defvar-local macher-agent--final-result nil
  "Stores the clean, synthesised final answer from the sub-agent.")

(macher-agent-define-tool macher-agent-submit-task-result-tool
                          ("Submit your final, completed answer back to the parent agent. Call this ONLY when your task is completely finished."
                           "worker"
                           :args '((:name "final_answer" :type string :description "The comprehensive final response to the requested task.")))
                          (final_answer)
                          (setq-local macher-agent--final-result final_answer)
                          "SUCCESS: Result submitted successfully. You have completed your task.")

;; --- Presets ---

(defconst macher-agent-base-read-tools
  '("read_file_in_workspace" 
    "list_directory_in_workspace" 
    "search_in_workspace")
  "Base filesystem reading tools provided by macher.el.")

(defconst macher-agent-ro-tools
  (list (gptel-tool-name macher-agent-read-buffer-in-workspace-tool)
        (gptel-tool-name macher-agent-list-buffers-in-workspace-tool)
        (gptel-tool-name macher-agent-search-buffers-in-workspace-tool))
  "Read-only tools for inspecting Emacs buffers.")

(defconst macher-agent-edit-tools
  (list (gptel-tool-name macher-agent-multi-edit-buffer-in-workspace-tool)
        (gptel-tool-name macher-agent-write-buffer-in-workspace-tool))
  "Destructive tools for modifying Emacs buffers.")

(defconst macher-agent-orchestrate-tools
  (list (gptel-tool-name macher-agent-spawn-subagent-tool)
        (gptel-tool-name macher-agent-delegate-tasks-to-subagents-tool)
        (gptel-tool-name macher-agent-execute-subagents-tool))
  "Tools for managing and communicating with sub-agents.")

(with-eval-after-load 'macher
  
  (gptel-make-preset "macher-agent-plan"
    :description "Project planning, architectural analysis, and sub-agent orchestration"
    :system "You are the Principal Architect of this codebase. Your role is orchestration and system design. 

You do not write or edit code directly. Your workflow is:
1. Analyse the user's request.
2. Use read tools to explore the workspace and understand the current implementation.
3. Devise a step-by-step execution plan.
4. Delegate discrete implementation tasks to sub-agents using the appropriate orchestration tools.
   - Provide sub-agents with highly specific instructions, including exact file paths and expected outcomes.
   - Do not ask them to 'figure it out'; give them the blueprint.
5. Synthesise their results and report back to the user."
    :tools (append macher-agent-base-read-tools
                   macher-agent-ro-tools
                   macher-agent-orchestrate-tools))

  (gptel-make-preset "macher-agent-worker"
    :description "Sub-agent worker preset with strict tool-submission rules."
    :system "You are an autonomous Senior Software Engineer operating within a sandboxed Emacs environment.
Your role is to execute a specific, delegated task with absolute precision.

CRITICAL DIRECTIVES:
1. You MUST use the `submit_task_result` tool to deliver your final answer back to the orchestrator.
   - Never output your final answer as conversational plain text.
   - The orchestrator can only 'hear' you if you use the submission tool.
2. Use your read tools to verify file contents before attempting any edits.
3. When using edit tools, rely on exact text matching. Account for indentation and whitespace.
4. Stay strictly within the scope of your delegated instructions. Do not attempt to refactor unrelated code.
5. The very last action you take in your execution loop MUST be invoking `submit_task_result`."
    :tools (append macher-agent-base-read-tools
                   macher-agent-ro-tools
                   macher-agent-edit-tools
                   (list (gptel-tool-name macher-agent-submit-task-result-tool)))))

(provide 'macher-agent-gptel-tools)
;;; macher-agent-gptel-tools.el ends here
