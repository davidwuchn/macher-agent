;;; macher-agent-gptel-tools.el --- Pure gptel orchestration tools -*- lexical-binding: t; -*-

(require 'macher)

(defcustom macher-agent-tool-timeout-attempts 1200
  "Maximum number of 0.5s polling attempts before a sub-agent times out."
  :type 'integer
  :group 'macher-agent)

(defun macher-agent--wait-and-return (buf callback &optional attempts)
  "Wait for the sub-agent to populate its final result variable."
  (let ((attempts (or attempts 0)))
    (cond
     ((> attempts macher-agent-tool-timeout-attempts)
      (funcall callback "ERROR: Sub-agent timed out before submitting a result."))
     
     ((not (buffer-live-p buf))
      (funcall callback "ERROR: Sub-agent buffer was killed before finishing."))
     
     ((buffer-local-value 'macher-agent--final-result buf)
      (let ((clean-result (buffer-local-value 'macher-agent--final-result buf)))
        (with-current-buffer buf
          (setq-local macher-agent--final-result nil))
        (funcall callback (format "SUCCESS. Sub-agent completed task. Final Output:\n\n%s" clean-result))))
     
     (t
      (run-at-time 0.5 nil #'macher-agent--wait-and-return buf callback (1+ attempts))))))

(defvar macher-agent-spawn-subagent-tool
  (gptel-make-tool
   :name "spawn_subagent"
   :description "Create a new, isolated sub-agent in the current project directory. Use this to spin up a worker for a specific task."
   :category "macher-agent-plan"
   :args (list '(:name "name" :type string :description "The name of the new sub-agent."))
   :function (lambda (context name)
               (condition-case err
                   (let ((buf-name (format "*macher-agent: %s*" name)))
                     (macher-agent-add-subagent name default-directory t)
                     (unless (local-variable-p 'macher-agent--scoped-buffers)
                       (setq-local macher-agent--scoped-buffers nil))
                     (add-to-list 'macher-agent--scoped-buffers buf-name)
                     (format "SUCCESS: Sub-agent created. The EXACT buffer name to use is '%s'." buf-name))
                 (error (error-message-string err))))))

(defvar macher-agent-delegate-tool
  (gptel-make-tool
   :name "delegate_task_to_subagent"
   :description "Write instructions to a sub-agent and wait for its final response."
   :category "macher-agent-plan"
   :async t
   :args (list '(:name "buffer_name" :type string)
               '(:name "instructions" :type string))
   :function (lambda (context callback buffer_name instructions)
               (condition-case err
                   (let ((actual-name (macher-agent--resolve-buffer-name buffer_name)))
                     (macher-agent--ensure-access actual-name)
                     
                     (let ((buf (get-buffer actual-name)))
                       (unless (buffer-live-p buf)
                         (error "ERROR: Buffer '%s' does not exist." actual-name))
                       
                       (with-current-buffer buf
                         (goto-char (point-max))
                         (insert "\n\n=== DELEGATED TASK === @macher-agent-worker\n" 
                                 (substring-no-properties instructions) 
                                 "\n\n=== SYSTEM REMINDER ===\n"
                                 "You MUST use the `submit_task_result` tool to return your answer. Do not just type it as plain text.\n")
                         (gptel-send)
                         (macher-agent--wait-and-return buf callback))))
                 (error (funcall callback (error-message-string err)))))))

(defvar macher-agent-write-to-buffer-tool
  (gptel-make-tool
   :name "write_to_buffer"
   :description "Propose new content for a live Emacs buffer. This creates a virtual patch that will be presented for review rather than mutating the buffer immediately."
   :category "macher-agent-plan"
   :args (list '(:name "buffer_name" :type string :description "The name of the target buffer")
               '(:name "content" :type string :description "The proposed new content for the buffer"))
   :function (lambda (context buffer_name content)
               (condition-case err
                   (let ((actual-name (macher-agent--resolve-buffer-name buffer_name)))
                     (unless (get-buffer actual-name)
                       (get-buffer-create actual-name))
                     
                     ;; The core context layer will intrinsically check access and throw if denied
                     (macher-agent--update-context-file context actual-name content)
                     (format "SUCCESS: Virtual edit recorded for buffer '%s'. A patch will be generated at the end of the turn." actual-name))
                 (error (error-message-string err))))))

(defvar macher-agent-commit-buffer-tool
  (gptel-make-tool
   :name "write_and_commit_buffer"
   :description "Directly overwrite an Emacs buffer and synchronise the agent's memory immediately, bypassing the patch review step."
   :category "macher-agent-plan"
   :args (list '(:name "buffer_name" :type string)
               '(:name "content" :type string))
   :function (lambda (context buffer_name content)
               (condition-case err
                   (let ((actual-name (macher-agent--resolve-buffer-name buffer_name)))
                     ;; Gatekeeper Check
                     (macher-agent--ensure-access actual-name)
                     
                     (let ((target-buffer (get-buffer-create actual-name)))
                       (with-current-buffer target-buffer
                         (erase-buffer)
                         (insert content))
                       
                       (when context
                         (macher-agent--update-context-file context actual-name content)
                         (macher-agent--auto-sync-context context))
                       
                       (format "SUCCESS: Buffer '%s' has been directly overwritten and synchronised." actual-name)))
                 (error (error-message-string err))))))

(defvar macher-agent-list-buffers-tool
  (gptel-make-tool
   :name "list_agent_buffers"
   :description "List all buffers you currently have explicit access to. You cannot access buffers outside this list."
   :category "macher-agent-plan"
   :function (lambda (context)
               (let ((active-buffers nil))
                 (dolist (buf-name macher-agent--scoped-buffers)
                   (when (get-buffer buf-name)
                     (push buf-name active-buffers)))
                 (if active-buffers
                     (mapconcat #'identity (nreverse active-buffers) "\n")
                   "No buffers are currently in your scope.")))))

(defvar macher-agent-search-buffers-tool
  (gptel-make-tool
   :name "search_agent_buffers"
   :description "Search for a regular expression pattern across the buffers in your restricted scope."
   :category "macher-agent-plan"
   :args (list '(:name "pattern" :type string :description "The Emacs regex pattern to search for"))
   :function (lambda (context pattern)
               (condition-case err
                   (let ((results nil))
                     (dolist (buf-name macher-agent--scoped-buffers)
                       (let ((buf (get-buffer buf-name)))
                         (when buf
                           (with-current-buffer buf
                             (save-excursion
                               (goto-char (point-min))
                               (while (re-search-forward pattern nil t)
                                 (let* ((line (line-number-at-pos))
                                        (content (string-trim (thing-at-point 'line t))))
                                   (push (format "%s:%d: %s" buf-name line content) results))))))))
                     (if results
                         (mapconcat #'identity (nreverse results) "\n")
                       (format "No matches found for '%s' in your scoped buffers." pattern)))
                 (error (error-message-string err))))))

(defvar macher-agent-read-buffer-tool
  (gptel-make-tool
   :name "read_buffer"
   :description "Read the contents of a scoped buffer (ie a buffer in your allowed list)."
   :category "macher-agent-plan"
   :args (list '(:name "buffer_name" :type string :description "The name of the buffer to read"))
   :function (lambda (context buffer_name)
               (condition-case err
                   (let ((actual-name (macher-agent--resolve-buffer-name buffer_name)))
                     ;; Utilize the abstracted core read function
                     (macher-agent--read-context-file context actual-name))
                 (error (error-message-string err))))))

(defvar macher-agent-execute-blocking-tool
  (gptel-make-tool
   :name "execute_subagent_buffer_blocking"
   :description "Trigger a sub-agent and WAIT for it to finish. Returns the sub-agent's final output."
   :category "macher-agent-plan"
   :async t
   :args (list '(:name "buffer_name" :type string))
   :function (lambda (context callback buffer_name)
               (condition-case err
                   (let ((actual-name (macher-agent--resolve-buffer-name buffer_name)))
                     (macher-agent--ensure-access actual-name)
                     
                     (let ((buf (get-buffer actual-name)))
                       (unless (buffer-live-p buf)
                         (error "ERROR: Buffer '%s' does not exist." actual-name))
                       
                       (with-current-buffer buf
                         (goto-char (point-max))
                         (insert "\n\n=== SYSTEM REMINDER ===\n@macher-agent-worker You MUST use the `submit_task_result` tool to return your answer. Do not just type it as plain text.\n")
                         (gptel-send)
                         (macher-agent--wait-and-return buf callback))))
                 (error (funcall callback (error-message-string err)))))))

(defvar macher-agent-execute-nonblocking-tool
  (gptel-make-tool
   :name "execute_subagent_buffer_nonblocking"
   :description "Trigger a sub-agent to begin processing asynchronously in the background. Does NOT return output."
   :category "macher-agent-plan"
   :args (list '(:name "buffer_name" :type string))
   :function (lambda (context buffer_name)
               (condition-case err
                   (let ((actual-name (macher-agent--resolve-buffer-name buffer_name)))
                     (macher-agent--ensure-access actual-name)
                     
                     (let ((buf (get-buffer actual-name)))
                       (unless (buffer-live-p buf)
                         (error "ERROR: Buffer '%s' does not exist." actual-name))
                       
                       (with-current-buffer buf
                         (goto-char (point-max))
                         (gptel-send)
                         (format "SUCCESS: Sub-agent in '%s' triggered asynchronously." actual-name))))
                 (error (error-message-string err))))))

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

(with-eval-after-load 'macher
  (gptel-make-preset "macher-agent-plan"
    :description "Project planning, architectural analysis, and sub-agent orchestration"
    :tools '("read_file_in_workspace" 
             "list_directory_in_workspace" 
             "search_in_workspace"
             "spawn_subagent"
             "delegate_task_to_subagent"
             "write_to_buffer"
             "execute_subagent_buffer_blocking"
             "execute_subagent_buffer_nonblocking")))

(with-eval-after-load 'macher
  (gptel-make-preset "macher-agent-worker"
    :description "Sub-agent worker preset with strict tool-submission rules."
    :system "You are an autonomous sub-agent working on a delegated task within an Emacs environment.

CRITICAL DIRECTIVE: 
You MUST use the `submit_task_result` tool to deliver your final answer back to the orchestrator if asked to. 
Do NOT output your final answer as conversational plain text.
If you need to explore the codebase, use your read/search tools. 
The very last action you take must be invoking `submit_task_result`."
    :tools '("read_file_in_workspace" 
             "list_directory_in_workspace" 
             "search_in_workspace"
             "submit_task_result")))

(provide 'macher-agent-gptel-tools)
;;; macher-agent-gptel-tools.el ends here
