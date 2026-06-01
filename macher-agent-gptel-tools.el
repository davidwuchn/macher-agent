;;; macher-agent-gptel-tools.el --- Pure gptel orchestration tools -*- lexical-binding: t; -*-

(require 'macher)
(require 'json)
(require 'cl-lib)
(require 'transient)

(declare-function macher-agent-current-context "macher-agent-vfs-client")
(declare-function macher-agent--resolve-buffer-name "macher-agent-orchestration")
(declare-function macher-agent--read-context-file "macher-agent-vfs-client")
(declare-function macher-agent--merge-contexts "macher-agent-vfs-client")
(declare-function macher-agent--clone-context "macher-agent-vfs-client")
(declare-function macher-agent--ensure-access "macher-agent-vfs-client")
(declare-function macher-agent-context-classify-entry "macher-agent-vfs-client")

(defvar macher-agent-tools-registry)

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
  (let* (;; 1. Safely isolate the callback closure
         (callback (cl-find-if #'functionp all-args))
         ;; 2. Safely isolate macher's injected context struct (if routed via FSM)
         (injected-context (cl-find-if (lambda (x) (and (boundp 'macher-context-p) 
                                                        (fboundp 'macher-context-p) 
                                                        (macher-context-p x))) 
                                       all-args))
         ;; 3. Strip structural arguments to isolate the raw LLM payload
         (raw-tool-args (cl-remove-if (lambda (x) (or (eq x callback) (eq x injected-context))) all-args))
         ;; 4. Align from the END to silently discard LLM hallucinations
         (aligned-args (last raw-tool-args (length schema)))
         ;; 5. Context priority: FSM Context > Local Context > Global Search
         (context (or injected-context (ignore-errors (macher-agent-current-context))))
         (payload nil))

    ;; Map args to a plist dynamically based on the schema
    (cl-loop for arg-def in schema
             for i from 0
             for arg-key = (intern (concat ":" (plist-get arg-def :name)))
             for val = (nth i aligned-args)
             do (setq payload (plist-put payload arg-key val)))

    (funcall next-fn payload context (or callback (lambda (res) res)))))

(cl-defmacro macher-agent-make-tool (name-symbol description &key category args command-fn success-fn output-filter-fn)
  "Declarative tool definition. All execution mechanics are delegated to the middleware."
  (let ((name (replace-regexp-in-string "^macher-agent-\\|-tool$" "" (symbol-name name-symbol))))
    `(defvar ,name-symbol
       (gptel-make-tool
        :name ,(replace-regexp-in-string "-" "_" name)
        :description ,description :category ,(or category "macher-agent") :args ,args :async t
        :function
        (lambda (&rest all-args)
          (macher-agent--middleware-pipeline
           all-args ,args
           (lambda (payload context raw-callback)
             (let ((callback (macher-agent--wrap-callback raw-callback)))
               (condition-case err
                   (let* ((action (funcall ,command-fn payload))
                          (on-success 
                           (lambda (raw-result)
                             (let* ((success-data (if ,success-fn (funcall ,success-fn raw-result) raw-result))
                                    (final-data (if ,output-filter-fn (funcall ,output-filter-fn success-data) success-data)))
                               (funcall callback (list :status 'success :data final-data))))))
                     ;; Pass to the execution router
                     (macher-agent--execute-action action context on-success callback))
                 (error
                  (funcall callback (list :status 'error :error (error-message-string err)))))))))))))

(defun macher-agent--execute-action (action context on-success on-error)
  "Routes the declarative ACTION to the appropriate asynchronous backend."
  (pcase action
    ;; String -> Run Sandboxed Shell Command
    ((pred stringp)
     (macher-agent--run-in-persistent-sandbox context action on-success on-error))
    ;; Delegation Task -> Route to Fan-Out Orchestrator
    (`(:delegate . ,tasks)
     (macher-agent-execute-parallel tasks on-success))
    ;; Nohup -> Fire and Forget
    (`(:nohup . ,cmd)
     (macher-agent--run-async-cmd "detached" cmd default-directory (lambda (_ _)))
     (funcall on-success "SUCCESS: Process started."))
    ;; Explicit Lisp Return bypasses sandbox string check
    (`(:lisp-result . ,val)
     (funcall on-success val))
    ;; Direct Lisp Return
    (_ (funcall on-success action))))

;; --- Sandbox Tools ---

(defun macher-agent-sync-to-persistent-sandbox (sandbox-dir pending-edits workspace)
  "Write uncommitted VFS memory directly to the persistent sandbox, bypassing shell overhead."
  (let ((coding-system-for-write 'utf-8-unix)
        (workspace-root (when workspace (expand-file-name (macher--workspace-root workspace)))))
    (dolist (edit pending-edits)
      (let* ((original-path (car edit))
             (content (cdr (cdr edit)))
             (relative-path (if workspace-root 
                                (file-relative-name original-path workspace-root)
                              original-path))
             (full-path (expand-file-name relative-path sandbox-dir)))
        (make-directory (file-name-directory full-path) t)
        (if content
            (with-temp-buffer
              (insert content)
              (write-region nil nil full-path nil 'silent))
          (when (file-exists-p full-path)
            (delete-file full-path)))))))

(defun macher-agent--run-async-cmd (name cmd dir callback)
  "Executes a command using explicit lexical capture for background safety."
  (let* ((out-buf (generate-new-buffer (format " *%s*" name)))
         (default-directory dir))
    (make-process
     :name name
     :buffer out-buf
     :command (list shell-file-name shell-command-switch cmd)
     :sentinel (lambda (proc _event)
                 ;; 'callback' is safely lexically captured here.
                 (when (memq (process-status proc) '(exit signal))
                   (let ((output (with-current-buffer out-buf (buffer-string)))
                         (exit-code (process-exit-status proc)))
                     (kill-buffer out-buf)
                     (funcall callback exit-code output)))))))

(defvar-local macher-agent--persistent-sandbox-dir nil)
(defun macher-agent--run-in-persistent-sandbox (context command on-success on-error)
  (unless macher-agent--persistent-sandbox-dir
    (let ((sandbox (make-temp-file "macher-sandbox-" t)))
      (setq-local macher-agent--persistent-sandbox-dir sandbox)
      (when-let* ((workspace (when context (macher-context-workspace context)))
                  (root (macher--workspace-root workspace)))
        ;; One-time bootstrap: Sync the physical workspace files using the single source of truth
        (let ((sync-cmd (macher-agent--build-rsync-cmd (expand-file-name root) sandbox)))
          (if (listp sync-cmd)
              (apply #'call-process (car sync-cmd) nil nil nil (cdr sync-cmd))
            (call-process shell-file-name nil nil nil shell-command-switch sync-cmd))))))
  (macher-agent-sync-to-persistent-sandbox 
   macher-agent--persistent-sandbox-dir 
   (and context (macher-context-contents context))
   (and context (macher-context-workspace context)))
  (macher-agent--run-async-cmd 
   "sandbox" command macher-agent--persistent-sandbox-dir 
   (lambda (exit-code output) 
     (if (= exit-code 0) 
         (funcall on-success output) 
       (funcall on-error (list :status 'error :error output))))))

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

(defun macher-agent--jit-reload-skills (&rest _)
  "Intercept gptel-send to recompile presets from the VFS."
  (when (bound-and-true-p macher-agent--is-workspace)
    (let* ((ctx (ignore-errors (macher-agent-current-context)))
           (workspace (when ctx (macher-context-workspace ctx)))
           (skills-dir (when workspace (expand-file-name "skills" (macher--workspace-root workspace)))))
      (when (and skills-dir (file-directory-p skills-dir))
        (when (local-variable-p 'gptel-directives) (kill-local-variable 'gptel-directives))
        ;; Ensure macher-agent-initialize-skills utilizes macher-agent--read-file-vfs-aware
        (macher-agent-initialize-skills skills-dir)
        (when-let* ((preset (bound-and-true-p gptel--system-message-preset))
                    (new-sys-msg (alist-get preset gptel-directives)))
          (setq-local gptel--system-message (if (listp new-sys-msg) (plist-get new-sys-msg :system) new-sys-msg)))))))

(advice-add 'gptel-send :before #'macher-agent--jit-reload-skills)

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
  "Insert INSTRUCTIONS into BUF for the delegated sub-agent without the hardcoded preset."
  (with-current-buffer buf
    (goto-char (point-max))
    (unless (string-empty-p instructions)
      (macher-agent--insert-hidden preset)
      (macher-agent--insert-hidden "\n\n=== DELEGATED TASK ===\n")
      (insert (substring-no-properties instructions)))))

(defvar-local macher-agent--final-result nil
  "Stores the clean, synthesised final answer from the sub-agent.")

(defvar gptel-track-media)
(defvar gptel-context)
(declare-function gptel-add-file "gptel")
(declare-function gptel--parse-buffer "gptel")
(declare-function gptel-context-remove "gptel-context" (file))

(defvar macher-agent--pending-tool-media-alist nil
  "Global alist mapping buffers to their pending media.
This guarantees media survives even if the process filter evaluates tool 
callbacks in a temporary network buffer.")

(defun macher-agent--gptel-base64-encode-advice (orig-fun file)
  "Read FILE from VFS if available before encoding."
  ;; Use ignore-errors here just in case this triggers outside an active agent session
  (let* ((ctx (ignore-errors (macher-agent-current-context)))
         (workspace (when ctx (macher-context-workspace ctx)))
         (workspace-root (when workspace (macher--workspace-root workspace)))
         (actual-name (if (and workspace-root (file-name-absolute-p file))
                          (file-relative-name file workspace-root)
                        file))
         ;; THE FIX: Wrap the VFS read in condition-case.
         ;; If the security layer denies access (e.g. for a physical media file),
         ;; we silently catch the error and fallback to reading the real file.
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
  :command-fn (lambda (payload)
                (let ((buffer_name (plist-get payload :buffer_name))
                      (content (plist-get payload :content))
                      (context (ignore-errors (macher-agent-current-context))))
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
    ;; Disable history serialization for heavy gptel menu variables
    (transient-suffix-put 'gptel-menu 'gptel--infix-tools :save-history nil)
    (transient-suffix-put 'gptel-menu 'gptel--infix-system-message :save-history nil)))

(provide 'macher-agent-gptel-tools)
;;; macher-agent-gptel-tools.el ends here