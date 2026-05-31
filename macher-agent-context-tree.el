;;; macher-agent-context-tools.el --- Tools requiring macher's ephemeral context -*- lexical-binding: t; -*-

(require 'project)
(require 'gptel)
(require 'macher)
(require 'macher-agent-vfs-client)

;; Forward declaration
(declare-function macher-agent-current-context "macher-agent-vfs-client")

(cl-defmacro macher-agent-make-tool (&key name description args command-fn success-fn output-filter category)
  "Create a tool that automatically syncs macher's virtual edits into a sandbox before execution.
Utilises a variadic signature to safely absorb FSM-injected context and ignore LLM prompt hallucinations."
  (let ((cat (or category "macher-agent")))
    `(gptel-make-tool
      :name ,name
      :description ,description
      :args ,args
      :category ,cat
      :async t
      :function (lambda (&rest all-args)
                  (let* (;; 1. Safely isolate the gptel callback
                         (callback (cl-find-if #'functionp all-args))

                         ;; 2. Safely isolate macher's injected context struct
                         (injected-context (cl-find-if (lambda (x) (and (boundp 'macher-context-p) (fboundp 'macher-context-p) (macher-context-p x))) all-args))

                         ;; 3. Strip out the callback and context
                         (raw-tool-args (cl-remove-if (lambda (x)
                                                        (or (eq x callback)
                                                            (eq x injected-context)))
                                                      all-args))

                         ;; 4. Align arguments from the end based on expected length
                         (expected-arg-count (length ,args))
                         (aligned-args (last raw-tool-args expected-arg-count))

                         ;; 5. Resolve Context & Scope
                         (context (or injected-context (ignore-errors (macher-agent-current-context))))
                         (workspace (when context (macher-context-workspace context)))
                         (project-root (if workspace (file-name-as-directory (macher--workspace-root workspace)) default-directory))
                         (pending-edits (macher-agent--get-context-edits context))

                         ;; 6. Bind keyword arguments for the command definition
                         (call-args (let ((result nil))
                                      (cl-loop for arg-def in ,args
                                               for i from 0
                                               for arg-name = (intern (concat ":" (plist-get arg-def :name)))
                                               do (setq result (plist-put result arg-name (nth i aligned-args))))
                                      result))

                         ;; 7. Construct command and handle success overrides
                         (cmd-string (funcall ,command-fn call-args))
                         (success-override (when ,success-fn (funcall ,success-fn call-args))))

                    ;; Hand off execution to the robust VFS Client implementation
                    (macher-agent--pure-async-execute
                     project-root
                     pending-edits
                     cmd-string
                     success-override
                     (lambda (result)
                       (funcall callback (if ,output-filter (funcall ,output-filter result) result)))))))))

(provide 'macher-agent-context-tools)
;;; macher-agent-context-tools.el ends here
