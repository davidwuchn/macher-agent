(macher-agent-define-tool macher-agent-list-buffers-in-workspace-tool
                          ("List all buffers you currently have explicit access to. You cannot access buffers outside this list."
                           "ro")
                          ()
                          (let* ((context (macher-agent-current-context))
                                 (workspace (when context (macher-context-workspace context)))
                                 (root-dir (when workspace (macher--workspace-root workspace)))
                                 (active-buffers nil))
                            (when context
                              (dolist (entry (macher-context-contents context))
                                (let* ((buf-name (car entry))
                                       (classification (macher-agent-context-classify-entry buf-name root-dir)))
                                  ;; Include both pure buffers and external files
                                  (when (memq classification '(buffer external))
                                    (push buf-name active-buffers)))))
                            (if active-buffers
                                (mapconcat #'identity (nreverse active-buffers) "\n")
                              "No buffers are currently in your scope.")))
