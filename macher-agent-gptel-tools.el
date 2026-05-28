;;; macher-agent-gptel-tools.el --- Pure gptel orchestration tools -*- lexical-binding: t; -*-

(require 'macher)
(require 'json)
(require 'cl-lib)

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
              ;; REMOVED: Manual context stapling. The Advice bridge handles this safely now.
              (funcall async-fn)))
      (add-hook 'gptel-prompt-transform-functions transform-hook nil t)
      
      ;; 2. Handle completion naturally
      (setq response-hook
            (lambda (response info)
              (let ((res (buffer-local-value 'macher-agent--final-result buf)))
                (if res
                    (progn
                      (macher-agent--hide-ui buf)
                      (funcall callback (list :status 'success :data res)))
                  (funcall callback (list :status 'error :error (format "ERROR: Buffer '%s' stopped silently without calling submit_task_result." (buffer-name buf))))))))
      (add-hook 'gptel-post-response-functions response-hook nil t)
      
      (gptel-send))))

(defun macher-agent--set-system-message (msg)
  "Adapter function to safely set the gptel system message without hardcoding internals."
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
      (dolist (arg-name '("buffer_name" "buffer_names" "image_path"))
        (let* ((arg-sym (intern arg-name))
               (val (cdr (assq arg-sym arg-alist))))
          (when val
            (if (or (listp val) (vectorp val))
                (cl-loop for item being the elements of val do
                         (macher-agent--ensure-access context item))
              (macher-agent--ensure-access context val))))))))

(cl-defmacro macher-agent-define-tool (name-symbol (description category &key args async) lambda-args &rest body)
  "Define a gptel tool with standardised JSON parsing, error handling, and native signature."
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
                 `(let ((callback (lambda (plist-result)
                                    (let ((final-str (if (eq (plist-get plist-result :status) 'success)
                                                         (plist-get plist-result :data)
                                                       (plist-get plist-result :error))))
                                      (funcall gptel-callback final-str)))))
                    (condition-case err
                        (apply (lambda ,lambda-args ,@body) parsed-args)
                      (error
                       (funcall callback (list :status 'error :error (macher-agent--format-error err))))))

               `(let ((result
                       (condition-case err
                           (list :status 'success :data (apply (lambda ,lambda-args ,@body) parsed-args))
                         (error
                          (list :status 'error :error (macher-agent--format-error err))))))
                  (if (eq (plist-get result :status) 'success)
                      (plist-get result :data)
                    (plist-get result :error))))))))))

(defun macher-agent--format-error (err)
  "Standardise the error message string for the LLM."
  (let ((msg (error-message-string err)))
    (if (string-match-p "^\\(ERROR\\|SECURITY ERROR\\):" msg)
        msg
      (format "ERROR: %s" msg))))

(defun macher-agent--prepare-subagent-instructions (buf instructions)
  "Insert INSTRUCTIONS into BUF with cloaked system reminders."
  (with-current-buffer buf
    (goto-char (point-max))
    (when (not (string-empty-p instructions))
      (macher-agent--insert-hidden "\n\n=== DELEGATED TASK ===\n")
      (insert (substring-no-properties instructions)))
    (macher-agent--insert-hidden "\n\n@macher-agent-worker\n=== SYSTEM REMINDER ===\nYou MUST use the `submit_task_result` tool to return your answer. Do not just type it as plain text.\n")))

(defvar-local macher-agent--final-result nil
  "Stores the clean, synthesised final answer from the sub-agent.")

(defvar gptel-track-media)
(defvar gptel-context--alist)
(declare-function gptel-add-file "gptel")
(declare-function gptel-context-remove "gptel-context" (file))

(macher-agent-define-tool macher-agent-read-image-in-workspace-tool
                          ("Read an image from the workspace into the agent's context for a single turn. This allows you to 'see' images, including those generated by tools."
                           "ro"
                           :args '((:name "image_path" :type string :description "The path or buffer name of the image to read")))
                          (image_path)
                          (unless (and (boundp 'gptel-track-media) gptel-track-media)
                            (error "gptel media send option is off (gptel-track-media is nil)"))
                          (let* ((context (macher-agent-current-context))
                                 (actual-name (macher-agent--resolve-buffer-name image_path))
                                 (content (macher-agent--read-context-file context actual-name)))
                            (unless content
                              (error "SECURITY ERROR: You do not have permission to access '%s' or file not found. Use list_buffers_in_workspace to see your allowed scope." actual-name))
                            ;; Write the virtual content (raw bytes) to a temporary file
                            (let* ((ext (let ((e (file-name-extension actual-name t)))
                                          (if (and e (not (string-empty-p e))) (concat "." e) ".png")))
                                   (temp-file (make-temp-file "macher-agent-img-" nil ext))
                                   (cleanup-hook nil))
                              (with-temp-file temp-file
                                (set-buffer-multibyte nil)
                                (insert content))
                              ;; Add the file to gptel's context
                              (gptel-add-file temp-file)
                              
                              ;; Ensure the file is removed from gptel context after this request
                              (setq cleanup-hook
                                    (lambda (&rest _)
                                      (remove-hook 'gptel-post-response-functions cleanup-hook t)
                                      ;; Standard gptel removal is either gptel-context-remove, or deleting from gptel-context--alist
                                      (if (fboundp 'gptel-context-remove)
                                          (ignore-errors (gptel-context-remove temp-file))
                                        (when (boundp 'gptel-context--alist)
                                          (setq gptel-context--alist (assoc-delete-all temp-file gptel-context--alist))))
                                      (ignore-errors (delete-file temp-file))))
                              (add-hook 'gptel-post-response-functions cleanup-hook nil t)
                              
                              (format "Image '%s' has been temporarily added to your visual context for this request." actual-name))))

(with-eval-after-load 'macher-agent-skills
  (puthash "read_image_in_workspace" macher-agent-read-image-in-workspace-tool macher-agent-tools-registry))

(with-eval-after-load 'gptel-transient
  (ignore-errors
    ;; Disable history serialization for heavy gptel menu variables
    (transient-suffix-put 'gptel-menu 'gptel--infix-tools :save-history nil)
    (transient-suffix-put 'gptel-menu 'gptel--infix-system-message :save-history nil)))

(provide 'macher-agent-gptel-tools)
;;; macher-agent-gptel-tools.el ends here
