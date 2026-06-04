;;; macher-agent-orchestration.el --- Interactive sub-agent commands -*- lexical-binding: t; -*-

(require 'macher)
(require 'macher-agent-macher-bridge)
(require 'gptel nil t)
(require 'macher-agent-vfs-client)

(declare-function macher-agent-gptel-transmit "macher-agent-gptel-bridge" (task-context callbacks))
(declare-function macher-agent--set-system-message "macher-agent-gptel-tools" (msg))
(declare-function macher-agent-current-context "macher-agent-vfs-client")
(declare-function macher-agent--init-workspace-state "macher-agent-vfs-client")
(declare-function macher-agent--auto-sync-context "macher-agent-vfs-client" (&optional ctx fsm))

(defvar macher-agent-submit-task-result-tool)

(cl-defstruct macher-agent-task-context
  workspace
  target-buffer
  skill-sym
  system-message)

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

(defvar macher-agent--garbage-queue nil
  "List of buffers queued for background garbage collection.")

(defun macher-agent--reap-buffers-on-idle ()
  "Silently reap any sub-agent buffers queued in the garbage queue."
  (while macher-agent--garbage-queue
    (let ((buf (pop macher-agent--garbage-queue)))
      (when (buffer-live-p buf)
        (ignore-errors
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf)))))))

;; Ensure the timer is running
(defvar macher-agent--reaper-timer nil)
(when macher-agent--reaper-timer 
  (cancel-timer macher-agent--reaper-timer))
(setq macher-agent--reaper-timer 
      (run-with-idle-timer 0.5 t #'macher-agent--reap-buffers-on-idle))

(run-with-idle-timer 0.5 t #'macher-agent--reap-buffers-on-idle)

(defun macher-agent--apply-preset (preset)
  "Apply the PRESET directive securely, flawlessly merging buffer and preset tools."
  (when-let* ((profile (macher-agent-resolve-skill-profile preset))
              (skill-data (plist-get profile :data)))
    
    (let* ((tools (plist-get skill-data :tools))
           (safe-skill-data (macher-agent-sanitise-skill-data skill-data)))
      
      (when safe-skill-data
        (let ((gptel--known-presets (list (cons preset safe-skill-data))))
          (gptel--apply-preset preset (lambda (sym val) (set (make-local-variable sym) val)))))
      
      (unless (boundp 'gptel-tools) (setq gptel-tools nil))
      (make-local-variable 'gptel-tools)
      (setq gptel-tools (macher-agent-deduplicate-tools (append gptel-tools tools))))))

(defun macher-agent-spawn-task (task callback)
  "Spawn a task inside a target subagent."
  (let* ((buf-name (if (listp task) (plist-get task :buffer_name) task))
         (instructions (if (listp task) (plist-get task :instructions) ""))
         (preset (if (listp task) (plist-get task :preset) nil))
         (buf (get-buffer buf-name)))
    (if (not buf)
        (funcall callback (list :status 'error :error (format "ERROR: Sub-agent buffer '%s' not found." buf-name) :buffer_name buf-name))
      (macher-agent--prepare-subagent-instructions buf instructions preset)
      (with-current-buffer buf
        (macher-agent--show-ui buf)
        (setq-local macher-agent--parent-callback callback)
        
        (let* ((profile (macher-agent-resolve-skill-profile preset))
               (final-sym (plist-get profile :sym))
               (skill-data (plist-get profile :data))
               (task-ctx (make-macher-agent-task-context
                          :workspace nil
                          :target-buffer buf
                          :skill-sym final-sym
                          :system-message (if skill-data (plist-get skill-data :system) gptel--system-message))))
          (macher-agent-gptel-transmit
           task-ctx
           (list :on-success (lambda (res)
                               (funcall callback (list :status 'success :data res :buffer_name buf-name))
                               (push buf macher-agent--garbage-queue))
                 :on-error (lambda (err)
                             (funcall callback (list :status 'error :error (format "ERROR: %s" err) :buffer_name buf-name))
                             (push buf macher-agent--garbage-queue)))))))))

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

(defun macher-agent--prepare-subagent-buffer (buf full-dir context &optional preset parent-tools parent-model parent-backend)
  "Prepare a subagent buffer, locking its directory strictly to the workspace root."
  (with-current-buffer buf
    (setq default-directory (file-name-as-directory (macher-agent--get-project-root full-dir)))
    
    (when (and (fboundp 'markdown-mode) (not (derived-mode-p 'markdown-mode)))
      (markdown-mode))
    (when (and (fboundp 'gptel-mode) (not gptel-mode))
      (gptel-mode 1))
    
    (setq-local gptel-stream nil)
    (setq-local macher-agent--is-subagent t)
    
    (when parent-model (setq-local gptel-model parent-model))
    (when parent-backend (setq-local gptel-backend parent-backend))
    
    (unless (boundp 'gptel-tools) (setq gptel-tools nil))
    (make-local-variable 'gptel-tools)
    
    (when parent-tools
      (setq gptel-tools (macher-agent-deduplicate-tools (append gptel-tools parent-tools))))
    
    (when preset
      (macher-agent--apply-preset preset))
    
    (run-hooks 'macher-agent-subagent-setup-hook)))

;;;###autoload
(defun macher-agent-add-subagent (name dir &optional instructions context preset)
  "Create and prepare a new subagent buffer, inheriting parent state."
  (let* ((parent-tools (bound-and-true-p gptel-tools))
         ;; Capture the parent's model and backend
         (parent-model (bound-and-true-p gptel-model))
         (parent-backend (bound-and-true-p gptel-backend))
         (buf (get-buffer-create name)))
    
    ;; Pass them into the preparation buffer
    (macher-agent--prepare-subagent-buffer buf dir context preset parent-tools parent-model parent-backend)
    
    (when context
      (let ((workspace (macher-agent--get-context-workspace context)))
        (when workspace
          (push (cons name buf) (macher-agent-workspace-active-subagents workspace))))
      (macher-agent-scope-add-file name context))
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
              (insert new-content))))))
    (macher-agent--auto-sync-context ctx)
    (message "Virtual buffers applied successfully.")))

(defun macher-agent--prepare-subagent-instructions (buf instructions &optional preset)
  "Insert INSTRUCTIONS into BUF and strictly bind its preset system message."
  (with-current-buffer buf
    (erase-buffer)
    (unless (string-empty-p instructions)
      (insert (substring-no-properties instructions)))
    (when preset
      (macher-agent--apply-preset preset))))

(add-hook 'gptel-pre-response-hook
          (lambda ()
            (let ((ctx (ignore-errors (macher-agent-current-context))))
              (when ctx (macher-agent--auto-sync-context ctx)))
            (when (fboundp 'macher-agent--compose-active-skills)
              (macher-agent--compose-active-skills))))

(provide 'macher-agent-orchestration)
