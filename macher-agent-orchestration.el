;;; macher-agent-orchestration.el --- Interactive sub-agent commands -*- lexical-binding: t; -*-

(require 'macher)
(require 'macher-agent-macher-bridge)
(require 'gptel nil t)
(require 'macher-agent-vfs-client)

(declare-function macher-agent-gptel-transmit "macher-agent-gptel-bridge" (task-context callbacks))
(declare-function macher-agent-sync-prompt-transformer "macher-agent-gptel-bridge" (prompt))
(declare-function macher-agent-post-response-reaper "macher-agent-gptel-bridge" (beg end))
(declare-function macher-agent--set-system-message "macher-agent-gptel-tools" (msg))
(declare-function macher-agent-resolve-context "macher-agent-vfs-client")
(declare-function macher-agent--inject-context-state "macher-agent-vfs-client" (context &optional directives))
(declare-function macher-agent--init-workspace-state "macher-agent-vfs-client")
(declare-function macher-agent--auto-sync-context "macher-agent-vfs-client" (&optional ctx fsm))
(declare-function macher-agent-vfs-entry-path "macher-agent-vfs-client")
(declare-function macher-agent-vfs-entry-curr "macher-agent-vfs-client")

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

(defun macher-agent-subagent-p (&optional buffer)
  "Return non-nil if BUFFER is a subagent."
  (with-current-buffer (or buffer (current-buffer))
    (bound-and-true-p macher-agent--is-subagent)))

(defun macher-agent-ready-to-reap-p (&optional buffer)
  "Return non-nil if BUFFER is ready to be reaped."
  (with-current-buffer (or buffer (current-buffer))
    (bound-and-true-p macher-agent--ready-to-reap)))

(defun macher-agent--reap-buffer (buf)
  "A garbage collector that natively aborts hidden gptel networks."
  (condition-case nil
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (when (and (macher-agent-subagent-p)
                     (macher-agent-ready-to-reap-p))
            
            (set-buffer-modified-p nil)

            (when (fboundp 'gptel-abort)
              (ignore-errors (gptel-abort)))

            (dolist (proc (process-list))
              (let* ((p-buf (process-buffer proc))
                     (target-buf nil))
                
                (when (and p-buf (buffer-live-p p-buf))
                  (with-current-buffer p-buf
                    (setq target-buf
                          (or (when (bound-and-true-p gptel--info)
                                (plist-get gptel--info :buffer))
                              (when (and (boundp 'gptel--fsm) gptel--fsm (fboundp 'gptel-fsm-info))
                                (plist-get (gptel-fsm-info gptel--fsm) :buffer))))))

                (when (or (eq p-buf buf)
                          (eq target-buf buf))
                  (set-process-query-on-exit-flag proc nil)
                  (set-process-sentinel proc nil)
                  (delete-process proc))))

            (let ((kill-buffer-query-functions nil)
                  (kill-buffer-hook nil))
              (kill-buffer buf)))))
    ((error quit) nil)))

(defun macher-agent--apply-preset (preset)
  "Apply the PRESET directive, safely merging buffer and preset tools."
  (let* ((clean-sym (if (fboundp 'macher-normalise-preset-name)
                        (macher-normalise-preset-name preset)
                      (if (stringp preset) (intern preset) preset)))
         (spec (when (and clean-sym (boundp 'gptel--known-presets)) 
                 (alist-get clean-sym gptel--known-presets))))
    
    (when spec
      (setq-local macher-agent--active-skill-sym clean-sym)
      (setq-local gptel--preset clean-sym)
      
      (let ((system-msg (or (plist-get spec :system)
                            (plist-get spec :system-message)))
            (model (plist-get spec :model))
            (backend (plist-get spec :backend))
            (temp (plist-get spec :temperature))
            (tokens (plist-get spec :max-tokens))
            (tools (plist-get spec :tools)))
        
        (when system-msg (setq-local gptel--system-message system-msg))
        (when model (setq-local gptel-model model))
        (when backend (setq-local gptel-backend backend))
        (when temp (setq-local gptel-temperature temp))
        (when tokens (setq-local gptel-max-tokens tokens))
        
        (when tools
          (let* ((actual-tools (if (and (consp tools) (eq (car tools) :append)) 
                                   (cdr tools) 
                                 tools))
                 (default-tools (default-value 'gptel-tools)))
            (setq-local gptel-tools 
                        (macher-agent-normalize-tools 
                         (append default-tools gptel-tools actual-tools)))))))))

(defvar macher-agent--is-subagent nil)
(defvar macher-agent--ready-to-reap nil)

(put 'macher-agent--is-subagent 'permanent-local t)
(put 'macher-agent--ready-to-reap 'permanent-local t)

(defun macher-agent-spawn-task (task callback)
  "Spawn a task inside a target subagent."
  (let* ((buf-name (if (listp task) (plist-get task :buffer_name) task))
         (instructions (if (listp task) (plist-get task :instructions) ""))
         (preset (if (listp task) (plist-get task :preset) nil))
         (is-background (and (listp task) (plist-get task :background)))
         (buf (get-buffer buf-name)))
    (if (not buf)
        (funcall callback (make-macher-agent-delegate-response :status 'error :error (format "ERROR: Sub-agent buffer '%s' not found." buf-name) :buffer-name buf-name))
      (macher-agent--prepare-subagent-instructions buf instructions preset)
      (with-current-buffer buf
        (unless is-background
          (macher-agent--show-ui buf))
        
        (setq-local macher-agent--is-subagent t)
        
        (setq-local macher-agent--parent-callback 
                    (lambda (res)
                      (when (buffer-live-p buf)
                        (with-current-buffer buf 
                          (unless is-background
                            (setq-local macher-agent--ready-to-reap t))))
                      
                      (funcall callback res)))

        (let* ((raw-str (when preset (if (symbolp preset) (symbol-name preset) preset)))
               (clean-sym (when raw-str (intern (replace-regexp-in-string "^@+" "" raw-str))))
               (task-ctx (make-macher-agent-task-context
                          :workspace nil
                          :target-buffer buf
                          :skill-sym clean-sym
                          :system-message gptel--system-message)))
          
          (macher-agent-gptel-transmit
           task-ctx
           (list :on-success (lambda (res)
                               (funcall macher-agent--parent-callback (make-macher-agent-delegate-response :status 'success :data res :buffer-name buf-name)))
                 :on-error (lambda (err)
                             (funcall macher-agent--parent-callback (make-macher-agent-delegate-response :status 'error :error (format "ERROR: %s" err) :buffer-name buf-name))))))))))

(defvar macher-agent-subagent-setup-hook nil)

(defun macher-agent--add-buffer-to-scope-headless (buf-name persistent-context)
  (get-buffer-create buf-name)
  (when persistent-context
    (let* ((contents (macher-agent--get-context-contents persistent-context))
           (entry (cl-find buf-name contents :key #'macher-agent-vfs-entry-path :test #'equal)))
      (unless entry
        (let ((orig (with-current-buffer buf-name (buffer-substring-no-properties (point-min) (point-max)))))
          (macher-agent--set-context-contents persistent-context
                                              (cons (macher-agent-vfs-make-entry buf-name orig orig) contents))))))
  (run-hooks 'macher-agent-context-mutated-hook))

;;;###autoload
(defun macher-agent-add-buffer-to-scope (buffer)
  (interactive "BAdd buffer to current agent's scope: ")
  (let* ((buf-name (if (stringp buffer) buffer (buffer-name buffer)))
         (ctx (macher-agent-resolve-context)))
    (unless ctx
      (error "No active agent session found"))
    (macher-agent--add-buffer-to-scope-headless buf-name ctx)
    (message "SUCCESS: Added '%s' to the agent's restricted scope." buf-name)))

(defun macher-agent--resolve-buffer-name (name)
  (substring-no-properties name))

(defun macher-agent--prepare-subagent-buffer (buf full-dir context &optional preset parent-tools parent-model parent-backend parent-presets parent-directives parent-temp parent-tokens)
  "Prepare a subagent buffer, locking its directory to the workspace root."
  (with-current-buffer buf
    (setq default-directory (file-name-as-directory (macher-agent-root full-dir)))
    
    (when (and (fboundp 'markdown-mode) (not (derived-mode-p 'markdown-mode)))
      (markdown-mode))
    
    (setq-local macher-agent--is-subagent t)
    
    (when (and (fboundp 'gptel-mode) (not gptel-mode))
      (gptel-mode 1))
    
    (setq-local gptel-stream nil)
    
    (when context
      (macher-agent--inject-context-state context))
    
    (when parent-model (setq-local gptel-model parent-model))
    (when parent-backend (setq-local gptel-backend parent-backend))
    (when parent-presets (setq-local gptel--known-presets parent-presets))
    (when parent-directives (setq-local gptel-directives parent-directives))
    (when parent-temp (setq-local gptel-temperature parent-temp))
    (when parent-tokens (setq-local gptel-max-tokens parent-tokens))
    
    (unless (boundp 'gptel-tools) (setq gptel-tools nil))
    (make-local-variable 'gptel-tools)
    
    (when parent-tools
      (setq gptel-tools (macher-agent-normalize-tools (append gptel-tools parent-tools))))
    
    (when preset
      (macher-agent--apply-preset preset))
    
    (add-hook 'gptel-prompt-transform-functions #'macher-agent-sync-prompt-transformer nil t)
    (add-hook 'gptel-post-response-functions #'macher-agent-post-response-reaper nil t)
    
    (run-hooks 'macher-agent-subagent-setup-hook)))

;;;###autoload
(defun macher-agent-add-subagent (name dir &optional instructions context preset)
  "Create and prepare a new subagent buffer, inheriting parent state."
  (let* ((parent-tools (bound-and-true-p gptel-tools))
         (parent-model (bound-and-true-p gptel-model))
         (parent-backend (bound-and-true-p gptel-backend))
         (parent-presets (bound-and-true-p gptel--known-presets))
         (parent-directives (bound-and-true-p gptel-directives))
         (parent-temp (bound-and-true-p gptel-temperature))
         (parent-tokens (bound-and-true-p gptel-max-tokens))
         (buf (get-buffer-create name)))
    
    (macher-agent--prepare-subagent-buffer
     buf dir context preset parent-tools parent-model parent-backend
     parent-presets parent-directives parent-temp parent-tokens)
    
    (when context
      (let ((workspace (macher-agent--get-context-workspace context)))
        (when workspace
          (push (cons name buf) (macher-agent-workspace-active-subagents workspace))))
      (macher-agent-scope-add-file name context))
    buf))

(defun macher-agent-apply-virtual-buffers ()
  (interactive)
  (let* ((ctx (macher-agent-resolve-context))
         (contents (and ctx (macher-agent--get-context-contents ctx))))
    (when contents
      (dolist (entry contents)
        (let* ((path-or-buf (macher-agent-vfs-entry-path entry))
               (new-content (macher-agent-vfs-entry-curr entry)))
          (when (and new-content (get-buffer path-or-buf))
            (with-current-buffer (get-buffer path-or-buf)
              (erase-buffer)
              (insert new-content))))))
    (macher-agent--auto-sync-context ctx)
    (message "Virtual buffers applied successfully.")))

(defun macher-agent--prepare-subagent-instructions (buf instructions &optional preset)
  "Insert INSTRUCTIONS into BUF and bind its preset system message."
  (with-current-buffer buf
    (unless (string-empty-p instructions)
      (insert (substring-no-properties instructions)))
    (when preset
      (macher-agent--apply-preset preset))))

(add-hook 'gptel-pre-response-hook
          (lambda ()
            (let ((ctx (ignore-errors (macher-agent-resolve-context))))
              (when ctx (macher-agent--auto-sync-context ctx)))))

(provide 'macher-agent-orchestration)
