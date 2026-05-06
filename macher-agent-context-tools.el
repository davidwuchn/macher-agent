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

(defun macher-agent--pure-async-execute (context cmd success-override callback)
  "Execute CMD inside a temporary sandbox cleanly and asynchronously.
Does NOT block the Emacs event loop and safely returns both successes and errors."
  (let* ((root (locate-dominating-file default-directory ".git"))
         (project-root (if root
                           (file-name-as-directory (expand-file-name root))
                         (file-name-as-directory default-directory)))
         (temp-dir (file-name-as-directory (expand-file-name (make-temp-file "sandbox-" t))))
         (rsync-cmd (format "rsync -a --exclude='target/' --exclude='.git/' --exclude='node_modules/' %s %s"
                            (shell-quote-argument project-root)
                            (shell-quote-argument temp-dir)))
         (rsync-proc (start-process-shell-command "rsync-sandbox" nil rsync-cmd)))
    
    (set-process-sentinel
     rsync-proc
     (lambda (r-proc _event)
       (when (memq (process-status r-proc) '(exit signal))
         (dolist (edit context)
           (let* ((path (car edit))
                  (content (cdr edit))
                  (rel-path (file-relative-name path project-root))
                  (full-path (expand-file-name rel-path temp-dir)))
             (make-directory (file-name-directory full-path) t)
             (with-temp-file full-path
               (insert content))))
         
         (let* ((output-buffer (generate-new-buffer " *macher-async-out*"))
                (target-cmd (format "cd %s && %s" (shell-quote-argument temp-dir) cmd))
                (cmd-proc (start-process-shell-command "macher-cmd" output-buffer target-cmd)))
           
           (set-process-sentinel
            cmd-proc
            (lambda (cmd-p _cmd-event)
              (when (memq (process-status cmd-p) '(exit signal))
                (let ((output (with-current-buffer output-buffer (buffer-string)))
                      (exit-code (process-exit-status cmd-p)))
                  (kill-buffer output-buffer)
                  
                  (if (and success-override 
                           (= exit-code 0) 
                           (string-empty-p (string-trim output)))
                      (funcall callback success-override)
                    (funcall callback output))))))))))))

(cl-defmacro macher-agent-make-tool (&key name description args command-fn success-fn output-filter)
  "Create a tool that automatically syncs macher's virtual edits into a sandbox before execution."
  `(gptel-make-tool
    :name ,name
    :description ,description
    :args ,args
    :category "macher-tool-category"
    :async t
    :function (lambda (callback &rest tool-args)
                (let* ((fsm macher--fsm-latest)
                       (fsm-info (when fsm (gptel-fsm-info fsm)))
                       (context (when fsm-info (plist-get fsm-info :macher--context))))
                  
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
