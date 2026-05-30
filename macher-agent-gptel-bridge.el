;;; macher-agent-gptel-bridge.el --- Clean gptel boundary -*- lexical-binding: t; -*-

(require 'gptel)
(require 'macher)
(require 'macher-agent-vfs-client)

(declare-function macher-agent-current-context "macher-agent-vfs-client")
(declare-function macher-agent--auto-sync-context "macher-agent-vfs-client")
(declare-function macher-agent--split-context "macher-agent-vfs-client")
(declare-function macher-agent--build-virtual-patch "macher-agent-vfs-client")

;; --- 1. The Pre-flight Boundary (Initialize VFS before LLM call) ---

(defun macher-agent--gptel-pre-send-advice (orig-fun &rest args)
  "Ensure the agent VFS is synchronized before sending a request to the LLM.
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
  
  ;; Use a standard quote (') instead of a sharp-quote (#')!
  ;; This prevents the byte-compiler from inlining the struct type-check,
  ;; allowing testing frameworks to cleanly mock the accessor.
  (let* ((info (funcall 'gptel-fsm-info fsm))
         (buf (plist-get info :buffer))
         (pending (alist-get buf macher-agent--pending-tool-media-alist)))
    
    (when pending
      (let* ((msg-plist (list :role "user" 
                              :content "Tool execution complete. Here is the requested visual data:"))
             (prompts (list msg-plist))
             (gptel-context pending))
        
        ;; Have gptel natively encode the image to base64 JSON payload
        (gptel--inject-media (plist-get info :backend) prompts)
        
        ;; Inject directly into the raw API payload data
        (gptel--inject-prompt (plist-get info :backend) 
                              (plist-get info :data) 
                              (car prompts))
        
        ;; Clear the queue for this buffer
        (setf (alist-get buf macher-agent--pending-tool-media-alist nil 'remove) nil)))
    
    ;; Continue with the actual network request
    (apply orig-fun fsm args)))

(advice-add 'gptel--handle-wait :around #'macher-agent--inject-media-fsm-advice)

;; --- 2. The Post-flight Boundary (Refresh UI after LLM finishes) ---

(defun macher-agent--gptel-post-response-hook (_response _info)
  "Refresh the VFS UI after the LLM completes a turn.
If the context is dirty, it splits the context into file and buffer edits
and hands them safely to the `macher` presentation layer."
  (let ((ctx (macher-agent-current-context)))
    (when (and ctx (macher-context-dirty-p ctx) (not (bound-and-true-p macher-agent--is-subagent)))
      (let* ((split (macher-agent--split-context ctx))
             (file-ctx (car split))
             (buf-ctx (cdr split)))
        
        ;; Native File Diffing Hand-off
        (when (and file-ctx (fboundp 'macher--build-patch))
          (macher--build-patch file-ctx nil))
        
        ;; Virtual Buffer Diffing Hand-off
        (when (and buf-ctx (fboundp 'macher-agent--build-virtual-patch))
          (macher-agent--build-virtual-patch buf-ctx))))))

(add-hook 'gptel-post-response-functions #'macher-agent--gptel-post-response-hook)

;; --- 3. Clean FSM Context Adapter (No FSM injection) ---

(defun macher-agent--setup-tools-advice (orig-fn &rest args)
  "Make sure `macher--setup-tools` works gracefully without FSM injection."
  (let ((ctx (macher-agent-current-context)))
    (when ctx
      (macher-agent--auto-sync-context ctx)))
  (apply orig-fn args))

(advice-add 'macher--setup-tools :around #'macher-agent--setup-tools-advice)

(provide 'macher-agent-gptel-bridge)
;;; macher-agent-gptel-bridge.el ends here
