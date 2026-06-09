;;; macher-agent-gptel-bridge.el --- Clean gptel boundary -*- lexical-binding: t; -*-

(require 'gptel)
(require 'macher)
(require 'macher-agent-vfs-client)

(declare-function macher-agent-resolve-context "macher-agent-vfs-client")
(declare-function macher-agent--auto-sync-context "macher-agent-vfs-client")
(declare-function macher-agent--split-context "macher-agent-vfs-client")
(declare-function macher-agent--build-virtual-patch "macher-agent-vfs-client")
(declare-function macher-agent--reap-buffer "macher-agent-orchestration")
(declare-function macher-agent-initialize-skills "macher-agent-api")

(defun macher-agent-sync-prompt-transformer (prompt)
  "Synchronise the active virtual file system state and registries before the prompt is sent."
  (let* ((macher-agent--allow-lazy-init t)
         (ctx (macher-agent-resolve-context)))
    (when ctx
      (macher-agent--auto-sync-context ctx)
      (when (fboundp 'macher-agent-initialize-skills)
        (macher-agent-initialize-skills ctx))))
  prompt)

(defun macher-agent-post-response-reaper (_beg _end)
  "Cleanly reap the sub-agent buffer if flagged for disposal."
  (when (and (macher-agent-subagent-p)
             (macher-agent-ready-to-reap-p))
    (let ((buf (current-buffer)))
      (run-at-time 0 nil (lambda ()
                           (when (and (buffer-live-p buf)
                                      (fboundp 'macher-agent--reap-buffer))
                             (macher-agent--reap-buffer buf)))))))

(defun macher-agent-gptel-transmit (task-context callbacks)
  "Facade to transmit network request, attaching async-safe local hooks."
  (let* ((target-buffer (macher-agent-task-context-target-buffer task-context))
         (sys-msg (macher-agent-task-context-system-message task-context))
         (success-cb (plist-get callbacks :on-success))
         (error-cb (plist-get callbacks :on-error)))
    
    (with-current-buffer target-buffer
      (setq-local gptel--system-message sys-msg)
      
      (let ((transform-hook nil))
        (setq transform-hook
              (lambda (async-fn fsm)
                (setq-local macher--fsm-latest fsm)
                (funcall async-fn)
                (remove-hook 'gptel-prompt-transform-functions transform-hook t)))
        (add-hook 'gptel-prompt-transform-functions transform-hook nil t))

      (let ((response-hook nil))
        (setq response-hook
              (lambda (_beg _end)
                (let ((res (string-trim (buffer-substring-no-properties (point-min) (point-max)))))
                  
                  
                  (if (and (macher-agent-subagent-p)
                           (not (string-empty-p res)))
                      (message "DEBUG BRIDGE: Stream ended for sub-agent. Deferring to tool execution...")
                    
                    (if (not (string-empty-p res))
                        (when success-cb (funcall success-cb res))
                      (when error-cb (funcall error-cb "Buffer stopped silently or returned empty.")))
                    
                    (remove-hook 'gptel-post-response-functions response-hook t)))))
        (add-hook 'gptel-post-response-functions response-hook nil t))

      (gptel-send))))

(defun macher-agent--setup-tools-advice (orig-fn &rest args)
  "Sync the VFS and inject the sandbox session before tools are executed."
  (let* ((fsm (car args))
         (info (when fsm (gptel-fsm-info fsm)))
         (ctx (bound-and-true-p macher-agent--persistent-context)))
    (when ctx
      (when (fboundp 'macher-agent--auto-sync-context)
        (macher-agent--auto-sync-context ctx))
      (when fsm
        (let ((session (or (plist-get info :macher-agent-session)
                           (let* ((ws (macher-agent--get-context-workspace ctx))
                                  (proj-root (if ws (macher-agent-root ws) default-directory))
                                  (agent-ws (make-macher-agent-workspace :project-root proj-root)))
                             (make-macher-agent-session :id (buffer-name) :workspace agent-ws)))))
          (setf (gptel-fsm-info fsm) (plist-put info :macher-agent-session session))))))
  (apply orig-fn args))

;; --- Media Injection Hook ---

(defun macher-agent--inject-media-fsm-advice (orig-fun fsm &rest args)
  "Inject pending tool media into the FSM payload right before it hits the network."
  (let* ((info (macher-agent--extract-fsm-info fsm))
         (session (plist-get info :macher-agent-session))
         (pending (when session (macher-agent-session-pending-media session))))
    
    (when pending
      (let* ((msg-plist (list :role "user" 
                              :content "Tool execution complete. Here is the requested visual data:"))
             (prompts (list msg-plist))
             (gptel-context pending))
        
        ;; Have gptel natively encode the image to base64 JSON payload
        (when (fboundp 'gptel--inject-media)
          (gptel--inject-media (plist-get info :backend) prompts))
        
        ;; Inject directly into the raw API payload data
        (when (fboundp 'gptel--inject-prompt)
          (gptel--inject-prompt (plist-get info :backend) 
                                (plist-get info :data) 
                                (car prompts)))
        
        ;; Clear the queue for this session so we don't send the image twice
        (setf (macher-agent-session-pending-media session) nil)))
    
    ;; Continue with the actual network request
    (apply orig-fun fsm args)))

(advice-add 'gptel--handle-wait :around #'macher-agent--inject-media-fsm-advice)

(defun macher-agent--make-safe-callback (orig-cb)
  "Closure generator: captures orig-cb so it survives async network delays."
  (lambda (response &rest cb-args)
    (apply orig-cb (or response "") cb-args)))

(defvar macher-agent--captured-buffer-tools nil
  "Dynamic snapshot of buffer tools.")

(defun macher-agent--protect-nil-responses (orig-fun response info &optional raw)
  "Prevent nil string crashes at the point of insertion."
  (funcall orig-fun (or response "") info raw))

(advice-add 'gptel--insert-response :around #'macher-agent--protect-nil-responses)
(advice-add 'gptel-curl--stream-insert-response :around #'macher-agent--protect-nil-responses)

(defvar macher-agent--allow-gptel-restore nil
  "Dynamic variable controlling whether `gptel--restore-state' is allowed to execute.")

(defun macher-agent--gptel-restore-advice (orig-fun &rest args)
  "Bypass `gptel--restore-state' unless explicitly allowed."
  (when macher-agent--allow-gptel-restore
    (let ((current-root (macher-agent-root nil)))
      (when (and current-root (fboundp 'macher-agent--init-workspace-state))
        (macher-agent--init-workspace-state current-root)))
    (let ((ctx (when (fboundp 'macher-agent-resolve-context)
                 (macher-agent-resolve-context))))
      (when ctx
        (macher-agent-initialize-skills ctx)))
    (apply orig-fun args)))

;; Advise the actual internal function that gptel uses on mode startup
(advice-add 'gptel--restore-state :around #'macher-agent--gptel-restore-advice)

(defun macher-agent-resolve-backend-and-model (model-name)
  "Find the first backend and model format matching MODEL-NAME.
MODEL-NAME can be a string or a symbol.
Returns a cons cell (BACKEND . MODEL-FORMAT) if found, otherwise nil."
  (when (and model-name (boundp 'gptel--known-backends))
    (let ((model-str (if (symbolp model-name) (symbol-name model-name) model-name))
          result)
      (dolist (item gptel--known-backends)
        (unless result
          (let* ((backend (cdr item))
                 (models (gptel-backend-models backend)))
            (dolist (m models)
              (unless result
                (let* ((m-raw (if (consp m) (car m) m))
                       (m-str (if (symbolp m-raw) (symbol-name m-raw) m-raw)))
                  (when (equal m-str model-str)
                    (setq result (cons backend m-raw)))))))))
      result)))

(defun macher-agent--after-apply-preset-advice (preset &rest _)
  "Ensure gptel-tools is resolved to structs, includes default tools, and is deduplicated.
Also aligns `gptel-backend` with `gptel-model` if the model belongs to a different backend."
  (when (boundp 'gptel-tools)
    (let* ((default-tools (default-value 'gptel-tools))
           (clean-sym (macher-normalise-preset-name preset))
           (preset-tools nil))
      (when clean-sym
        (setq-local macher-agent--active-skill-sym clean-sym)
        (when (boundp 'gptel--known-presets)
          (let* ((spec (alist-get clean-sym gptel--known-presets))
                 (tools (plist-get spec :tools)))
            (when (and tools (eq (car tools) :append))
              (setq preset-tools (cdr tools))))))
      (setq-local gptel-tools (macher-agent-normalize-tools (append default-tools gptel-tools preset-tools)))))

  ;; Auto-resolve and align backend when `gptel-model' is updated via a preset
  (when (bound-and-true-p gptel-model)
    (let ((resolved (macher-agent-resolve-backend-and-model gptel-model)))
      (when resolved
        (let ((backend (car resolved))
              (model-format (cdr resolved)))
          (unless (eq gptel-backend backend)
            (setq-local gptel-backend backend))
          (unless (eq gptel-model model-format)
            (setq-local gptel-model model-format)))))))

(advice-add 'gptel--apply-preset :after #'macher-agent--after-apply-preset-advice)

(defvar macher-agent--active-fsm nil
  "Dynamically bound to the active FSM during tool execution hooks.")

(defun macher-agent--bind-active-fsm-advice (orig-fn fsm &rest args)
  "Capture the current FSM dynamically so tool validators do not rely on lagging state variables."
  (let ((macher-agent--active-fsm fsm))
    (apply orig-fn fsm args)))

;; Advise both pre and post hooks to guarantee the FSM is always available
(advice-add 'gptel--handle-pre-tool :around #'macher-agent--bind-active-fsm-advice)
(advice-add 'gptel--handle-post-tool :around #'macher-agent--bind-active-fsm-advice)

(defun macher-agent--enforce-tool-scope (tool &rest _args)
  "Enforce that TOOL is explicitly within the buffer-local `gptel-tools'
or the active request FSM.
If not, block execution to prevent hallucinated or globally-leaked tools."
  (let* ((tool-name (cond ((stringp tool) tool)
                          ((and (fboundp 'gptel-tool-p) (gptel-tool-p tool))
                           (gptel-tool-name tool))
                          ((and (listp tool) (plist-get tool :name))
                           (plist-get tool :name))
                          ((and (listp tool) (plist-get tool :function))
                           (let ((fn (plist-get tool :function)))
                             (if (listp fn) (plist-get fn :name) fn)))
                          ((symbolp tool) (symbol-name tool))
                          (t (format "%s" tool))))
         
         (fsm (or macher-agent--active-fsm
                  (bound-and-true-p macher--fsm-latest)
                  (bound-and-true-p gptel--fsm-last)))
         (info (when fsm (gptel-fsm-info fsm)))
         
         (fsm-tools (when info (plist-get info :tools)))
         
         (in-fsm (and fsm-tools
                      (cl-find tool-name fsm-tools
                               :key (lambda (t_) 
                                      (if (and (fboundp 'gptel-tool-p) (gptel-tool-p t_))
                                          (gptel-tool-name t_)
                                        (format "%s" t_)))
                               :test #'string=)))
         
         (local-tool (or in-fsm
                         (and (boundp 'gptel-tools)
                              (cl-find tool-name gptel-tools
                                       :key (lambda (t_) 
                                              (if (and (fboundp 'gptel-tool-p) (gptel-tool-p t_))
                                                  (gptel-tool-name t_)
                                                (format "%s" t_)))
                                       :test #'string=)))))
    (unless local-tool
      (list :block (format "ERROR: Tool '%s' is out of scope. It was not provided to this sub-agent." tool-name)))))

(defun macher-agent-setup-gptel-buffer ()
  "Set up a gptel buffer with macher-agent capabilities if in an active agent session."
  (let* ((macher-agent--allow-lazy-init nil)
         (ctx (ignore-errors (macher-agent-resolve-context))))
    (when ctx
      (add-hook 'gptel-prompt-transform-functions #'macher-agent-sync-prompt-transformer nil t)
      (add-hook 'gptel-pre-tool-call-functions #'macher-agent--enforce-tool-scope nil t))))

(add-hook 'gptel-mode-hook #'macher-agent-setup-gptel-buffer)

(provide 'macher-agent-gptel-bridge)
