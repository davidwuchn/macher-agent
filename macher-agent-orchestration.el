;;; macher-agent-orchestration.el --- Interactive sub-agent commands -*- lexical-binding: t; -*-

(require 'macher)

(declare-function macher-agent--set-system-message "macher-agent-gptel-tools" (msg))
(declare-function macher-agent-current-context "macher-agent-vfs-client")
(declare-function macher-agent--auto-sync-context "macher-agent-vfs-client" (&optional ctx fsm))

(defvar macher-agent-subagent-setup-hook nil
  "Hook run after a sub-agent buffer is fully initialized.")

(defun macher-agent--add-buffer-to-scope-headless (buf-name persistent-context)
  "Headless core logic for adding BUF-NAME to PERSISTENT-CONTEXT.
This bypasses user prompts to ensure orchestration remains decoupled
from the UI, strictly mutating the payload context."
  (get-buffer-create buf-name)
  (when persistent-context
    (let* ((contents (macher-context-contents persistent-context))
           (entry (assoc buf-name contents)))
      (unless entry
        (let ((orig (with-current-buffer buf-name
                      (buffer-substring-no-properties (point-min) (point-max)))))
          (setf (macher-context-contents persistent-context)
                (cons (cons buf-name (cons orig orig)) contents))))))
  (run-hooks 'macher-agent-context-mutated-hook))

;;;###autoload
(defun macher-agent-add-buffer-to-scope (buffer)
  "Manually add an Emacs BUFFER (existing or new) to the current agent's scope.
Acts as the interactive wrapper that passes the user's selected buffer
to the headless execution layer and reports success via message."
  (interactive "BAdd buffer to current agent's scope: ")
  (let* ((buf-name (if (stringp buffer) buffer (buffer-name buffer)))
         (ctx (macher-agent-current-context)))
    (macher-agent--add-buffer-to-scope-headless buf-name ctx)
    (message "SUCCESS: Added '%s' to the agent's restricted scope." buf-name)))

(defun macher-agent--resolve-buffer-name (name)
  "Return the clean buffer name.
Prefix forcing is removed as scope is handled explicitly by the
persistent context payload."
  (substring-no-properties name))

(defun macher-agent--prepare-subagent-buffer (buf full-dir context)
  "Set up internal state and clean mode initialisation for sub-agent BUF.
This configures internal state variables which are invisible but critical
for tools to function. It applies the worker preset silently in the
background and establishes the workspace directory to FULL-DIR alongside
the inherited CONTEXT."
  (with-current-buffer buf
    (setq default-directory full-dir)
    (setq-local macher-agent--is-workspace t)
    (setq-local macher-agent--is-subagent t)
    (setq-local macher--workspace (cons 'agent full-dir))
    (when context
      (setq-local macher-agent--persistent-context context))
    
    ;; Strict Buffer Isolation for Agent Context
    (setq-local gptel-context--alist nil)
    (when (boundp 'gptel--system-message)
      (setq-local gptel--system-message (default-value 'gptel--system-message)))
    (when (boundp 'gptel-model)
      (setq-local gptel-model (default-value 'gptel-model)))
    
    (unless (derived-mode-p 'markdown-mode)
      (markdown-mode))
    (unless gptel-mode
      (gptel-mode 1))
    
    (run-hooks 'macher-agent-subagent-setup-hook)))

;;;###autoload
(defun macher-agent-add-subagent (name dir &optional _display context)
  "Create a new sub-agent buffer completely silently.
No workspace path or system directives are printed to the buffer.
If CONTEXT is provided, the sub-agent inherits the persistent context.
Finally, this keeps the global tracking updated by pushing the new
sub-agent to `macher-agent-active-subagents`."
  (let* ((buf-name (format "*macher-agent: %s*" name))
         (buf (generate-new-buffer buf-name))
         (safe-dir (if (and dir (stringp dir)) dir default-directory))
         (full-dir (file-name-as-directory (expand-file-name safe-dir))))
    
    (macher-agent--prepare-subagent-buffer buf full-dir context)
    
    (when (boundp 'macher-agent-active-subagents)
      (push (cons name full-dir) macher-agent-active-subagents))
    buf))

(defun macher-agent-apply-virtual-buffers ()
  "Apply pending context edits to live Emacs buffers from the current context.
This commits the virtual patches to the real buffers."
  (interactive)
  (let* ((ctx (macher-agent-current-context))
         (contents (and ctx (macher-context-contents ctx))))
    (when contents
      (dolist (entry contents)
        (let* ((path-or-buf (car entry))
               (new-content (cddr entry)))
          (when (and new-content (get-buffer path-or-buf))
            (with-current-buffer (get-buffer path-or-buf)
              (erase-buffer)
              (insert new-content)))))
      (macher-agent--auto-sync-context ctx)
      (message "Virtual buffers applied successfully."))))

(defun macher-agent--register-tools-with-macher ()
  "Register specific macher-agent tools into the macher category 
so the FSM natively injects the workspace context. Simple tools are bypassed."
  (dolist (tool (gptel-get-tools))
    (setf (gptel-tool-category tool) "macher")))

(add-hook 'gptel-menu-mode-hook #'macher-agent--register-tools-with-macher)

;; Ensure manual review is triggered on aborts or errors
(defun macher-agent--gptel-abort-hook (&rest _)
  "Salvage pending edits if a generation is aborted or times out."
  (when (and (boundp 'macher-agent--persistent-context)
             macher-agent--persistent-context
             (macher-context-dirty-p macher-agent--persistent-context))
    (message "Generation aborted/failed. Salvaging pending virtual edits...")
    (macher-agent-force-review)))

(advice-add 'gptel-abort :after #'macher-agent--gptel-abort-hook)

(add-hook 'gptel-post-response-functions
          (lambda (_response info)
            ;; If response is nil, it often indicates a failure (400/500/timeout)
            (unless _response
              (macher-agent--gptel-abort-hook))))

(add-hook 'gptel-pre-response-functions
          (lambda (&rest _)
            (let ((ctx (macher-agent-current-context)))
              (when ctx (macher-agent--auto-sync-context ctx)))))

(with-eval-after-load 'macher
  (gptel-make-preset "macher-agent-worker"
    :description "Sub-agent worker preset with strict tool-submission rules."
    :system "You are an autonomous sub-agent working on a delegated task within an Emacs environment.

CRITICAL DIRECTIVES: 
1. You MUST use the `submit_task_result` tool to deliver your final answer back to the orchestrator if asked to. 
2. Do NOT output your final answer as conversational plain text.
3. SANDBOX RULE: Never use absolute paths (e.g., /Users/name/...) in any scripts, file writes, or CLI commands. You MUST use relative paths (./) bounded to your current working directory.
The very last action you take must be invoking `submit_task_result`."
    :tools '("read_buffer_in_workspace" 
             "list_buffers_in_workspace" 
             "search_in_workspace"
             "submit_task_result")))

(provide 'macher-agent-orchestration)
;;; macher-agent-orchestration.el ends here
