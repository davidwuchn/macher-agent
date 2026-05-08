;;; macher-agent-orchestration.el --- Interactive sub-agent commands -*- lexical-binding: t; -*-

(require 'macher)

(defvar-local macher-agent--scoped-buffers nil
  "An explicit list of buffer names this specific agent is allowed to access.")

;;;###autoload
(defun macher-agent-add-buffer-to-scope (buffer)
  "Manually add an existing Emacs BUFFER to the current agent's scope."
  (interactive "bAdd buffer to current agent's scope: ")
  (let ((buf-name (if (stringp buffer) buffer (buffer-name (get-buffer buffer)))))
    ;; Ensure the current buffer has its own local list
    (unless (local-variable-p 'macher-agent--scoped-buffers)
      (setq-local macher-agent--scoped-buffers nil))
    
    (add-to-list 'macher-agent--scoped-buffers buf-name)
    (message "SUCCESS: Added '%s' to the agent's restricted scope." buf-name)))

(defun macher-agent--resolve-buffer-name (name)
  "Return the clean buffer name. Prefix forcing is removed as scope is handled explicitly."
  (substring-no-properties name))

;;;###autoload
(defun macher-agent-add-subagent (name dir &optional no-inject)
  "Interactively instantiate an isolated sub-agent buffer for task delegation.
If DIR is empty, the agent is created as a stateless chat without file system access."
  (interactive
   (let* ((agent-name (read-string "Sub-agent name: "))
          (use-dir (y-or-n-p "Bind sub-agent to a workspace directory? "))
          (agent-dir (if use-dir (read-directory-name "Target directory: ") "")))
     (list agent-name agent-dir)))
  
  (let* ((buf-name (format "*macher-agent: %s*" name))
         (buf (get-buffer-create buf-name))
         (parent-buf (current-buffer))
         (safe-dir (if (and dir (stringp dir)) dir (or default-directory "~/")))
         (has-dir (not (string-empty-p safe-dir)))
         (full-dir (when has-dir (file-name-as-directory (expand-file-name safe-dir)))))

    ;; Track the sub-agent in the parent's explicit scope list
    (add-to-list 'macher-agent--scoped-buffers buf-name)
    
    (with-current-buffer buf
      (when has-dir
        (setq default-directory full-dir)
        (setq-local macher-agent--is-workspace t)
        ;; IDIOMATIC FIX: Use our safe 'agent workspace type, not 'project
        (setq-local macher--workspace (cons 'agent full-dir)))

      (condition-case err
          (progn
            (markdown-mode)
            (gptel-mode 1)
            ;; IDIOMATIC FIX: Automatically apply the strict worker preset
            (macher--apply-preset-locally 'macher-agent-worker))
        (error (message "Warning: Mode initialization had an error: %s" (error-message-string err))))

      (insert (format "# Sub-Agent: %s\nWorkspace: %s\n\n" name (if has-dir full-dir "None (Stateless Chat)"))))

    ;; Track the active subagent
    (push (cons name (or full-dir "None")) macher-agent-active-subagents)
    
    (unless no-inject
      (with-current-buffer parent-buf
        (when (derived-mode-p 'gptel-mode 'markdown-mode 'org-mode 'text-mode)
          (save-excursion
            (goto-char (point-max))
            (let ((start (point)))
              (insert (format "\n\n[SYSTEM DIRECTIVE: A sub-agent named '%s' has been instantiated%s. You can dispatch tasks to it using 'delegate_task_to_subagent'. The exact buffer_name to use is '%s'.]\n\n" 
                              name 
                              (if has-dir (format " and locked to '%s'" full-dir) " for stateless reasoning") 
                              buf-name))
              ;; Keep the hidden text properties so it doesn't clutter the user's view
              (put-text-property start (point) 'invisible t)
              (put-text-property start (point) 'intangible t)
              (put-text-property start (point) 'rear-nonsticky t))))))
    
    (message "Instantiated sub-agent: %s" buf-name)))

(provide 'macher-agent-orchestration)
;;; macher-agent-orchestration.el ends here
