(macher-agent-make-tool macher-agent-list-buffers-in-workspace-tool
  "List all buffers you currently have explicit access to. You cannot access buffers outside this list."
  :category "ro"
  :args nil
  :command-fn (lambda (_payload context root-dir)
                (let* ((active-buffers nil))
                  (when context
                    (dolist (entry (macher-agent--get-context-contents context))
                      (let* ((buf-name (macher-agent-vfs-entry-path entry))
                             (classification (macher-agent-context-classify-entry buf-name root-dir)))
                        (when (memq classification '(buffer external))
                          (push buf-name active-buffers)))))
                  (if active-buffers
                      (make-macher-agent-tool-response :type 'lisp-result :payload (mapconcat #'identity (nreverse active-buffers) "\n"))
                    (make-macher-agent-tool-response :type 'lisp-result :payload "No buffers are currently in your scope.")))))