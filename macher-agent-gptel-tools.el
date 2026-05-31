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

;; --- Pure Event-Driven Orchestration ---

(defun macher-agent--format-parallel-results (master-ctx results)
  "Format sub-agent results and merge shadow contexts into MASTER-CTX."
  (mapconcat (lambda (r)
               (let ((buf-name (car r))
                     (res (cdr r)))
                 (when-let ((buf (get-buffer buf-name))
                            (shadow-ctx (buffer-local-value 'macher-agent--persistent-context buf)))
                   (macher-agent--merge-contexts master-ctx shadow-ctx))
                 (format "=== Response from %s ===\n%s" buf-name res)))
             (nreverse results) "\n\n"))

(defun macher-agent--execute-parallel (buffers callback)
  "Execute multiple sub-agents concurrently using event-driven callbacks."
  (let ((pending-count (length buffers))
        (results nil)
        (errors nil)
        (master-ctx (macher-agent-current-context)))
    (cl-labels
        ((check-done ()
           (when (= pending-count 0)
             (if errors
                 (funcall callback (list :status 'error :error (string-join errors "\n")))
               (let ((final-output (macher-agent--format-parallel-results master-ctx results)))
                 (funcall callback (list :status 'success :data (format "All sub-agents completed. Outputs:\n\n%s" final-output))))))))
      (dolist (buf buffers)
        ;; Clone context and assign buffer-locally
        (let ((shadow-ctx (macher-agent--clone-context master-ctx)))
          (with-current-buffer buf
            (setq-local macher-agent--persistent-context shadow-ctx)))
        
        (macher-agent--dispatch-and-wait
         buf
         (lambda (result)
           (if (eq (plist-get result :status) 'success)
               (push (cons (buffer-name buf) (plist-get result :data)) results)
             (push (plist-get result :error) errors))
           (cl-decf pending-count)
           (check-done)))))))

(defun macher-agent--dispatch-and-wait (buf callback)
  "Trigger gptel-send and handle response via native lifecycle hooks.
Relies on macher-agent--bridge-context-advice to safely bind virtual memory."
  (with-current-buffer buf
    (macher-agent--show-ui buf)
    (let ((response-hook nil)
          (transform-hook nil))
      
      ;; 1. Catch the FSM upon creation just to track the latest state
      (setq transform-hook
            (lambda (async-fn fsm)
              (setq-local macher--fsm-latest fsm)
              (funcall async-fn)))
      (add-hook 'gptel-prompt-transform-functions transform-hook nil t)
      
      ;; 2. Handle completion naturally
      (setq response-hook
            (lambda (_response _info)
              (let ((res (buffer-local-value 'macher-agent--final-result buf)))
                (if res
                    (progn
                      (macher-agent--hide-ui buf)
                      (funcall callback (list :status 'success :data res)))
                  (funcall callback (list :status 'error :error (format "ERROR: Buffer '%s' stopped silently without calling submit_task_result." (buffer-name buf)))))
                
                ;; --- THE FIX: Defer destruction so gptel's sentinel can exit safely ---
                (run-at-time 0.1 nil 
                             (lambda () 
                               (when (buffer-live-p buf) 
                                 (kill-buffer buf)))))))
      
      (add-hook 'gptel-post-response-functions response-hook nil t)
      
      (gptel-send))))

(defun macher-agent--set-system-message (msg)
  "Adapter function to safely set the gptel system message."
  (setq-local gptel--system-message msg))

;; --- Tools ---

(defun macher-agent--parse-tool-arg (arg)
  "Parse a JSON string argument into a Lisp object if applicable."
  (if (and (stringp arg)
           (or (string-prefix-p "[" (string-trim arg))
               (string-prefix-p "{" (string-trim arg))))
      (condition-case nil
          (json-parse-string arg :array-type 'vector :object-type 'plist)
        (error arg))
    arg))

(defun macher-agent--validate-tool-args (name-symbol context clean-args parsed-args)
  "Middleware: Security check for buffer arguments after JSON parsing."
  (let ((arg-alist (cl-mapcar #'cons clean-args parsed-args)))
    (unless (eq name-symbol 'macher-agent-write-buffer-in-workspace-tool)
      (dolist (arg-name '("buffer_name" "buffer_names" "media_path"))
        (let* ((arg-sym (intern arg-name))
               (val (cdr (assq arg-sym arg-alist))))
          (when val
            (let* ((items (if (or (listp val) (vectorp val)) val (list val))))
              (cl-loop for item being the elements of items do
                       (if (string= arg-name "media_path")
                           (let* ((workspace (when context (macher-context-workspace context)))
                                  (root-dir (when workspace (macher--workspace-root workspace))))
                             ;; Restore classification check to protect against reading arbitrary text files
                             (if (eq (macher-agent-context-classify-entry item root-dir) 'media)
                                 (when root-dir
                                   (let ((expanded (expand-file-name item root-dir)))
                                     (unless (string-prefix-p (expand-file-name root-dir) expanded)
                                       (error "SECURITY ERROR: Media path escapes workspace root directory."))))
                               ;; If it is NOT media, fall back to strict VFS memory scope
                               (macher-agent--ensure-access context item)))
                         (macher-agent--ensure-access context item))))))))))

(defvar-local macher-agent--pending-instructions-queue nil
  "List of instruction strings to append to the tool's return payload.")

(defun macher-agent-add-pending-instruction (instruction)
  "Push an INSTRUCTION directive to steer the LLM after tool execution."
  (push instruction macher-agent--pending-instructions-queue))

(cl-defmacro macher-agent-make-tool (name-symbol (description category &key args async sandbox) lambda-args &rest body)
  "Define a gptel tool with standardised JSON parsing and error handling."
  (let* ((name-str (replace-regexp-in-string "^macher-agent-\\|-tool$" "" (symbol-name name-symbol)))
         (name (replace-regexp-in-string "-" "_" name-str))
         (all-lambda-args (if async (cons 'gptel-callback lambda-args) lambda-args))
         (docstring (format "Gptel tool wrapper for %s." name))
         (clean-args (cl-remove-if (lambda (sym) (string-prefix-p "&" (symbol-name sym))) lambda-args)))
    `(defvar ,name-symbol
       (gptel-make-tool
        :name ,name
        :description ,description
        :category ,(concat "macher-agent-" category)
        :args ,args
        :async ,async
        :function
        (lambda ,all-lambda-args
          ,docstring
          (let* ((context (macher-agent-current-context))
                 (parsed-args (mapcar #'macher-agent--parse-tool-arg (list ,@clean-args))))
            (macher-agent--validate-tool-args ',name-symbol context ',clean-args parsed-args)

            ,(if async
                 `(let ((callback (apply-partially
                                   (lambda (gptel-cb plist-result)
                                     (let ((final-str (if (eq (plist-get plist-result :status) 'success)
                                                          (plist-get plist-result :data)
                                                        (plist-get plist-result :error))))
                                       (when macher-agent--pending-instructions-queue
                                         (setq final-str (concat final-str
                                                                 "\n\n=== SYSTEM DIRECTIVE ===\n"
                                                                 (string-join (nreverse macher-agent--pending-instructions-queue) "\n")))
                                         (setq macher-agent--pending-instructions-queue nil))
                                       (funcall gptel-cb final-str)))
                                   gptel-callback)))
                    (condition-case err
                        ,(if sandbox
                             `(let* ((workspace (when context (macher-context-workspace context)))
                                     (root-dir (when workspace (macher--workspace-root workspace))))
                                (if (not root-dir)
                                    (funcall callback (list :status 'error :error "Cannot determine workspace root."))
                                  (macher-agent-with-sandbox root-dir
                                                             (lambda (sandbox-dir err-msg)
                                                               (if err-msg
                                                                   (funcall callback (list :status 'error :error err-msg))
                                                                 (let* ((original-callback callback)
                                                                        (callback (lambda (res)
                                                                                    (ignore-errors (delete-directory sandbox-dir t))
                                                                                    (funcall original-callback res)))
                                                                        (sandbox-dir sandbox-dir))
                                                                   (apply (lambda ,lambda-args ,@body) parsed-args)))))))
                           `(apply (lambda ,lambda-args ,@body) parsed-args))
                      (error
                       (funcall callback (list :status 'error :error (macher-agent--format-error err))))))

               `(let ((result
                       (condition-case err
                           ,(if sandbox
                                `(error "Synchronous tools cannot use the :sandbox flag. Set :async t.")
                              `(list :status 'success :data (apply (lambda ,lambda-args ,@body) parsed-args)))
                         (error
                          (list :status 'error :error (macher-agent--format-error err))))))
                  (let ((final-str (if (eq (plist-get result :status) 'success)
                                       (plist-get result :data)
                                     (plist-get result :error))))
                    (when macher-agent--pending-instructions-queue
                      (setq final-str (concat final-str
                                              "\n\n=== SYSTEM DIRECTIVE ===\n"
                                              (string-join (nreverse macher-agent--pending-instructions-queue) "\n")))
                      (setq macher-agent--pending-instructions-queue nil))
                    final-str)))))))))

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

(defvar macher-agent-commit-buffer-tool
  (gptel-make-tool
   :name "write_and_commit_buffer"
   :description "Directly overwrite an Emacs buffer and synchronise the agent's memory immediately, bypassing the patch review step."
   :category "macher-agent-plan"
   :args (list '(:name "buffer_name" :type string)
               '(:name "content" :type string))
   :function (lambda (context buffer_name content)
               (condition-case err
                   (let ((actual-name (macher-agent--resolve-buffer-name buffer_name)))
                     (macher-agent--ensure-access context actual-name)
                     (let ((target-buffer (get-buffer-create actual-name)))
                       
                       (with-current-buffer target-buffer
                         ;; 1. Prevent background processes from silently flushing to disk
                         (when (bound-and-true-p auto-save-visited-mode)
                           (auto-save-visited-mode -1))
                         
                         (erase-buffer)
                         (insert content)
                         
                         ;; 2. Explicitly mark as modified so the user is prompted on exit
                         (set-buffer-modified-p t))
                       
                       (when context
                         (macher-agent--update-context-file context actual-name content)
                         (macher-agent--auto-sync-context context))
                       (format "SUCCESS: Buffer '%s' has been directly overwritten and synchronised. Awaiting user save." actual-name)))
                 (error (error-message-string err))))))

(with-eval-after-load 'gptel-transient
  (ignore-errors
    ;; Disable history serialization for heavy gptel menu variables
    (transient-suffix-put 'gptel-menu 'gptel--infix-tools :save-history nil)
    (transient-suffix-put 'gptel-menu 'gptel--infix-system-message :save-history nil)))

(provide 'macher-agent-gptel-tools)
;;; macher-agent-gptel-tools.el ends here
