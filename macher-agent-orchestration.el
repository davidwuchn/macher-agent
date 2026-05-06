;;; macher-agent-orchestration.el --- Interactive sub-agent commands -*- lexical-binding: t; -*-

(defun macher-agent--resolve-buffer-name (name)
  "Ensure the buffer name has the correct macher-agent prefix."
  (let ((name-str (substring-no-properties name)))
    (if (string-prefix-p "*macher-agent:" name-str)
        name-str
      (format "*macher-agent: %s*" name-str))))

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
         ;; FIX: Protect against nil directories from async temp buffers
         (safe-dir (if (and dir (stringp dir)) dir (or default-directory "~/")))
         (has-dir (not (string-empty-p safe-dir)))
         (full-dir (when has-dir (file-name-as-directory (expand-file-name safe-dir)))))
    
    (with-current-buffer buf
      (when has-dir
        (setq default-directory full-dir)
        ;; 1. Activate the flag so our project.el hook intercepts the scanner
        (setq-local macher-agent--is-workspace t)
        ;; 2. Feed macher the standard string format it natively expects
        (setq-local macher--workspace (cons 'project full-dir)))
      (markdown-mode)
      (gptel-mode 1)
      (insert (format "# Sub-Agent: %s\nWorkspace: %s\n\n" name (if has-dir full-dir "None (Stateless Chat)"))))

    (push (cons name (or full-dir "None")) macher-agent-active-subagents)
    
    (unless no-inject
      (with-current-buffer parent-buf
        (when (derived-mode-p 'gptel-mode 'markdown-mode 'org-mode 'text-mode)
          (save-excursion
            (goto-char (point-max))
            (let ((start (point)))
              (insert (format "\n\n[SYSTEM DIRECTIVE: A sub-agent named '%s' has been instantiated%s. You can dispatch tasks to it using the 'write_to_buffer' tool followed by 'execute_subagent_buffer_blocking'. The exact buffer_name to use is '%s'.]\n\n" 
                              name 
                              (if has-dir (format " and locked to '%s'" full-dir) " for stateless reasoning") 
                              buf-name))
              (put-text-property start (point) 'invisible t)
              (put-text-property start (point) 'intangible t)
              (put-text-property start (point) 'rear-nonsticky t))))))
    
    (message "Instantiated sub-agent: %s" buf-name)))

(provide 'macher-agent-orchestration)
;;; macher-agent-orchestration.el ends here
