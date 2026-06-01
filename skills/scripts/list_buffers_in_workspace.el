(macher-agent-make-tool macher-agent-list-buffers-in-workspace-tool
  "List all buffers you currently have explicit access to. You cannot access buffers outside this list."
  :category "ro"
  :args nil
  :command-fn (lambda (_)
                (let* ((context (ignore-errors (macher-agent-current-context)))
                       (workspace (when context (macher-context-workspace context)))
                       (root-dir (when workspace (macher--workspace-root workspace)))
                       (active-buffers nil))
                  (when context
                    (dolist (entry (macher-context-contents context))
                      (let* ((buf-name (car entry))
                             (classification (macher-agent-context-classify-entry buf-name root-dir)))
                        (when (memq classification '(buffer external))
                          (push buf-name active-buffers)))))
                  (if active-buffers
                      (cons :lisp-result (mapconcat #'identity (nreverse active-buffers) "\n"))
                    (cons :lisp-result "No buffers are currently in your scope.")))))