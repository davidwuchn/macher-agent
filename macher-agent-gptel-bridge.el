;;; macher-agent-gptel-bridge.el --- Clean gptel boundary -*- lexical-binding: t; -*-

(require 'gptel)
(require 'macher)
(require 'macher-agent-vfs-client)

(declare-function macher-agent-current-context "macher-agent-vfs-client")
(declare-function macher-agent--auto-sync-context "macher-agent-vfs-client")
(declare-function macher-agent--split-context "macher-agent-vfs-client")
(declare-function macher-agent--build-virtual-patch "macher-agent-vfs-client")

(defun macher-agent--gptel-pre-send-advice (orig-fun &rest args)
  "Ensure the agent VFS is synchronised before sending."
  (let* ((macher-agent--allow-lazy-init t)
         (ctx (macher-agent-current-context)))
    (when ctx (macher-agent--auto-sync-context ctx)))
  (apply orig-fun args))

(advice-add 'gptel-send :around #'macher-agent--gptel-pre-send-advice)
(advice-add 'gptel-request :around #'macher-agent--gptel-pre-send-advice)

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
                  
                  
                  (if (and (bound-and-true-p macher-agent--is-subagent)
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
                                  (proj-root (if ws (macher-agent--get-workspace-root ws) default-directory))
                                  (agent-ws (make-macher-agent-workspace :project-root proj-root)))
                             (make-macher-agent-session :id (buffer-name) :workspace agent-ws)))))
          (setf (gptel-fsm-info fsm) (plist-put info :macher-agent-session session))))))
  (apply orig-fn args))

;; --- Media Injection Hook ---

(defun macher-agent--inject-media-fsm-advice (orig-fun fsm &rest args)
  "Inject pending tool media into the FSM payload right before it hits the network."
  (let* ((info (if (fboundp 'gptel-fsm-info)
                   (funcall 'gptel-fsm-info fsm)
                 (when (fboundp 'mock-gptel-fsm-info)
                   (funcall 'mock-gptel-fsm-info fsm))))
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

(defun macher-agent--transform-apply-preset-advice (orig-fun &rest args)
  "Inject the original buffer's presets, safely padding arguments for sub-agents."
  (let* ((fsm (car args))
         (info (when fsm 
                 (if (fboundp 'gptel-fsm-info) 
                     (funcall 'gptel-fsm-info fsm) 
                   (funcall 'mock-gptel-fsm-info fsm))))
         (orig-buf (if info (plist-get info :buffer) (current-buffer)))
         (gptel--known-presets (if (buffer-live-p orig-buf) 
                                   (buffer-local-value 'gptel--known-presets orig-buf) 
                                 gptel--known-presets))
         (gptel-directives (if (buffer-live-p orig-buf) 
                               (buffer-local-value 'gptel-directives orig-buf) 
                             gptel-directives)))
    
    ;; Execute gracefully. If the native function chokes on the delegate's missing/nil 
    ;; context and throws a stringp error, silently swallow it so the sentinel can finish.
    (condition-case nil
        (apply orig-fun (or args (list nil)))
      (error nil))))

(advice-add 'gptel--transform-apply-preset :around #'macher-agent--transform-apply-preset-advice)

(defun macher-agent--gptel-restore-advice (&rest _)
  "Ensure workspace skills are loaded into `gptel--known-presets` before restoring."
  (let ((ctx (when (fboundp 'macher-agent-current-context)
               (macher-agent-current-context))))
    (macher-agent-initialize-skills ctx)))

;; Advise the actual internal function that gptel uses on mode startup
(advice-add 'gptel--restore-state :before #'macher-agent--gptel-restore-advice)


(provide 'macher-agent-gptel-bridge)
