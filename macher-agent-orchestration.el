;;; macher-agent-orchestration.el --- Interactive sub-agent commands -*- lexical-binding: t; -*-

(require 'macher)


;;;###autoload
(defun macher-agent-add-buffer-to-scope (buffer)
  "Manually add an Emacs BUFFER (existing or new) to the current agent's scope."
  ;; Change "b" to "B" to allow possibly nonexistent buffer names
  (interactive "BAdd buffer to current agent's scope: ")
  (let ((buf-name (if (stringp buffer) buffer (buffer-name buffer))))
    ;; Physically create the buffer if it doesn't exist yet
    (get-buffer-create buf-name)
    
    (when macher-agent--persistent-context
      (let* ((contents (macher-context-contents macher-agent--persistent-context))
             (entry (assoc buf-name contents)))
        (unless entry
          (let ((orig (with-current-buffer buf-name
                        (buffer-substring-no-properties (point-min) (point-max)))))
            (setf (macher-context-contents macher-agent--persistent-context)
                  (cons (cons buf-name (cons orig nil)) contents))))))
    (message "SUCCESS: Added '%s' to the agent's restricted scope." buf-name)))

(defun macher-agent--resolve-buffer-name (name)
  "Return the clean buffer name. Prefix forcing is removed as scope is handled explicitly."
  (substring-no-properties name))

;;;###autoload
(defun macher-agent-add-subagent (name dir &optional _display context)
  "Create a new sub-agent buffer completely silently.
No workspace path or system directives are printed to the buffer.
If CONTEXT is provided, the sub-agent inherits the persistent context."
  (let* ((buf-name (format "*macher-agent: %s*" name))
         (buf (get-buffer-create buf-name))
         (safe-dir (if (and dir (stringp dir)) dir (or default-directory "~/")))
         (full-dir (file-name-as-directory (expand-file-name safe-dir))))

    (with-current-buffer buf
      ;; 1. Internal State (Invisible but critical for tools)
      (setq default-directory full-dir)
      (setq-local macher-agent--is-workspace t)
      (setq-local macher--workspace (cons 'agent full-dir))
      (when context
        (setq-local macher-agent--persistent-context context))

      ;; 2. Clean Mode Initialisation
      (unless (derived-mode-p 'markdown-mode)
        (markdown-mode))
      (unless gptel-mode
        (gptel-mode 1))

      ;; 3. Apply the worker preset silently in the background
      (when (assoc "macher-agent-worker" gptel-directives)
        (setq-local gptel--system-message (alist-get "macher-agent-worker" gptel-directives))
        (make-local-variable 'gptel-tools)
        (setq gptel-tools '("read_file_in_workspace" 
                            "list_directory_in_workspace" 
                            "search_in_workspace"
                            "submit_task_result"))))

    ;; 4. Keep the global tracking updated
    (when (boundp 'macher-agent-active-subagents)
      (push (cons name full-dir) macher-agent-active-subagents))

    buf))

(provide 'macher-agent-orchestration)
;;; macher-agent-orchestration.el ends here
