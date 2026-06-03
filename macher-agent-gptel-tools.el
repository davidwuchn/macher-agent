;;; macher-agent-gptel-tools.el --- Pure gptel orchestration tools -*- lexical-binding: t; -*-

(require 'macher)
(require 'json)
(require 'cl-lib)
(require 'transient)
(require 'macher-agent-vfs-client)

(declare-function macher-agent-current-context "macher-agent-vfs-client")
(declare-function macher-agent--resolve-buffer-name "macher-agent-orchestration")
(declare-function macher-agent--read-context-file "macher-agent-vfs-client")
(declare-function macher-agent--merge-contexts "macher-agent-vfs-client")
(declare-function macher-agent--clone-context "macher-agent-vfs-client")
(declare-function macher-agent--ensure-access "macher-agent-vfs-client")
(declare-function macher-agent-context-classify-entry "macher-agent-vfs-client")

(defvar macher-agent-allowed-tools nil
  "List of custom tool names that should receive the macher-context.")

;; --- Configuration & UI Hooks ---

(defcustom macher-agent-display-subagent-fn nil
  "Function to call with a BUFFER to display it while running.
If nil, the buffer executes silently in the background."
  :type '(choice (const :tag "Silent Background Execution" nil)
                 function)
  :group 'macher-agent)

(defcustom macher-agent-hide-subagent-fn nil
  "Function to call with a BUFFER to hide it once finished."
  :type '(choice (const :tag "Do Nothing" nil)
                 function)
  :group 'macher-agent)

(defun macher-agent--resolve-context (passed-context)
  "Attempt to resolve the current agent context."
  (or passed-context
      (ignore-errors (macher-agent-current-context))
      (when (and (boundp 'macher--fsm-latest) macher--fsm-latest)
        (if (fboundp 'gptel-fsm-info)
            (plist-get (funcall 'gptel-fsm-info macher--fsm-latest) :macher--context)
          (when (fboundp 'mock-gptel-fsm-info)
            (plist-get (funcall 'mock-gptel-fsm-info macher--fsm-latest) :macher--context))))))

(defun macher-agent--format-directives (result-data)
  "Append pending system instructions to RESULT-DATA if any exist."
  (let ((final-str result-data))
    (when macher-agent--pending-instructions-queue
      (setq final-str (concat final-str "\n\n=== SYSTEM DIRECTIVE ===\n"
                              (string-join (nreverse macher-agent--pending-instructions-queue) "\n")))
      (setq macher-agent--pending-instructions-queue nil))
    final-str))

(defun macher-agent--wrap-callback (gptel-cb)
  "Create a callback wrapper that parses the result and formats directives."
  (lambda (plist-result)
    (let ((final-str (if (eq (plist-get plist-result :status) 'success)
                         (plist-get plist-result :data)
                       (plist-get plist-result :error))))
      (when (eq (plist-get plist-result :status) 'error)
        (message "MACHER AGENT ERROR: %S" final-str))
      (if gptel-cb
          (funcall gptel-cb (macher-agent--format-directives final-str))
        (macher-agent--format-directives final-str)))))

(defun macher-agent--show-ui (buf)
  "Internal wrapper to safely trigger the display function."
  (when macher-agent-display-subagent-fn
    (funcall macher-agent-display-subagent-fn buf)))

(defun macher-agent--hide-ui (buf)
  "Internal wrapper to safely trigger the hide function."
  (when macher-agent-hide-subagent-fn
    (funcall macher-agent-hide-subagent-fn buf)))

;; --- Cloaking Mechanism ---

(defun macher-agent--insert-hidden (text)
  "Insert TEXT visually hidden via a display overlay, but fully readable by gptel.
This overrides font-lock and prevents markdown-mode from revealing the text."
  (let* ((start (point))
         (_ (insert text))
         (ov (make-overlay start (point))))
    (overlay-put ov 'display "")
    (overlay-put ov 'insert-behind-hooks '(ignore))))

;; --- Middleware Pipeline and Tool Definition ---

(defun macher-agent--middleware-pipeline (all-args schema next-fn)
  "Extracts context, isolates callbacks, and perfectly aligns the payload payload."
  (let* ((callback (cl-find-if #'functionp all-args))
         (injected-context (cl-find-if (lambda (x) (and (boundp 'macher-context-p) 
                                                        (fboundp 'macher-context-p) 
                                                        (macher-context-p x))) 
                                       all-args))
         ;; Safely remove ONLY the callback and injected context, preserving positional nil values
         (raw-tool-args (cl-remove-if (lambda (x) 
                                        (or (and callback (eq x callback)) 
                                            (and injected-context (eq x injected-context)))) 
                                      all-args))
         (aligned-args (last raw-tool-args (length schema)))
         (context (or injected-context (ignore-errors (macher-agent-current-context))))
         (payload nil))

    (cl-loop for arg-def in schema
             for i from 0
             for arg-key = (intern (concat ":" (plist-get arg-def :name)))
             for val = (nth i aligned-args)
             do (setq payload (plist-put payload arg-key val)))
    
    (funcall next-fn payload context (or callback (lambda (res) res)))))

(cl-defmacro macher-agent-make-tool (name-symbol description &key category args command-fn success-fn output-filter-fn)
  "Declarative tool definition. Execution delegated to middleware with strict parsing and dynamic arity."
  (let ((name (replace-regexp-in-string "^macher-agent-\\|-tool$" "" (symbol-name name-symbol))))
    `(defvar ,name-symbol
       (gptel-make-tool
        :name ,(replace-regexp-in-string "-" "_" name)
        :description ,description :category ,(or category "macher-agent") :args ,args :async t
        :function
        (lambda (&rest all-args)
          (let* ((callback (cl-find-if #'functionp all-args))
                 (context (ignore-errors (macher-agent-current-context)))
                 (root (if context (macher-agent-context-root context) default-directory))
                 (arg-names (ignore-errors (mapcar (lambda (a) (intern (concat ":" (plist-get a :name)))) ,args)))
                 (payload nil)
                 (cmd-eval ,command-fn)
                 (succ-eval ,success-fn)
                 (filter-eval ,output-filter-fn))
            
            (cl-loop for k in arg-names
                     for v in (cl-remove-if #'functionp all-args)
                     do (setq payload (plist-put payload k v)))
            
            (let ((wrap-cb (macher-agent--wrap-callback callback)))
              (condition-case err
                  (let* ((action (let* ((arity (func-arity cmd-eval))
                                        (max-args (cdr arity)))
                                   (if (or (eq max-args 'many) (>= max-args 3))
                                       (funcall cmd-eval payload context root)
                                     (funcall cmd-eval payload))))
                         (on-success 
                          (lambda (raw-result)
                            (let* ((success-data (if succ-eval (funcall succ-eval raw-result) raw-result))
                                   (final-data (if filter-eval (funcall filter-eval success-data) success-data)))
                              (funcall wrap-cb (list :status 'success :data final-data))))))
                    (macher-agent--execute-action action context on-success wrap-cb))
                (error
                 (funcall wrap-cb (list :status 'error :error (error-message-string err))))))))))))

(defun macher-agent--execute-action (action context on-success on-error)
  "Routes the declarative ACTION to the appropriate asynchronous backend."
  (pcase action
    ((pred stringp)
     (macher-agent--run-in-persistent-sandbox context action on-success on-error))
    (`(:delegate . ,tasks)
     (macher-agent-execute-parallel tasks on-success))
    (`(:nohup . ,cmd)
     (macher-agent--run-async-cmd "detached" cmd default-directory (lambda (_ _)))
     (funcall on-success "SUCCESS: Process started."))
    (`(:lisp-result . ,val)
     (funcall on-success val))
    ;; Gracefully trap malformed tools returning closures due to parenthesis nesting errors
    ((pred functionp)
     (funcall on-error (list :status 'error :error "Tool evaluation failed. The command block returned a closure instead of a valid action payload. Check the tool definition for parenthesis nesting errors.")))
    (_ (funcall on-success action))))

;; --- Sandbox Tools ---

(defun macher-agent--run-async-cmd (name cmd dir callback)
  "Executes a command using explicit lexical capture for background safety."
  (let* ((out-buf (generate-new-buffer (format " *%s*" name)))
         (default-directory dir))
    (make-process
     :name name
     :buffer out-buf
     :command (list shell-file-name shell-command-switch cmd)
     :sentinel (lambda (proc _event)
                 (when (memq (process-status proc) '(exit signal))
                   (let ((output (with-current-buffer out-buf (buffer-string)))
                         (exit-code (process-exit-status proc)))
                     (kill-buffer out-buf)
                     (funcall callback exit-code output)))))))

(defun macher-agent--run-in-persistent-sandbox (context command on-success on-error)
  (condition-case err
      (macher-agent-with-strict-vfs-pipeline context
                                             (let* ((output-buf (generate-new-buffer " *macher-sandbox-out*"))
                                                    (exit-code (call-process shell-file-name nil output-buf nil shell-command-switch command))
                                                    (output (with-current-buffer output-buf (buffer-string))))
                                               (kill-buffer output-buf)
                                               (if (= exit-code 0)
                                                   (funcall on-success output)
                                                 (funcall on-error (list :status 'error :error output)))))
    (error (funcall on-error (list :status 'error :error (error-message-string err))))))

;; --- VFS and JIT Reloading ---

(defun macher-agent--read-file-vfs-aware (file-path context)
  "Read a file, prioritising the uncommitted VFS memory over the physical disk."
  (let* ((vfs-entry (when context (assoc file-path (macher-context-contents context))))
         (vfs-content (cdr (cdr vfs-entry))))
    (cond
     (vfs-content vfs-content)
     ((file-exists-p file-path)
      (with-temp-buffer (insert-file-contents file-path) (buffer-string)))
     (t nil))))

;; --- Additional Legacy Tooling Support ---

(defun macher-agent--parse-tool-arg (arg)
  "Parse a JSON string argument into a Lisp object if applicable."
  (if (and (stringp arg)
           (or (string-prefix-p "[" (string-trim arg))
               (string-prefix-p "{" (string-trim arg))))
      (condition-case nil
          (json-parse-string arg :array-type 'vector :object-type 'plist)
        (error arg))
    arg))

(defvar-local macher-agent--pending-instructions-queue nil
  "List of instruction strings to append to the tool's return payload.")

(defun macher-agent-add-pending-instruction (instruction)
  "Push an INSTRUCTION directive to steer the LLM after tool execution."
  (push instruction macher-agent--pending-instructions-queue))

(defun macher-agent--format-error (err)
  "Standardise the error message string for the LLM."
  (let ((msg (error-message-string err)))
    (if (string-match-p "^\\(ERROR\\|SECURITY ERROR\\):" msg)
        msg
      (format "ERROR: %s" msg))))

(defun macher-agent--prepare-subagent-instructions (buf instructions &optional preset)
  "Insert INSTRUCTIONS into BUF and strictly bind its preset system message."
  (with-current-buffer buf
    ;; 1. Erase the buffer so it ONLY contains the assigned task prompt
    (erase-buffer)
    
    ;; 2. Bind the preset so the JIT engine injects the correct system message
    (when preset
      (let ((clean-preset (replace-regexp-in-string "^@" "" preset)))
        (setq-local macher-agent--active-skill-sym (intern clean-preset))))
    
    ;; 3. Insert the explicit LLM instructions
    (unless (string-empty-p instructions)
      (insert (substring-no-properties instructions)))))

(defvar-local macher-agent--final-result nil
  "Stores the clean, synthesised final answer from the sub-agent.")

(defvar gptel-track-media)
(defvar gptel-context)
(declare-function gptel-add-file "gptel")
(declare-function gptel--parse-buffer "gptel")
(declare-function gptel-context-remove "gptel-context" (file))

(defvar macher-agent--pending-tool-media-alist nil
  "Global alist mapping buffers to their pending media.")

(defun macher-agent--gptel-base64-encode-advice (orig-fun file)
  "Read FILE from VFS if available before encoding."
  (let* ((ctx (ignore-errors (macher-agent-current-context)))
         (workspace (when ctx (macher-context-workspace ctx)))
         (workspace-root (when workspace (macher-agent--get-workspace-root workspace)))
         (actual-name (if (and workspace-root (file-name-absolute-p file))
                          (file-relative-name file workspace-root)
                        file))
         (content (when ctx 
                    (condition-case nil
                        (macher-agent--read-context-file ctx actual-name)
                      (error nil)))))
    (if content
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (insert content)
          (base64-encode-region (point-min) (point-max) :no-line-break)
          (buffer-string))
      (funcall orig-fun file))))

(advice-add 'gptel--base64-encode :around #'macher-agent--gptel-base64-encode-advice)

(macher-agent-make-tool macher-agent-commit-buffer-tool
                        "Directly overwrite an Emacs buffer and synchronise the agent's memory immediately, bypassing the patch review step."
                        :category "plan"
                        :args (list '(:name "buffer_name" :type string)
                                    '(:name "content" :type string))
                        :command-fn (lambda (payload context _root)
                                      (let ((buffer_name (plist-get payload :buffer_name))
                                            (content (plist-get payload :content)))
                                        (let ((actual-name (macher-agent--resolve-buffer-name buffer_name)))
                                          (macher-agent--ensure-access context actual-name)
                                          (let ((target-buffer (get-buffer-create actual-name)))
                                            (with-current-buffer target-buffer
                                              (when (bound-and-true-p auto-save-visited-mode)
                                                (auto-save-visited-mode -1))
                                              (erase-buffer)
                                              (insert content)
                                              (set-buffer-modified-p t))
                                            (when context
                                              (macher-agent--update-context-file context actual-name content)
                                              (macher-agent--auto-sync-context context))
                                            (cons :lisp-result (format "SUCCESS: Buffer '%s' has been directly overwritten and synchronised. Awaiting user save." actual-name)))))))

(with-eval-after-load 'gptel-transient
  (ignore-errors
    (transient-suffix-put 'gptel-menu 'gptel--infix-tools :save-history nil)
    (transient-suffix-put 'gptel-menu 'gptel--infix-system-message :save-history nil)))

(provide 'macher-agent-gptel-tools)
;;; macher-agent-gptel-tools.el ends here
