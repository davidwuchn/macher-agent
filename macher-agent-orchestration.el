;;; macher-agent-orchestration.el --- Interactive sub-agent commands -*- lexical-binding: t; -*-

(require 'macher)
(require 'macher-agent-macher-bridge)
(require 'gptel nil t)
(require 'macher-agent-vfs-client)

(declare-function macher-agent--set-system-message "macher-agent-gptel-tools" (msg))
(declare-function macher-agent-current-context "macher-agent-vfs-client")
(declare-function macher-agent--init-workspace-state "macher-agent-vfs-client")
(declare-function macher-agent--auto-sync-context "macher-agent-vfs-client" (&optional ctx fsm))

(defun macher-agent-execute-parallel (tasks final-callback)
  (let* ((task-list (append tasks nil))
         (total (length task-list))
         (completed 0)
         (results (make-list total nil)))
    (if (= total 0)
        (funcall final-callback nil)
      (cl-loop for task in task-list
               for index from 0
               do (let ((idx index))
                    (macher-agent-spawn-task 
                     task 
                     (lambda (result)
                       (setf (nth idx results) result)
                       (cl-incf completed)
                       (when (= completed total)
                         (funcall final-callback results)))))))))

(defun macher-agent-spawn-task (task callback)
  "Spawn a task inside a target subagent, heavily protected against deadlocks."
  (let* ((raw-buf-name (if (listp task) (plist-get task :buffer_name) task))
         (safe-buf-name (if (stringp raw-buf-name) raw-buf-name (format "unnamed-subagent-%s" (random 1000))))
         (buf-name (if (string-match-p "^\\*macher-agent:" safe-buf-name) safe-buf-name (format "*macher-agent: %s*" safe-buf-name)))
         (instructions (if (listp task) (plist-get task :instructions) ""))
         (preset (if (listp task) (plist-get task :preset) nil))
         (ctx (macher-agent-current-context))
         ;; CAPTURE PARENT CREDENTIALS TO PREVENT PROMPTING DEADLOCKS
         (parent-backend gptel-backend)
         (parent-model gptel-model)
         (buf (get-buffer buf-name)))
    
    (unless buf
      (setq buf (macher-agent-add-subagent (replace-regexp-in-string "^\\*macher-agent:[ ]*" "" safe-buf-name) default-directory nil ctx preset))
      (when ctx (macher-agent--add-buffer-to-scope-headless (buffer-name buf) ctx)))
    
    (if (not buf)
        (funcall callback (list :status 'error :error (format "ERROR: Failed to spawn sub-agent '%s'." buf-name) :buffer_name buf-name))
      (macher-agent--prepare-subagent-instructions buf instructions preset)
      (with-current-buffer buf
        ;; INJECT PARENT CREDENTIALS
        (when parent-backend (setq-local gptel-backend parent-backend))
        (when parent-model (setq-local gptel-model parent-model))
        
        (macher-agent--show-ui buf)
        (let ((response-hook nil)
              (transform-hook nil))
          (setq transform-hook
                (lambda (async-fn fsm)
                  (setq-local macher--fsm-latest fsm)
                  (funcall async-fn)))
          (add-hook 'gptel-prompt-transform-functions transform-hook nil t)
          
          (setq response-hook
                (lambda (_response _info)
                  (let ((res (buffer-local-value 'macher-agent--final-result buf)))
                    (if res
                        (funcall callback (list :status 'success :data res :buffer_name buf-name))
                      (let ((salvaged-text (with-current-buffer buf (buffer-substring-no-properties (point-min) (point-max)))))
                        (funcall callback (list :status 'success :data salvaged-text :buffer_name buf-name))))
                    (run-at-time 0.5 nil (lambda () (when (buffer-live-p buf) (kill-buffer buf)))))))
          (add-hook 'gptel-post-response-functions response-hook nil t)
          
          (condition-case err
              (gptel-send)
            (error
             (funcall callback (list :status 'error :error (format "Failed to start sub-agent: %s" err) :buffer_name buf-name)))))))))

(defvar macher-agent-subagent-setup-hook nil)

(defun macher-agent--add-buffer-to-scope-headless (buf-name persistent-context)
  (get-buffer-create buf-name)
  (when persistent-context
    (let* ((contents (macher-agent--get-context-contents persistent-context))
           (entry (assoc buf-name contents)))
      (unless entry
        (let ((orig (with-current-buffer buf-name (buffer-substring-no-properties (point-min) (point-max)))))
          (macher-agent--set-context-contents persistent-context
                                              (cons (cons buf-name (cons orig orig)) contents))))))
  (run-hooks 'macher-agent-context-mutated-hook))

;;;###autoload
(defun macher-agent-add-buffer-to-scope (buffer)
  (interactive "BAdd buffer to current agent's scope: ")
  (let* ((buf-name (if (stringp buffer) buffer (buffer-name buffer)))
         (ctx (macher-agent-current-context)))
    (macher-agent--add-buffer-to-scope-headless buf-name ctx)
    (message "SUCCESS: Added '%s' to the agent's restricted scope." buf-name)))

(defun macher-agent--resolve-buffer-name (name)
  (substring-no-properties name))

(defun macher-agent--prepare-subagent-buffer (buf full-dir context &optional preset)
  (with-current-buffer buf
    (setq default-directory full-dir)
    (macher-agent--init-workspace-state full-dir)
    (setq-local macher-agent--is-subagent t)
    (when context
      (setq-local macher-agent--persistent-context context))
    
    ;; Set the Anchor
    (setq-local macher-agent--active-skill-sym (if preset (intern preset) '\@macher-agent-worker))
    ;; Prefill System Prompt natively based on anchor
    (let ((meta (or (alist-get macher-agent--active-skill-sym macher-agent-global-skills-alist)
                    (when context (alist-get macher-agent--active-skill-sym (macher-agent-workspace-skills-alist (macher-agent--get-context-workspace context)))))))
      (setq-local gptel--system-message (or (plist-get meta :system) "")))
    
    (setq-local gptel-context--alist nil)
    (when (and (fboundp 'markdown-mode) (not (derived-mode-p 'markdown-mode)))
      (markdown-mode))
    (when (and (fboundp 'gptel-mode) (not gptel-mode))
      (gptel-mode 1))
    
    (run-hooks 'macher-agent-subagent-setup-hook)))

;;;###autoload
(defun macher-agent-add-subagent (name dir &optional _display context preset)
  (let* ((buf-name (format "*macher-agent: %s*" name))
         (buf (generate-new-buffer buf-name))
         (safe-dir (if (and dir (stringp dir)) dir default-directory))
         (full-dir (file-name-as-directory (expand-file-name safe-dir))))
    
    (macher-agent--prepare-subagent-buffer buf full-dir context preset)
    
    (let* ((workspace (when context (macher-agent--get-context-workspace context)))
           (subagents (if workspace (macher-agent-workspace-active-subagents workspace) nil)))
      (when workspace
        (setf (macher-agent-workspace-active-subagents workspace) (cons (cons name full-dir) subagents))))
    buf))

(defun macher-agent-apply-virtual-buffers ()
  (interactive)
  (let* ((ctx (macher-agent-current-context))
         (contents (and ctx (macher-agent--get-context-contents ctx))))
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

(defun macher-agent--gptel-abort-hook (&rest _)
  (when (and (boundp 'macher-agent--persistent-context)
             macher-agent--persistent-context
             (macher-agent--get-context-dirty-p macher-agent--persistent-context))
    (message "Generation aborted/failed. Salvaging pending virtual edits...")
    (macher-agent-force-review)))

(advice-add 'gptel-abort :after #'macher-agent--gptel-abort-hook)

(add-hook 'gptel-post-response-functions
          (lambda (_response info)
            (unless _response
              (macher-agent--gptel-abort-hook))))

(add-hook 'gptel-pre-response-functions
          (lambda (&rest _)
            (let ((ctx (macher-agent-current-context)))
              (when ctx (macher-agent--auto-sync-context ctx)))))

(provide 'macher-agent-orchestration)
