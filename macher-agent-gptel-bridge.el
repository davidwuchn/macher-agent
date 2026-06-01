;;; macher-agent-gptel-bridge.el --- Clean gptel boundary -*- lexical-binding: t; -*-

(require 'gptel)
(require 'macher)
(require 'macher-agent-vfs-client)

(declare-function macher-agent-current-context "macher-agent-vfs-client")
(declare-function macher-agent--auto-sync-context "macher-agent-vfs-client")
(declare-function macher-agent--split-context "macher-agent-vfs-client")
(declare-function macher-agent--build-virtual-patch "macher-agent-vfs-client")

;; --- 1. The Pre-flight Boundary (Initialise VFS before LLM call) ---

(defun macher-agent--gptel-pre-send-advice (orig-fun &rest args)
  "Ensure the agent VFS is synchronised before sending a request to the LLM.
This is the single entry point for pre-flight state management."
  ;; Dynamically bind the flag to allow lazy initialisation only during a send
  (let* ((macher-agent--allow-lazy-init t)
         (ctx (macher-agent-current-context)))
    (when ctx
      (macher-agent--auto-sync-context ctx)))
  (apply orig-fun args))

(advice-add 'gptel-send :around #'macher-agent--gptel-pre-send-advice)

;; --- 1.5 Media Lifecycle (Inject media before request) ---

;; looks like FSM can't be avoided may break in future
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
        
        ;; Clear the queue for this session
        (setf (macher-agent-session-pending-media session) nil)))
    
    ;; Continue with the actual network request
    (apply orig-fun fsm args)))

(advice-add 'gptel--handle-wait :around #'macher-agent--inject-media-fsm-advice)

;; --- 2. The Post-flight Boundary (Refresh UI after LLM finishes) ---

(defun macher-agent--gptel-post-response-hook (_response info)
  "Refresh the VFS UI after the LLM completes a turn.
If the context is dirty, it delegates to macher-agent--process-request."
  (let ((ctx (macher-agent-current-context)))
    (when (and ctx (macher-context-dirty-p ctx) (not (bound-and-true-p macher-agent--is-subagent)))
      ;; Build a dummy FSM structure based on info
      (let ((fsm (if (fboundp 'gptel-make-fsm)
                     (gptel-make-fsm :info info)
                   nil)))
        (macher-agent--process-request 'complete ctx fsm)))))

(add-hook 'gptel-post-response-functions #'macher-agent--gptel-post-response-hook)

;; --- 3. Clean FSM Context Adapter (No FSM injection) ---

(defun macher-agent--setup-tools-advice (orig-fn &rest args)
  "Make sure `macher--setup-tools` works gracefully without FSM injection."
  (let* ((fsm (car args))
         (info (when fsm
                 (if (fboundp 'gptel-fsm-info)
                     (funcall 'gptel-fsm-info fsm)
                   (when (fboundp 'mock-gptel-fsm-info)
                     (funcall 'mock-gptel-fsm-info fsm)))))
         (ctx (when info (plist-get info :macher--context)))
         (fallback-ctx (unless ctx (ignore-errors (macher-agent-current-context))))
         (final-ctx (or ctx fallback-ctx)))
    (when final-ctx
      (macher-agent--auto-sync-context final-ctx)
      ;; Ensure the macher-agent-session is attached to the FSM info
      (when fsm
        (let ((session (or (plist-get info :macher-agent-session)
                           (let* ((ws (macher-context-workspace final-ctx))
                                  (proj-root (if ws (macher--workspace-root ws) default-directory))
                                  (agent-ws (make-macher-agent-workspace :project-root proj-root)))
                             (make-macher-agent-session :id (buffer-name) :workspace agent-ws)))))
          (setf (gptel-fsm-info fsm) (plist-put info :macher-agent-session session))))))
  (apply orig-fn args))

(advice-add 'macher--setup-tools :around #'macher-agent--setup-tools-advice)

;; Override macher's default diff processing to route live buffers vs file VFS
(setq macher-process-request-function #'macher-agent--process-request)

(provide 'macher-agent-gptel-bridge)
;;; macher-agent-gptel-bridge.el ends here
