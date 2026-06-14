;;; macher-agent-gptel-bridge.el --- Clean gptel boundary -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'gptel)
(require 'macher)
(require 'macher-agent-vfs-client)

(declare-function macher-agent-resolve-context "macher-agent-vfs-client")
(declare-function macher-agent--auto-sync-context "macher-agent-vfs-client")
(declare-function macher-agent--split-context "macher-agent-vfs-client")
(declare-function macher-agent--build-virtual-patch "macher-agent-vfs-client")
(declare-function macher-agent--reap-buffer "macher-agent-orchestration")
(declare-function macher-agent-initialize-skills "macher-agent-api")
(declare-function macher-agent-canonical-tool-name "macher-agent-api")

(defun macher-agent-sync-prompt-transformer (async-fn fsm)
  "Synchronise the virtual file system, normalise the active tools list,
and compose skill profiles securely.

This function acts exclusively as a pre-wire transformer. It executes
strictly within the temporary transmission buffer managed by the system.
It parses and strips inline skill tags locally, preventing destructive
side effects to the user's source buffer. It then invokes the pure
composition engine to merge the base state with the inline presets,
applying the resulting transmission state ephemerally before network dispatch."
  (let* ((info (when fsm (gptel-fsm-info fsm)))
         (orig-buf (or (when info (plist-get info :buffer)) (current-buffer)))
         (macher-agent--allow-lazy-init t)
         (ctx (macher-agent-resolve-context fsm)))

    (when (and fsm ctx)
      (setf (gptel-fsm-info fsm)
            (plist-put (gptel-fsm-info fsm) :macher-agent-context ctx)))

    (when ctx
      (with-current-buffer orig-buf
        (macher-agent--auto-sync-context ctx)
        (when (fboundp 'macher-agent-initialize-skills)
          (macher-agent-initialize-skills ctx))))

    (let ((matched-skills nil))
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward "@\\([[:alnum:]_-]+\\)\\b\\s-*" nil t)
          (push (intern (match-string-no-properties 1)) matched-skills)
          (replace-match "")))

      (unless matched-skills
        (let ((active-sys (with-current-buffer orig-buf gptel--system-message))
              (directives (with-current-buffer orig-buf gptel-directives)))
          (when-let* ((sym (cl-loop for (s . sys) in directives
                                    when (equal sys active-sys) return s)))
            (push sym matched-skills))))

      (let* ((base-state
              (with-current-buffer orig-buf
                (list :model gptel-model
                      :system gptel--system-message
                      :temperature (bound-and-true-p gptel-temperature)
                      :max-tokens (bound-and-true-p gptel-max-tokens)
                      :tools gptel-tools
                      :known-presets (bound-and-true-p gptel--known-presets))))
             (presets (with-current-buffer orig-buf (bound-and-true-p macher-agent-presets)))
             (payload (when (fboundp 'macher-agent-compose-payload)
                        (macher-agent-compose-payload base-state (append presets (nreverse matched-skills))))))

        (when payload
          (setq-local gptel--system-message (plist-get payload :system))
          (setq-local gptel-model (plist-get payload :model))
          (setq-local gptel-temperature (plist-get payload :temperature))
          (setq-local gptel-max-tokens (plist-get payload :max-tokens))
          (setq-local gptel-tools (plist-get payload :tools)))
          
        (when info
          (plist-put (gptel-fsm-info fsm) :tools 
                     (mapcar #'macher-agent-canonical-tool-name gptel-tools)))))

    (when (and async-fn (functionp async-fn))
      (funcall async-fn))))


(defun macher-agent-post-response-reaper (_beg _end)
  "Reap the sub-agent buffer if flagged for disposal."
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
         (error-cb (plist-get callbacks :on-error))
         (ctx (ignore-errors (macher-agent-resolve-context))))
    
    (with-current-buffer target-buffer
      (setq-local gptel--system-message sys-msg)
      
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
        
        (when (fboundp 'gptel--inject-media)
          (gptel--inject-media (plist-get info :backend) prompts))
        
        (when (fboundp 'gptel--inject-prompt)
          (gptel--inject-prompt (plist-get info :backend) 
                                (plist-get info :data) 
                                (car prompts)))
        
        (setf (macher-agent-session-pending-media session) nil)))
    
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

(defvar macher-agent--active-fsm nil
  "Dynamically bound to the active FSM during tool execution hooks.")

(defun macher-agent--bind-active-fsm-advice (orig-fn fsm &rest args)
  "Capture the current FSM dynamically so tool validators do not rely on lagging state variables."
  (let ((macher-agent--active-fsm fsm))
    (apply orig-fn fsm args)))

(advice-add 'gptel--handle-pre-tool :around #'macher-agent--bind-active-fsm-advice)
(advice-add 'gptel--handle-post-tool :around #'macher-agent--bind-active-fsm-advice)

(defun macher-agent--enforce-tool-scope (tool &rest _args)
  "Enforce that TOOL is explicitly within the authorised scope.
If not, block execution to prevent hallucinated or globally-leaked tools.

To robustly validate the tool across execution boundaries (including
asynchronous callbacks and temporary buffer switches), the function
retrieves the active finite state machine (FSM) or fallback references
and compares the incoming tool against the authorised toolset.

It reads the tool names exclusively from the finite state machine snapshot,
ignoring buffer-local variables to avoid race conditions."
  (let* ((canonical-name (macher-agent-canonical-tool-name tool))
         (fsm (or macher-agent--active-fsm
                  (bound-and-true-p macher--fsm-latest)
                  (bound-and-true-p gptel--fsm-last)))
         (info (when fsm (gptel-fsm-info fsm)))
         (fsm-tools (when info (plist-get info :tools)))
         (authorised-names
          (mapcar #'macher-agent-canonical-tool-name fsm-tools)))
    (unless (and canonical-name (member canonical-name authorised-names))
      (list :block (format "ERROR: Tool '%s' is out of scope. It was not provided to this sub-agent." (or canonical-name tool))))))

(defun macher-agent-setup-gptel-buffer ()
  "Set up a gptel buffer with macher-agent capabilities if in an active agent session."
  (let* ((macher-agent--allow-lazy-init nil)
         (ctx (ignore-errors (macher-agent-resolve-context))))
    (when ctx
      (add-hook 'gptel-prompt-transform-functions #'macher-agent-sync-prompt-transformer nil t)
      (add-hook 'gptel-pre-tool-call-functions #'macher-agent--enforce-tool-scope nil t))))

(add-hook 'gptel-mode-hook #'macher-agent-setup-gptel-buffer)

(provide 'macher-agent-gptel-bridge)
