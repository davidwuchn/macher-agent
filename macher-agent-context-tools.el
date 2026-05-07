;;; macher-agent-context-tools.el --- Tools requiring macher's ephemeral context -*- lexical-binding: t; -*-

(require 'project)
(require 'gptel)
(require 'macher)

(defun macher-agent--get-context-edits (context)
  "Extract file paths and virtual contents from the macher CONTEXT."
  (when context
    (mapcar (lambda (entry)
              (let* ((path (car entry))
                     (content-pair (cdr entry))
                     (new-content (cdr content-pair)))
                (cons path new-content)))
            (macher-context-contents context))))

(defun macher-agent--pure-async-execute (project-root context cmd success-override callback)
  "Execute CMD inside a temporary sandbox cleanly and asynchronously.
Does NOT block the Emacs event loop and safely returns both successes and errors.
Crucially, guarantees sandbox deletion to prevent disk leaks and safely supports TRAMP."
  (let* ((temp-dir (file-name-as-directory (make-temp-file "sandbox-" t)))
         (rsync-out-buf (generate-new-buffer " *macher-rsync-out*"))
         
         ;; Define all path logic in the main list
         (local-root (file-local-name (expand-file-name project-root)))
         (source (file-name-as-directory local-root))
         (dest (file-local-name (expand-file-name temp-dir)))
         
         ;; Define the command string here so it's available to the whole function
         (rsync-cmd (format "rsync -a --exclude='target/' %s. %s"
                            (shell-quote-argument source)
                            (shell-quote-argument dest))))
    
    ;; BODY START: rsync-cmd is now valid here
    (message "Executing: %s" rsync-cmd)

    (let ((default-directory project-root))
      (set-process-sentinel
       (start-file-process-shell-command "rsync-sandbox" rsync-out-buf rsync-cmd)
       (lambda (r-proc _event)
         (when (memq (process-status r-proc) '(exit signal))
           (if (not (= (process-exit-status r-proc) 0))
               (let ((err-out (with-current-buffer rsync-out-buf (string-trim (buffer-string)))))
                 (kill-buffer rsync-out-buf)
                 (delete-directory temp-dir t)
                 (funcall callback (format "ERROR: Failed to create sandbox (rsync failed).\nCommand: %s\nOutput: %s" rsync-cmd err-out)))
             
             (kill-buffer rsync-out-buf)
             (dolist (edit context)
               (let* ((path (car edit))
                      (content (cdr edit))
                      (rel-path (file-relative-name path project-root))
                      (full-path (expand-file-name rel-path temp-dir)))
                 (if content
                     (progn
                       (make-directory (file-name-directory full-path) t)
                       (with-temp-file full-path
                         (insert content)))
                   (when (file-exists-p full-path)
                     (delete-file full-path)))))
             
             (let* ((output-buffer (generate-new-buffer " *macher-async-out*"))
                    ;; Use 'dest' directly as it is the local temp path
                    (target-cmd (format "cd %s && %s" (shell-quote-argument dest) cmd)))
               
               (let ((default-directory project-root))
                 (set-process-sentinel
                  (start-file-process-shell-command "macher-cmd" output-buffer target-cmd)
                  (lambda (cmd-p _cmd-event)
                    (when (memq (process-status cmd-p) '(exit signal))
                      (let ((output (with-current-buffer output-buffer (buffer-string)))
                            (exit-code (process-exit-status cmd-p)))
                        
                        (kill-buffer output-buffer)
                        (delete-directory temp-dir t)
                        
                        (if (and success-override 
                                 (= exit-code 0) 
                                 (string-empty-p (string-trim output)))
                            (funcall callback success-override)
                          (funcall callback output)))))))))))))))

(cl-defmacro macher-agent-make-tool (&key name description args command-fn success-fn output-filter category)
  "Create a tool that automatically syncs macher's virtual edits into a sandbox before execution.
If CATEGORY is omitted, it defaults to \"macher-agent\"."
  `(gptel-make-tool
    :name ,name
    :description ,description
    :args ,args
    :category ,(or category "macher-agent")
    :async t
    :function (lambda (callback &rest tool-args)
                (let* ((fsm macher--fsm-latest)
                       (fsm-info (when fsm (gptel-fsm-info fsm)))
                       (context (when fsm-info (plist-get fsm-info :macher--context)))
                       ;; Idiomatically extract the root from the macher workspace
                       (workspace (when context (macher-context-workspace context)))
                       (project-root (if workspace 
                                         (file-name-as-directory (macher--workspace-root workspace))
                                       (file-name-as-directory default-directory))))
                  
                  (let* ((call-args (if (and tool-args (keywordp (car tool-args)))
                                        tool-args
                                      (let ((result nil))
                                        (cl-loop for arg-def in ,args
                                                 for i from 0
                                                 for arg-name = (intern (concat ":" (plist-get arg-def :name)))
                                                 do (setq result (plist-put result arg-name (nth i tool-args))))
                                        result)))
                         (cmd-string (funcall ,command-fn call-args))
                         (success-override (when ,success-fn (funcall ,success-fn call-args)))
                         (pending-edits (macher-agent--get-context-edits context)))
                    
                    (macher-agent--pure-async-execute
                     project-root
                     pending-edits
                     cmd-string
                     success-override
                     (lambda (result)
                       (funcall callback (if ,output-filter (funcall ,output-filter result) result)))))))))

;;;###autoload
(defun macher-agent-clear-context ()
  "Wipe the agent's virtual memory so it reads fresh from the disk on its next turn."
  (interactive)
  (if (not macher-agent--persistent-context)
      (message "No active context to clear in this buffer.")
    (setq-local macher-agent--persistent-context nil)
    ;; Also clear the FSM tracker so it doesn't try to auto-resume a dead state
    (setq-local macher--fsm-latest nil) 
    (message "Agent memory cleared. It will take a fresh snapshot of the disk on its next task.")))

(provide 'macher-agent-context-tools)
;;; macher-agent-context-tools.el ends here
