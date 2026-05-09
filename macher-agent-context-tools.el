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

(defun macher-agent--run-async-cmd (name cmd dir callback)
  "Run CMD asynchronously in DIR, passing (EXIT-CODE OUTPUT) to CALLBACK."
  (let ((out-buf (generate-new-buffer (format " *macher-%s-out*" name)))
        (default-directory dir))
    (set-process-sentinel
     (start-file-process-shell-command name out-buf cmd)
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (let ((exit-code (process-exit-status proc))
               (output (with-current-buffer out-buf (buffer-string))))
           (kill-buffer out-buf)
           (funcall callback exit-code output)))))))

(defgroup macher-agent nil
  "Sandboxed, Language-Agnostic AI Workflows."
  :group 'gptel
  :prefix "macher-agent-")

(defcustom macher-agent-sandbox-excludes 
  '(".git/" "target/" "node_modules/" ".Trash/" "Library/" ".venv/" "__pycache__/")
  "List of directories to exclude when syncing the workspace to a sandbox."
  :type '(repeat string)
  :group 'macher-agent)

(defun macher-agent--build-rsync-cmd (source dest)
  "Generate the rsync command to copy SOURCE to DEST safely."
  (let ((src-local (file-name-as-directory (file-local-name (expand-file-name source))))
        (dst-local (file-local-name (expand-file-name dest)))
        (exclude-args (mapconcat (lambda (ex) (format "--exclude=%s" (shell-quote-argument ex))) 
                                 macher-agent-sandbox-excludes " ")))
    (format "rsync -a %s %s %s"
            exclude-args
            (shell-quote-argument src-local)
            (shell-quote-argument dst-local))))

(defun macher-agent--pure-async-execute (project-root context cmd success-override callback)
  "Execute CMD inside a temporary sandbox cleanly and asynchronously."
  (let* ((temp-dir (let ((default-directory project-root))
                     (file-name-as-directory (make-temp-file "sandbox-" t))))
         (rsync-cmd (macher-agent--build-rsync-cmd project-root temp-dir))
         (cleanup-fn (lambda () (delete-directory temp-dir t))))
    
    (message "Executing: %s" rsync-cmd)

    ;; 1. Run Rsync
    (macher-agent--run-async-cmd 
     "rsync" rsync-cmd project-root
     (lambda (exit-code output)
       (if (not (= exit-code 0))
           (progn
             (funcall cleanup-fn)
             (funcall callback (format "ERROR: Rsync failed.\nCommand: %s\nOutput: %s" 
                                       rsync-cmd (string-trim output))))
         
         ;; 2. Overlay in-memory files
         (dolist (edit context)
           (let* ((path (car edit))
                  (content (cdr edit))
                  (full-path (expand-file-name (file-relative-name path project-root) temp-dir)))
             (if content
                 (progn
                   (make-directory (file-name-directory full-path) t)
                   (with-temp-file full-path (insert content)))
               (when (file-exists-p full-path)
                 (delete-file full-path)))))
         
         ;; 3. Run User Command
         (macher-agent--run-async-cmd 
          "cmd" cmd temp-dir
          (lambda (cmd-exit cmd-output)
            (funcall cleanup-fn)
            (if (and success-override 
                     (= cmd-exit 0) 
                     (string-empty-p (string-trim cmd-output)))
                (funcall callback success-override)
              (funcall callback cmd-output)))))))))

(cl-defmacro macher-agent-make-tool (&key name description args command-fn success-fn output-filter category)
  "Create a tool that automatically syncs macher's virtual edits into a sandbox before execution."
  `(gptel-make-tool
    :name ,name
    :description ,description
    :args ,args
    ;; RESTORED: Pass the custom category through natively!
    :category ,(or category "macher-agent")
    :async t
    ;; Accept the upstream injected context as the very first argument
    :function (lambda (context callback &rest tool-args)
                (let* ((workspace (macher-context-workspace context))
                       (project-root (file-name-as-directory (macher--workspace-root workspace)))
                       (pending-edits (macher-agent--get-context-edits context))
                       (call-args (if (and tool-args (keywordp (car tool-args)))
                                      tool-args
                                    (let ((result nil))
                                      (cl-loop for arg-def in ,args
                                               for i from 0
                                               for arg-name = (intern (concat ":" (plist-get arg-def :name)))
                                               do (setq result (plist-put result arg-name (nth i tool-args))))
                                      result)))
                       (cmd-string (funcall ,command-fn call-args))
                       (success-override (when ,success-fn (funcall ,success-fn call-args))))

                  (macher-agent--pure-async-execute
                   project-root
                   pending-edits
                   cmd-string
                   success-override
                   (lambda (result)
                     (funcall callback (if ,output-filter (funcall ,output-filter result) result))))))))

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
